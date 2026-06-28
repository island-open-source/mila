import Foundation
import Combine
import OSLog

private let summarizerLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                   category: "RecordingSummarizer")

/// Fires a one-shot LLM call against a finished recording's transcript and
/// stores the result on the `Recording.summary` field.
///
/// Three entry points:
///   * `summarizeIfNeeded(_:)` — fired by the post-transcription hook for
///     every freshly-transcribed recording. Skips work when a live summary
///     is already there.
///   * `regenerate(_:)` — explicit user action (Re-transcribe completion +
///     "Regenerate summary" context menu). Bypasses the
///     "already has summary" gate so the old summary is replaced.
///   * `backfillIfNeeded()` — called on launch and on LLM-config flip
///     (off→on). Scans the store for completed recordings missing a
///     summary and queues them through `summarizeIfNeeded` with a
///     concurrency cap so we don't melt the user's API quota.
///
/// Uses the same `LLMRunner` + sandboxing the rename sheet's "Send to
/// Claude" path uses, so any `$PATH` / TCC-popup mitigations carry over
/// for free.
@MainActor
final class RecordingSummarizer: ObservableObject {
    private let store: RecordingStore
    private let llmSettings: LLMSettings
    private let liveAISettings: LiveAISettings

    /// Background work tracked per-recording so a second `summarizeIfNeeded`
    /// call for the same id (e.g. a re-transcribe trigger) doesn't spawn
    /// two overlapping CLI invocations.
    ///
    /// Published as a set so detail views can show a "Summarizing…"
    /// spinner on the summary section while a call is in flight (used by
    /// the "Regenerate summary" affordance + backfill).
    @Published private(set) var inFlightIDs: Set<UUID> = []
    private var inFlight: [UUID: Task<Void, Never>] = [:]

    /// Recordings the backfill scan has identified as needing a summary
    /// but hasn't started yet — held here so `maxConcurrent` is enforced
    /// across the whole batch instead of letting all candidates spawn at
    /// once.
    private var backfillQueue: [UUID] = []

    /// Max concurrent in-flight CLI invocations the summarizer will
    /// schedule from backfill / regeneration. Starts at 2 — high enough
    /// that two recordings get summarized at app launch in parallel but
    /// low enough that a 20-recording catch-up sweep doesn't fork 20
    /// `claude -p` subprocesses on the user's machine.
    var maxConcurrent: Int = 2

    /// Subscribers held for the lifetime of the summarizer. We watch
    /// `LLMSettings.$tool` so a user who configures their CLI mid-session
    /// gets an automatic backfill sweep the moment the toggle flips.
    private var cancellables: Set<AnyCancellable> = []

    /// Timeout for the one-shot summary call. Reads from `LLMSettings.cliTimeout`
    /// so it follows the user's preference set in Settings → LLM.
    var timeoutSeconds: TimeInterval { llmSettings.cliTimeout }

    init(store: RecordingStore,
         llmSettings: LLMSettings,
         liveAISettings: LiveAISettings) {
        self.store = store
        self.llmSettings = llmSettings
        self.liveAISettings = liveAISettings

        // Backfill on off→on transitions of LLM configured-ness. The
        // `tool` property is the only one that affects `isConfigured`
        // today; observing it directly (rather than the computed
        // `isConfigured`) means we don't need to expose a publisher on
        // the computed property.
        //
        // `@Published` emits from `willSet` — i.e. the sink fires
        // BEFORE the property has been updated, so `llmSettings.tool`
        // and `llmSettings.isConfigured` still report the OLD value at
        // sink time. `Task { @MainActor }` from a main-actor caller
        // can resume on the same actor tick (Swift's scheduler does not
        // guarantee a real runloop hop), so reading `isConfigured`
        // inside the Task body still saw the old value in CI.
        //
        // `.receive(on: DispatchQueue.main)` shifts delivery onto the
        // next main-queue tick via `dispatch_async`, which is a hard
        // boundary: by the time the sink runs, the @Published setter
        // has fully completed (storage written, didSet invoked) so
        // `isConfigured` reflects the new value.
        llmSettings.$tool
            .map { $0 != .none }
            .removeDuplicates()
            .dropFirst()  // ignore the initial value emitted by @Published
            .receive(on: DispatchQueue.main)
            .sink { [weak self] nowConfigured in
                guard let self, nowConfigured else { return }
                summarizerLog.log("llm configured flipped on — scheduling backfill")
                self.backfillIfNeeded()
            }
            .store(in: &cancellables)
    }

    // MARK: - Predicates

    /// Returns true iff `recording` needs (and can get) a one-shot summary
    /// under the normal (non-force) gate.
    /// Public so callers + tests can ask the same question we ask
    /// internally without re-deriving the predicate.
    func shouldSummarize(_ recording: Recording) -> Bool {
        guard llmSettings.summaryEnabled else { return false }
        guard llmSettings.isConfigured else { return false }
        let transcript = recording.fullText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if transcript.isEmpty { return false }
        let existing = (recording.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty { return false }
        return true
    }

    /// True while a summary CLI call is in flight for `recordingID`.
    /// Used by the detail view to show a "Summarizing…" spinner on the
    /// summary section.
    func isSummarizing(_ recordingID: UUID) -> Bool {
        inFlightIDs.contains(recordingID)
    }

    // MARK: - Public API

    /// Kick off a background summary for `recording` if the gate above
    /// allows. Returns immediately — the caller doesn't await the LLM.
    /// Idempotent: a second call while one is in flight is a no-op so a
    /// re-enqueue from the transcription path can't double-bill.
    func summarizeIfNeeded(_ recording: Recording) {
        guard shouldSummarize(recording) else {
            logSkip(recording, force: false)
            return
        }
        runSummary(for: recording, force: false)
    }

    /// Force-regenerate a summary for `recording`, bypassing the
    /// "already has a summary" gate. Used by:
    ///   * `TranscriptionService`'s onTranscriptionCompleted callback
    ///     when the completed recording was a re-transcription (the old
    ///     summary refers to the now-replaced transcript).
    ///   * The "Regenerate summary" context-menu action.
    ///
    /// Still respects the two hard requirements: LLM must be configured,
    /// transcript must be non-empty. Returns immediately.
    func regenerate(_ recording: Recording) {
        guard llmSettings.isConfigured else {
            summarizerLog.log("regenerate \(self.shortID(recording.id), privacy: .public): skipped — LLM not configured")
            return
        }
        let transcript = recording.fullText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            summarizerLog.log("regenerate \(self.shortID(recording.id), privacy: .public): skipped — transcript empty")
            return
        }
        runSummary(for: recording, force: true)
    }

    /// Scan the store for completed recordings missing a summary, then
    /// process them newest-first with at most `maxConcurrent` in-flight
    /// CLI invocations. No-op when the LLM CLI isn't configured (the
    /// constructor's `$tool` subscriber re-runs the scan once that
    /// changes).
    ///
    /// Idempotent: re-runs are safe — recordings already in flight are
    /// skipped by `runSummary`'s own dedup check.
    func backfillIfNeeded() {
        guard llmSettings.summaryEnabled else {
            summarizerLog.log("backfill: skipped — auto-summary disabled")
            return
        }
        guard llmSettings.isConfigured else {
            summarizerLog.log("backfill: skipped — LLM not configured")
            return
        }
        // Newest-first: scan in the same order RecordingStore keeps its
        // array (createdAt descending) so the recording the user just
        // made gets attention before the months-old archive.
        let candidates: [Recording] = store.recordings.filter { rec in
            guard rec.status == .completed else { return false }
            guard !rec.isTrashed else { return false }
            let transcript = rec.fullText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { return false }
            let existing = (rec.summary ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return existing.isEmpty
        }
        guard !candidates.isEmpty else {
            summarizerLog.log("backfill: nothing to do")
            return
        }
        summarizerLog.log("backfill: \(candidates.count, privacy: .public) candidate(s) queued (concurrency=\(self.maxConcurrent, privacy: .public))")
        // Append rather than replace so a config-flip-triggered re-scan
        // that runs while a previous backfill is still draining doesn't
        // drop in-progress IDs. The dedup guard inside `runSummary`
        // covers duplicate enqueues.
        for rec in candidates {
            if !backfillQueue.contains(rec.id),
               !inFlight.keys.contains(rec.id) {
                backfillQueue.append(rec.id)
            }
        }
        pumpBackfill()
    }

    /// Cancel any in-flight summary work for `recordingID`. Used when a
    /// recording is being permanently deleted so we don't spend a CLI
    /// call on output that has nowhere to land.
    func cancel(recordingID: UUID) {
        backfillQueue.removeAll { $0 == recordingID }
        if let task = inFlight.removeValue(forKey: recordingID) {
            task.cancel()
            inFlightIDs.remove(recordingID)
        }
    }

    // MARK: - Internals

    /// Drain `backfillQueue` up to the concurrency cap. Re-invoked from
    /// each task's `defer` so as soon as one finishes the next one can
    /// start.
    private func pumpBackfill() {
        while inFlight.count < maxConcurrent, !backfillQueue.isEmpty {
            let id = backfillQueue.removeFirst()
            guard let rec = store.recordings.first(where: { $0.id == id }) else {
                continue
            }
            // Re-check the gate — the recording may have been trashed,
            // re-transcribed, or summarized via another code path
            // between scan time and now.
            guard shouldSummarize(rec) else { continue }
            runSummary(for: rec, force: false)
        }
    }

    /// Common path used by `summarizeIfNeeded` and `regenerate`.
    /// `force` controls whether an already-present summary is overwritten
    /// when the CLI returns.
    private func runSummary(for recording: Recording, force: Bool) {
        let id = recording.id
        // Dedup: a re-enqueue from the transcription path or a second
        // "Regenerate" tap while the first is in flight is a no-op so a
        // re-enqueue from the transcription path can't double-bill.
        guard inFlight[id] == nil else {
            summarizerLog.log("\(self.shortID(id), privacy: .public): skipped — already in flight")
            return
        }
        let tool = llmSettings.tool
        let executableOverride = llmSettings.executablePath.isEmpty
            ? nil
            : llmSettings.executablePath
        let model = liveAISettings.model
        let promptLanguageName: String = {
            switch liveAISettings.outputLanguage {
            case .auto:
                return recording.fullText.isPredominantlyHebrew ? "Hebrew" : "English"
            case .english:
                return "English"
            case .hebrew:
                return "Hebrew"
            }
        }()
        let prompt = liveAISettings.summaryPrompt
            .replacingOccurrences(of: "{{LANGUAGE}}", with: promptLanguageName)
        let transcript = recording.fullText
        let timeout = timeoutSeconds
        let startedAt = Date()

        inFlightIDs.insert(id)
        summarizerLog.log("started \(self.shortID(id), privacy: .public) transcript=\(transcript.count, privacy: .public)c force=\(force, privacy: .public)")

        let task = Task { @MainActor [weak self] in
            defer {
                // `return` cannot transfer control out of a defer body in
                // Swift, so an `if let self` block is what we want here
                // rather than an early-return guard. If the summarizer
                // has already deinit'd, there's nothing to clean up —
                // the dictionary and the publisher set went with it.
                if let self {
                    self.inFlight[id] = nil
                    self.inFlightIDs.remove(id)
                    // After each completion, try to pull the next
                    // queued backfill candidate in.
                    self.pumpBackfill()
                }
            }
            do {
                let raw = try await LLMRunner.run(
                    tool: tool,
                    prompt: prompt,
                    transcript: transcript,
                    executablePathOverride: executableOverride,
                    model: model.isEmpty ? nil : model,
                    timeout: timeout
                )
                let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else {
                    summarizerLog.log("skipped \(self?.shortID(id) ?? "?", privacy: .public): empty CLI output")
                    return
                }
                // The recording may have been deleted between enqueue
                // and now. Re-fetch so we never write a summary to a
                // ghost row.
                guard let self else { return }
                guard var current = self.store.recordings.first(where: { $0.id == id }) else {
                    summarizerLog.log("skipped \(self.shortID(id), privacy: .public): recording is gone")
                    return
                }
                let existing = (current.summary ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !force, !existing.isEmpty {
                    summarizerLog.log("skipped \(self.shortID(id), privacy: .public): a summary landed mid-flight")
                    return
                }
                current.summary = cleaned
                self.store.update(current)
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                summarizerLog.log("succeeded \(self.shortID(id), privacy: .public) length=\(cleaned.count, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms")
            } catch {
                summarizerLog.error("failed \(self?.shortID(id) ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        inFlight[id] = task
    }

    /// Log why a `summarizeIfNeeded` call was rejected. Split out so the
    /// reason ends up in OSLog (and Console.app) with the same
    /// "skipped <id>: <reason>" shape backfill uses.
    private func logSkip(_ recording: Recording, force: Bool) {
        let id = recording.id
        if !llmSettings.summaryEnabled {
            summarizerLog.log("skipped \(self.shortID(id), privacy: .public): auto-summary disabled")
            return
        }
        if !llmSettings.isConfigured {
            summarizerLog.log("skipped \(self.shortID(id), privacy: .public): LLM not configured")
            return
        }
        let transcript = recording.fullText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if transcript.isEmpty {
            summarizerLog.log("skipped \(self.shortID(id), privacy: .public): transcript empty")
            return
        }
        let existing = (recording.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !force, !existing.isEmpty {
            summarizerLog.log("skipped \(self.shortID(id), privacy: .public): already summarized")
            return
        }
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}
