import Foundation
import Combine
import OSLog

private let liveAILog = MilaLog(category: "LiveAISession")

/// Drives the LLM half of Live AI mode. Holds an action-item list, fires a
/// debounced one-shot LLM call against the latest transcript on each tick,
/// dedupes returned items by `id`, and gracefully serializes calls so the
/// CLI never overlaps with itself.
///
/// Why one-shot per tick rather than a persistent CLI session: the
/// `claude` and `cursor-agent` CLIs aren't designed for streamed
/// stdin/stdout interaction, and one-shot calls are cheap because
/// Anthropic's prompt cache (used automatically by `claude`) bills the
/// repeated transcript prefix at the cached rate. See the plan doc for
/// the cost breakdown.
@MainActor
final class LiveAISession: ObservableObject {
    /// Authoritative list of action items, newest at the top. The list
    /// fully replaces itself on every successful LLM tick (the prompt
    /// asks the model to re-emit ALL items each time, with stable IDs),
    /// so the UI never has to merge partial updates by hand.
    @Published private(set) var actionItems: [ActionItem] = []
    /// Rolling summary of the conversation, refreshed on every tick.
    /// Empty until the first successful LLM response contains it.
    @Published private(set) var summary: String = ""
    @Published private(set) var isThinking: Bool = false
    @Published private(set) var lastError: String?

    private let llmSettings: LLMSettings
    private let liveAISettings: LiveAISettings

    private var inFlight: Task<Void, Never>?
    /// Set when a tick fires while a call is in flight — the next idle
    /// moment will fire one more pass against the latest transcript so
    /// late chunks are never dropped.
    private var coalesced: Bool = false
    private var latestTranscript: String = ""

    // MARK: - Min-interval throttle

    /// When the most recent tick *started* (nil before the first tick).
    /// The throttle is measured from the start, not the end, so a long
    /// call that already outlasted the interval adds no extra delay.
    private var lastKickStartedAt: Date?
    /// A throttled tick that's sleeping out the remaining interval. At
    /// most one exists at a time; cancelled on stop / finalize.
    private var pendingKickTask: Task<Void, Never>?
    /// Set while `awaitFinalTick()` is draining at stop time — makes
    /// every scheduled kick fire immediately (no floor) so the saved
    /// summary covers right up to stop.
    private var isFinalizing: Bool = false

    /// Clock seam — overridable in tests to drive the throttle on a
    /// simulated timeline. Production reads the wall clock.
    var nowProvider: () -> Date = { Date() }

    /// The actual subprocess call, factored out so tests can substitute a
    /// stub that records invocations without spawning a real CLI.
    /// Production runs the `claude` / `cursor-agent` binary via
    /// `LLMRunner.run`.
    struct LLMCall {
        let tool: LLMTool
        let prompt: String
        let transcript: String
        let executablePathOverride: String?
        let model: String
        let session: LLMSession
        let timeout: TimeInterval
    }
    var performCall: (LLMCall) async throws -> String = { call in
        try await LLMRunner.run(
            tool: call.tool,
            prompt: call.prompt,
            transcript: call.transcript,
            executablePathOverride: call.executablePathOverride,
            model: call.model,
            session: call.session,
            timeout: call.timeout
        )
    }

    /// Pure throttle core: how long to wait before the next tick may
    /// *start*, given the previous tick's start time and the configured
    /// minimum spacing. `0` means "start now". Exposed `static` so it can
    /// be unit-tested exhaustively without any timing or subprocess.
    static func kickDelay(now: Date,
                          lastKickStartedAt: Date?,
                          minInterval: TimeInterval) -> TimeInterval {
        guard minInterval > 0, let last = lastKickStartedAt else { return 0 }
        let elapsed = now.timeIntervalSince(last)
        return elapsed >= minInterval ? 0 : (minInterval - elapsed)
    }

    /// Per-recording session id for stateful Claude conversations. The
    /// first call uses `--session-id <uuid>` to CREATE the conversation
    /// and subsequent calls use `--resume <uuid>` to continue it (the
    /// CLI errors with "Session ID is already in use" if you reuse
    /// --session-id, which is the bug that silently broke every tick
    /// after the first). nil when the tool is Cursor (no session flag
    /// in `-p` mode) or before `start()` runs.
    private var sessionID: UUID?
    /// Set to true after the first successful Claude call so subsequent
    /// calls switch from `--session-id` (create) to `--resume`
    /// (continue). A failed first call keeps this false so the next
    /// tick retries the create.
    private var sessionEstablished: Bool = false

    /// The length of `latestTranscript` we last actually shipped to the
    /// LLM. With a live session the model already has the previous
    /// transcript in its conversation history, so we only need to send
    /// the new tail each tick. nil when no tick has succeeded yet.
    private var lastTranscriptSent: String = ""

    /// Per-call timeout for `--resume` ticks. The default `LLMRunner`
    /// foreground timeout (300 s) is too generous for the live loop — a
    /// stuck call would pile up coalesced ticks. Sonnet 4.6 (current
    /// default) is meaningfully slower than Haiku; 90 s gives it room
    /// without piling.
    var timeoutSeconds: TimeInterval = 90

    /// First-call timeout (`.new` session). Establishing a fresh Claude
    /// session is materially slower than `--resume` (cold prompt cache,
    /// tool discovery, sandbox bring-up), so we don't apply the tight
    /// `timeoutSeconds` cap to the very first tick — it was producing a
    /// confusing "LLM CLI did not respond within the timeout" banner on
    /// recordings that otherwise worked fine from tick 2 onward. Bumped
    /// to 180s after Sonnet 4.6 cold-starts were timing out at 90s.
    var firstCallTimeoutSeconds: TimeInterval = 180

    init(llmSettings: LLMSettings, liveAISettings: LiveAISettings) {
        self.llmSettings = llmSettings
        self.liveAISettings = liveAISettings
    }

    /// Begin a session — clears any previous state. Generates a fresh
    /// session id when the user's LLM tool supports session continuity
    /// (Claude does; Cursor doesn't), so each recording gets its own
    /// isolated conversation history with the model.
    func start() {
        cancel()
        actionItems = []
        summary = ""
        lastError = nil
        sessionID = (llmSettings.tool == .claude) ? UUID() : nil
        sessionEstablished = false
        lastTranscriptSent = ""
        // os_log (NOT print) so the session UUID lands in diagnostic reports.
        // A fresh `start()` per recording is the invariant that prevents
        // cross-recording `--resume` bleed; logging the new id makes a
        // regression visible in `Mila-DiagnosticReport`.
        liveAILog.log("start: fresh session=\(self.sessionID?.uuidString.prefix(8) ?? "none", privacy: .public) tool=\(self.llmSettings.tool.rawValue, privacy: .public)")
    }

    /// Wait until any in-flight (or coalesced-and-pending) LLM tick
    /// finishes, so a caller can read `summary` / `actionItems` and
    /// know they reflect the final state. Used by
    /// QuickActionsController at stop time to avoid the race where
    /// the saved Recording was assembled with stale Live AI output.
    func awaitFinalTick() async {
        // Stop time: flush now, don't honour the min-interval floor.
        // `isFinalizing` makes every scheduleKick() in this window fire
        // immediately (delay 0), including the coalesced re-kick the
        // completion handler queues.
        isFinalizing = true
        defer { isFinalizing = false }
        // Drop any throttled tick that's sleeping out the interval — we
        // flush its (now stale) intent immediately below instead.
        pendingKickTask?.cancel()
        pendingKickTask = nil
        // If nothing is running, fire the latest transcript right away.
        // In session mode an already-sent transcript yields an empty
        // delta and kick() returns without launching, so this is a
        // no-op when there's nothing new.
        if inFlight == nil {
            scheduleKick(immediate: true)
        }
        // Drain the in-flight tick and any coalesced follow-up. The tick
        // task sets `inFlight = nil` in its tail before potentially
        // scheduling another (immediate, since isFinalizing) kick, so
        // looping until `inFlight` is nil drains everything.
        while let handle = inFlight {
            _ = await handle.value
        }
    }

    /// Cancel any in-flight call and clear state. Called when the
    /// recording stops or live AI mode is toggled off mid-recording.
    func cancel() {
        let inFlightHandle = inFlight
        inFlight?.cancel()
        inFlight = nil
        coalesced = false
        latestTranscript = ""
        isThinking = false
        // Clear the rolling AI output too. `cancel()` is both the leading
        // half of `start()` AND the gated-hardware reset path
        // (wireLiveAIPipeline calls it when Live AI is unavailable). In both
        // cases the previous recording's summary / action items must NOT
        // survive — otherwise `stopRecording` snapshots stale content onto a
        // new recording. Previously cancel() left these intact, so the
        // gated-branch comment claiming it "clears summary/actionItems" was a
        // no-op. (start() also re-clears them; harmless redundancy.)
        actionItems = []
        summary = ""
        lastError = nil
        pendingKickTask?.cancel()
        pendingKickTask = nil
        lastKickStartedAt = nil
        isFinalizing = false
        // Wipe the per-session stable sandbox dir LLMRunner created so
        // /tmp doesn't accumulate one folder per recording. The child
        // claude subprocess receives SIGTERM via the cancelled Task,
        // but exit is async — wait for the Task's continuation to
        // complete before removing the sandbox so we don't rip the
        // CWD out from under the still-living process.
        if let id = sessionID {
            let key = id.uuidString
            Task.detached(priority: .utility) {
                _ = await inFlightHandle?.value
                LLMRunner.cleanupStableSandbox(key: key)
            }
        }
        sessionID = nil
        sessionEstablished = false
        lastTranscriptSent = ""
    }

    /// Feed the latest full transcript. Routes through the min-interval
    /// throttle: a tick starts now only if no call is in flight AND at
    /// least `llmMinIntervalSeconds` has passed since the last one
    /// started; otherwise it's deferred or coalesced. Pass
    /// `immediate: true` to bypass the floor (stop-time flush, or a
    /// user-initiated toggle-on that wants instant feedback).
    func feed(transcript: String, immediate: Bool = false) {
        latestTranscript = transcript
        scheduleKick(immediate: immediate)
    }

    /// The single funnel all feed paths go through, so the throttle is
    /// applied uniformly. Decides: start now, defer until the interval
    /// elapses, or fold into the running call.
    private func scheduleKick(immediate: Bool = false) {
        guard llmSettings.isConfigured, !latestTranscript.isEmpty else { return }
        // Live AI toggled off mid-recording: don't fire, and drop any
        // deferred tick. The feed loop stops calling feed() on toggle-off,
        // but a pendingKickTask already sleeping out the min-interval floor
        // would otherwise still wake and spawn a stray subprocess up to the
        // interval later — folding a post-disable result into the summary.
        guard liveAISettings.enabled else {
            pendingKickTask?.cancel()
            pendingKickTask = nil
            coalesced = false
            return
        }
        // A call is already running — record that fresh transcript
        // arrived; the completion handler re-evaluates and fires one
        // more pass with the latest snapshot.
        guard inFlight == nil else { coalesced = true; return }
        let delay = (immediate || isFinalizing)
            ? 0
            : Self.kickDelay(now: nowProvider(),
                             lastKickStartedAt: lastKickStartedAt,
                             minInterval: liveAISettings.llmMinIntervalSeconds)
        if delay <= 0 {
            pendingKickTask?.cancel()
            pendingKickTask = nil
            kick()
        } else if pendingKickTask == nil {
            // Sleep out the remaining interval, then re-evaluate: the
            // interval will have elapsed so it kicks — unless a call
            // started meanwhile, in which case scheduleKick() coalesces.
            // `latestTranscript` is read at fire time, so it picks up any
            // segments that land while waiting.
            pendingKickTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.pendingKickTask = nil
                self.scheduleKick()
            }
        }
        // else: a deferred kick is already waiting — leave it in place.
    }

    private func kick() {
        guard llmSettings.isConfigured else { return }
        guard !latestTranscript.isEmpty else { return }
        let snapshot = latestTranscript
        let tool = llmSettings.tool
        let exe = llmSettings.executablePath.isEmpty ? nil : llmSettings.executablePath
        // When the user picks `.auto`, detect Hebrew vs English from the
        // transcript itself rather than passing the abstract phrase
        // "match the transcript language" through to the LLM — Claude
        // / cursor-agent obey concrete instructions ("Output in Hebrew")
        // far more consistently than they obey introspective ones.
        let promptLanguageName: String = {
            switch liveAISettings.outputLanguage {
            case .auto:
                return snapshot.isPredominantlyHebrew ? "Hebrew" : "English"
            case .english:
                return "English"
            case .hebrew:
                return "Hebrew"
            }
        }()
        let prompt = liveAISettings.prompt
            .replacingOccurrences(of: "{{LANGUAGE}}", with: promptLanguageName)
        let model = liveAISettings.model
        let useSession = (sessionID != nil)
        // Cold-start the first tick gets a longer timeout (see
        // `firstCallTimeoutSeconds`). All subsequent ticks use the
        // tight live-loop bound.
        let timeout = (useSession && !sessionEstablished)
            ? firstCallTimeoutSeconds
            : timeoutSeconds

        // Two transcript-shipping strategies:
        //
        //   * Session mode (Claude with --session-id) — the model's
        //     conversation memory already has the previous transcript
        //     and its own emissions. We only need to send the new tail
        //     since the last tick. The prompt drops the "CURRENT STATE"
        //     block because the model can already see what it said.
        //
        //   * Stateless mode (Cursor, or any tool without session
        //     support) — the model is fresh each call, so we ship the
        //     full transcript AND the current items/summary so it can
        //     dedupe explicitly.
        let augmentedTranscript: String
        if useSession {
            // Compute the delta. If the snapshot doesn't extend the
            // previously-sent prefix (e.g. transcript was reset), fall
            // back to sending the whole snapshot — the session will
            // have it twice, harmless, and the model just sees a re-
            // statement.
            let delta: String
            if snapshot.hasPrefix(lastTranscriptSent) {
                delta = String(snapshot.dropFirst(lastTranscriptSent.count))
                    .trimmingCharacters(in: .whitespaces)
            } else {
                delta = snapshot
            }
            if delta.isEmpty {
                // Nothing new to say. Skip the call.
                return
            }
            augmentedTranscript = "Additional transcript since last update:\n\(delta)"
        } else {
            let existingJSON = Self.encodeForPrompt(items: actionItems,
                                                    summary: summary)
            augmentedTranscript = """
CURRENT STATE (what the user already sees — you may keep, update, or remove anything here by re-emitting it, or by omitting it from your response):
\(existingJSON)

TRANSCRIPT SO FAR:
\(snapshot)
"""
        }

        // Compute the right session flag for this tick:
        //   * .new on the FIRST call — claude --session-id <uuid>
        //     creates the conversation.
        //   * .resume on every subsequent call — claude --resume <uuid>
        //     continues the existing conversation. Reusing --session-id
        //     errors out as "Session ID is already in use", which is
        //     why every Live AI tick after the first was silently
        //     failing before this fix.
        let llmSession: LLMSession
        if let id = sessionID {
            llmSession = sessionEstablished ? .resume(id) : .new(id)
        } else {
            llmSession = .none
        }
        isThinking = true
        // Stamp the throttle clock at the moment a tick commits to
        // running (after all the early-return guards above), so a
        // skipped/empty-delta kick doesn't reset the min-interval window.
        lastKickStartedAt = nowProvider()
        let kickStart = Date()
        let kickTag = "tick-\(Int(kickStart.timeIntervalSinceReferenceDate * 1000) % 100_000)"
        // Capture the (possibly stubbed) call closure so the detached
        // task doesn't need `self` just to reach it.
        let perform = performCall
        // Identify this tick by the session UUID it was launched for.
        // If `cancel()` or a fresh `start()` runs while the LLM call
        // is still in flight (session UUID gets cleared / replaced),
        // we drop the late response — applying it to a newer
        // recording would merge the wrong items / summary into a
        // session the model didn't actually produce.
        let kickSessionID = sessionID
        print("LiveAI[\(kickTag)]: tool=\(tool.rawValue) model=\(model.isEmpty ? "(default)" : model) session=\(llmSession) delta=\(useSession ? augmentedTranscript.count : 0)ch full=\(snapshot.count)ch items=\(actionItems.count) sending…")
        // os_log mirror of the session decision so diagnostic reports capture
        // it. A `.resume` on a recording's FIRST tick is the signature of the
        // cross-recording bleed bug (the session wasn't freshly started); a
        // healthy recording always opens with `.new`.
        liveAILog.log("tick \(kickTag, privacy: .public): session=\(String(describing: llmSession), privacy: .public) established=\(self.sessionEstablished, privacy: .public)")
        inFlight = Task { @MainActor [weak self] in
            let llmStart = Date()
            do {
                let raw = try await perform(LLMCall(
                    tool: tool,
                    prompt: prompt,
                    transcript: augmentedTranscript,
                    executablePathOverride: exe,
                    model: model,
                    session: llmSession,
                    timeout: timeout
                ))
                let elapsed = Date().timeIntervalSince(llmStart)
                let parsed = Self.parseEnvelope(from: raw)
                print(String(format: "LiveAI[%@]: response in %.1fs → %d items, summary=%dch", kickTag, elapsed, parsed.items.count, parsed.summary.count))
                // Bail out if the session was cancelled or restarted
                // while this tick was in flight. Without this check,
                // a slow CLI response from a previous recording could
                // pollute the active session's state.
                guard let self, self.sessionID == kickSessionID else {
                    print("LiveAI[\(kickTag)]: dropped — session changed mid-flight")
                    return
                }
                self.applyResponse(items: parsed.items, summary: parsed.summary)
                // A success clears any stale error banner — a transient
                // first-call timeout shouldn't keep showing red once
                // subsequent ticks are landing fine.
                self.lastError = nil
                if useSession {
                    self.lastTranscriptSent = snapshot
                    // First successful call establishes the session;
                    // future ticks must use --resume.
                    self.sessionEstablished = true
                }
            } catch {
                let elapsed = Date().timeIntervalSince(llmStart)
                print(String(format: "LiveAI[%@]: FAILED after %.1fs: %@", kickTag, elapsed, error.localizedDescription))
                // Same drop-the-stale-tick check as the success path.
                guard let self, self.sessionID == kickSessionID else {
                    return
                }
                self.lastError = "Live AI: \(error.localizedDescription)"
                // First-call failures: regenerate the session UUID so
                // the next attempt doesn't keep colliding with a
                // potentially wedged `claude --session-id <uuid>` state
                // (Claude refuses to reopen a session-id that's mid-
                // write or held). Once a session has been established
                // (one success), we trust the UUID and just retry on
                // the same session.
                if !self.sessionEstablished {
                    self.sessionID = UUID()
                    self.lastTranscriptSent = ""
                }
            }
            self?.isThinking = false
            self?.inFlight = nil
            // If new text arrived while we were running, fire one more
            // pass with the latest snapshot.
            if let self, self.coalesced {
                self.coalesced = false
                // Route through the throttle: honours the min-interval
                // floor during normal operation, fires immediately while
                // finalizing.
                self.scheduleKick()
            }
        }
    }

    private func applyResponse(items: [ActionItem], summary: String) {
        applyResponse(items)
        // An empty summary in the response usually means the model
        // emitted only items this tick — keep the last good summary
        // visible rather than blanking the UI mid-call.
        if !summary.isEmpty {
            self.summary = summary
        }
    }

    private func applyResponse(_ items: [ActionItem]) {
        // The LLM now sees the current list in the prompt, so its
        // response is the authoritative new state. Items it chose not
        // to re-emit ARE intentionally removed (the user wanted this
        // so duplicates from "I said it twice" can be consolidated).
        // If the LLM glitches and returns an empty list we keep what
        // we have (defensive: a CLI hiccup shouldn't blow away the
        // user's accumulated list).
        guard !items.isEmpty else { return }
        let now = Date()
        let priorByID = Dictionary(uniqueKeysWithValues:
            actionItems.map { ($0.id, $0) }
        )
        var rebuilt: [ActionItem] = []
        var seen = Set<String>()
        for var item in items {
            if seen.contains(item.id) { continue }   // LLM duplicated an id; keep first
            seen.insert(item.id)
            if let prior = priorByID[item.id] {
                // Preserve `addedAt` so newest-first ordering stays
                // stable for items the LLM kept; fill in metadata the
                // LLM may have stripped between ticks.
                item.addedAt = prior.addedAt
                if item.speaker == nil { item.speaker = prior.speaker }
                if item.timestampSeconds == 0 { item.timestampSeconds = prior.timestampSeconds }
            } else {
                item.addedAt = now
            }
            rebuilt.append(item)
        }
        rebuilt.sort { lhs, rhs in
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
            return lhs.id < rhs.id
        }
        actionItems = rebuilt
    }

    /// Serialize the current state so the LLM can see it on the next
    /// tick. Compact JSON shape (no pretty-print) keeps token usage
    /// low and prompt-cache friendly.
    private static func encodeForPrompt(items: [ActionItem], summary: String) -> String {
        struct Compact: Encodable {
            let summary: String
            let items: [Item]
            struct Item: Encodable {
                let id: String
                let text: String
                let speaker: String?
                let timestamp_seconds: Double
                let source: String
            }
        }
        let payload = Compact(
            summary: summary,
            items: items.map {
                .init(id: $0.id, text: $0.text, speaker: $0.speaker,
                      timestamp_seconds: $0.timestampSeconds,
                      source: $0.source.rawValue)
            }
        )
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"summary\":\"\",\"items\":[]}"
        }
        return json
    }

    /// Result of a successful parse. `summary` is empty when the model
    /// emitted only items (legacy / mid-call). Callers should keep the
    /// last good summary in that case rather than blanking the UI.
    struct ParsedResponse {
        let summary: String
        let items: [ActionItem]
    }

    /// Parse the LLM's response — preferred form is a single JSON object
    /// `{"summary": "...", "items": [...]}`; we also accept a bare
    /// `[...]` items array for back-compat with the original prompt
    /// shape and for runs where the model decides to skip the summary.
    /// The CLI occasionally wraps output in prose or ```json fences,
    /// so we extract the first balanced JSON block we find rather than
    /// insisting on a clean parse.
    static func parseEnvelope(from raw: String) -> ParsedResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Try object form first.
        if let range = findFirstJSONStructure(in: trimmed, opening: "{", closing: "}"),
           let data = String(trimmed[range]).data(using: .utf8),
           let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            let items = (envelope.items ?? []).compactMap(Self.makeItem(from:))
            return ParsedResponse(
                summary: (envelope.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                items: items
            )
        }
        // Fall back to bare array (legacy prompt / partial output).
        return ParsedResponse(summary: "", items: parseActionItems(from: raw))
    }

    /// Legacy helper — parse a bare JSON array of items. Retained so the
    /// existing tests keep working AND so a fall-back path is available
    /// when the LLM ignores the object-form instruction.
    static func parseActionItems(from raw: String) -> [ActionItem] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonRange = findFirstJSONArray(in: trimmed) else { return [] }
        let jsonText = String(trimmed[jsonRange])
        guard let data = jsonText.data(using: .utf8) else { return [] }
        do {
            let decoded = try JSONDecoder().decode([Wire].self, from: data)
            return decoded.compactMap(Self.makeItem(from:))
        } catch {
            return []
        }
    }

    private static func makeItem(from wire: Wire) -> ActionItem? {
        let id = wire.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = wire.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id, !id.isEmpty, let text, !text.isEmpty else { return nil }
        let source: ActionItem.Source = (wire.source ?? "inferred") == "voice_command"
            ? .voiceCommand : .llmInferred
        return ActionItem(
            id: id,
            text: text,
            speaker: wire.speaker?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty(),
            timestampSeconds: wire.timestamp_seconds ?? 0,
            source: source,
            addedAt: Date()
        )
    }

    private struct Envelope: Decodable {
        let summary: String?
        let items: [Wire]?
    }

    /// Lenient extractor: finds the first balanced `[...]` substring. The
    /// CLI sometimes prefixes "Here is the JSON:" or wraps in ```json
    /// fences — neither is JSON-parseable as-is, but we can still pluck
    /// out the array.
    static func findFirstJSONArray(in s: String) -> Range<String.Index>? {
        findFirstJSONStructure(in: s, opening: "[", closing: "]")
    }

    /// Generalised balanced-bracket extractor. Honours `"`-quoted strings
    /// so quoted bracket characters never throw off the depth counter.
    static func findFirstJSONStructure(in s: String,
                                       opening: Character,
                                       closing: Character) -> Range<String.Index>? {
        guard let start = s.firstIndex(of: opening) else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var idx = start
        while idx < s.endIndex {
            let ch = s[idx]
            if escape { escape = false }
            else if ch == "\\" && inString { escape = true }
            else if ch == "\"" { inString.toggle() }
            else if !inString {
                if ch == opening { depth += 1 }
                else if ch == closing {
                    depth -= 1
                    if depth == 0 {
                        let endIdx = s.index(after: idx)
                        return start..<endIdx
                    }
                }
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    private struct Wire: Decodable {
        let id: String?
        let text: String?
        let speaker: String?
        let timestamp_seconds: Double?
        let source: String?
    }
}

private extension String {
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}
