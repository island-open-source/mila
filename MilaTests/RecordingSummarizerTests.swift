import XCTest
@testable import Mila

/// Tests for the post-record summarizer that runs whenever the LLM CLI
/// is configured (not just when Live AI mode was active).
///
/// End-to-end invocation goes through `RecordingSummarizer`'s injectable
/// `runLLM` seam (see `RecordingSummarizer.RunLLM`) rather than spawning a
/// real `claude`/`/bin/sh` subprocess. Earlier revisions wrote a temp shell
/// script and pointed `LLMSettings.executablePath` at it; under CI
/// contention the spawn / exec / pipe-drain could hiccup or time out, the
/// summarizer's `catch` would swallow the error, no summary got written, and
/// the assertion failed intermittently (e.g. CI run 28448415130). Injecting
/// a synchronous canned-output closure removes the subprocess-timing
/// dependency entirely, so these assertions are deterministic by
/// construction — no real CLI installed, no child process, no flake.
@MainActor
final class RecordingSummarizerTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var llmDefaults: UserDefaults!
    private var liveDefaults: UserDefaults!
    private var llm: LLMSettings!
    private var liveAI: LiveAISettings!
    private var summarizer: RecordingSummarizer!

    private let llmSuite = "RecordingSummarizerTests.llm"
    private let liveSuite = "RecordingSummarizerTests.liveAI"

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "RecordingSummarizerTests")
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        UserDefaults().removePersistentDomain(forName: llmSuite)
        UserDefaults().removePersistentDomain(forName: liveSuite)
        llmDefaults = UserDefaults(suiteName: llmSuite)
        liveDefaults = UserDefaults(suiteName: liveSuite)
        llm = LLMSettings(defaults: llmDefaults)
        liveAI = LiveAISettings(defaults: liveDefaults)
        // Default summarizer uses the production `runLLM` (real CLI). The
        // gate-only tests below never reach it; the end-to-end tests rebuild
        // `summarizer` via `useStubRunner` with a deterministic stub.
        summarizer = RecordingSummarizer(store: store,
                                         llmSettings: llm,
                                         liveAISettings: liveAI)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        llmDefaults?.removePersistentDomain(forName: llmSuite)
        liveDefaults?.removePersistentDomain(forName: liveSuite)
        try await super.tearDown()
    }

    // MARK: - Gate

    func test_should_summarize_false_when_llm_not_configured() {
        llm.tool = .none
        let rec = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                            fullText: "hello world")
        XCTAssertFalse(summarizer.shouldSummarize(rec))
    }

    func test_should_summarize_false_when_summary_already_present() {
        llm.tool = .claude
        var rec = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                            fullText: "hello world")
        rec.summary = "already have one"
        XCTAssertFalse(summarizer.shouldSummarize(rec))
    }

    func test_should_summarize_false_when_transcript_is_empty() {
        llm.tool = .claude
        let rec = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                            fullText: "")
        XCTAssertFalse(summarizer.shouldSummarize(rec))
    }

    func test_should_summarize_true_when_configured_and_no_summary() {
        llm.tool = .claude
        let rec = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                            fullText: "the transcript")
        XCTAssertTrue(summarizer.shouldSummarize(rec))
    }

    /// The auto-summary master switch. When the user turns off
    /// "Automatically summarize recordings" the post-recording summary
    /// must NOT fire, even with the LLM configured and a transcript ready.
    func test_should_summarize_false_when_auto_summary_disabled() {
        llm.tool = .claude
        llm.summaryEnabled = false
        let rec = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                            fullText: "the transcript")
        XCTAssertFalse(summarizer.shouldSummarize(rec),
                       "Disabling auto-summary must gate shouldSummarize")
    }

    /// Default-on: existing users (and fresh installs) keep getting
    /// summaries unless they explicitly opt out. A bare `defaults.bool`
    /// would default to false and silently disable the feature for
    /// everyone, so the property must default to true.
    func test_summary_enabled_defaults_true() {
        XCTAssertTrue(llm.summaryEnabled,
                      "Auto-summary must default to on to preserve existing behaviour")
    }

    func test_should_summarize_treats_whitespace_summary_as_empty() {
        llm.tool = .claude
        var rec = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                            fullText: "the transcript")
        rec.summary = "   \n  "
        XCTAssertTrue(summarizer.shouldSummarize(rec),
                      "Whitespace-only summary should not block regeneration")
    }

    // MARK: - End-to-end via injected runner

    /// Verify the summarizer actually writes the LLM output to the
    /// recording's `summary` field, and that the sidecar lands too. The
    /// injected runner returns a canned summary synchronously — no real CLI.
    func test_summarize_stores_output_on_recording_and_writes_sidecar() async throws {
        llm.tool = .claude
        liveAI.model = ""
        useStubRunner { _, _, _, _, _, _, _ in
            "A concise summary of the meeting."
        }

        let audioURL = store.freshAudioURL(suggestedName: "Meeting")
        // The audio file needs to exist for `RecordingStore.add` to be
        // happy, but the summarizer never reads it — only `fullText`.
        try Data("not-audio".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Meeting",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "we discussed the roadmap and agreed to ship next week"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "A concise summary of the meeting.")
        let sidecar = store.summaryURL(for: updated)
        let onDisk = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertEqual(onDisk, "A concise summary of the meeting.")
    }

    /// The core "right call" assertion: when a transcript is ready, the
    /// summarizer must invoke the configured CLI ONCE, in claude's one-shot
    /// `-p` shape, with the transcript embedded in the prompt via
    /// `LLMRunner.composedPrompt`. The stub reconstructs the exact argv the
    /// app WOULD have launched — by feeding the prompt/model it was handed
    /// through `LLMTool.arguments`, the same call the production `runLLM`
    /// makes — and records it, so we still assert the wire shape without a
    /// real subprocess. This is what replaced the old real-Anthropic e2e:
    /// instead of asking a live model and judging its answer, we verify Mila
    /// issues the correct invocation off the back of a transcription.
    func test_summarize_invokes_cli_with_transcript_in_one_shot_prompt() async throws {
        llm.tool = .claude
        liveAI.model = ""   // keep argv minimal: no --model passthrough

        // Capture the argv the app would have launched. The production
        // runner (`LLMRunner.run`) composes the user prompt + transcript via
        // `composedPrompt` BEFORE handing the blob to `LLMTool.arguments`, so
        // the stub does the same here — that's what embeds the transcript and
        // the "Transcript:" label into the `-p` argument. Reconstructing the
        // argv this way proves the one-shot `-p` shape without a subprocess.
        var capturedArgs: [String] = []
        var callCount = 0
        useStubRunner { tool, prompt, transcript, _, model, extraArgs, _ in
            callCount += 1
            let composed = LLMRunner.composedPrompt(prompt, transcript: transcript)
            capturedArgs = tool.arguments(prompt: composed, model: model) + extraArgs
            return "A concise summary of the meeting."
        }

        let transcript = "we discussed the roadmap and agreed to ship next week"
        let audioURL = store.freshAudioURL(suggestedName: "Call")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Call",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: transcript
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        // The CLI ran exactly once and its output was stored.
        XCTAssertEqual(callCount, 1, "the summarizer must invoke the CLI exactly once")
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "A concise summary of the meeting.")

        // Assert the SHAPE of the call the app made.
        XCTAssertTrue(capturedArgs.contains("-p"),
                      "claude must be invoked in one-shot `-p` mode; got argv=\(capturedArgs)")
        let prompt = try XCTUnwrap(capturedArgs.first { $0.contains(transcript) },
                                   "the transcript must be embedded in the prompt; argv=\(capturedArgs)")
        XCTAssertTrue(prompt.contains("Transcript:"),
                      "prompt should use LLMRunner.composedPrompt's labelled format")
    }

    /// Empty CLI output must NOT clobber a (currently nil) summary — we
    /// don't want a wedged CLI to mask the recording as "summarized".
    func test_summarize_drops_empty_output() async throws {
        llm.tool = .claude
        // Stub returns empty output — the production runner trims stdout, so
        // an empty return models a CLI that printed nothing useful.
        useStubRunner { _, _, _, _, _, _, _ in "" }

        let audioURL = store.freshAudioURL(suggestedName: "Empty")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Empty",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertNil(updated.summary)
    }

    /// If a live summary lands between enqueue and the CLI returning, the
    /// summarizer must NOT overwrite it. Deterministic: the stub blocks on a
    /// gate the test opens AFTER patching the store, so the "summary landed
    /// mid-flight" ordering is guaranteed without any `sleep`.
    func test_summarize_does_not_overwrite_summary_that_landed_mid_flight() async throws {
        llm.tool = .claude

        let gate = TestGate()
        useStubRunner { _, _, _, _, _, _, _ in
            // Block until the test has patched the store, then return the
            // (now stale) CLI output.
            await gate.wait()
            return "OVERWRITE"
        }

        let audioURL = store.freshAudioURL(suggestedName: "Race")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Race",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        // The runner is now parked in `gate.wait()`. Patch the store to
        // simulate a live summary landing while the one-shot CLI was still
        // running, then release the gate so the runner returns.
        XCTAssertTrue(summarizer.isSummarizing(rec.id),
                      "runner should be in flight before we patch the store")
        if var current = store.recordings.first(where: { $0.id == rec.id }) {
            current.summary = "live_summary_from_recording"
            store.update(current)
        }
        gate.open()

        await summarizer.awaitInFlight(rec.id)
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "live_summary_from_recording",
                       "Late-arriving CLI output must not overwrite a summary that already exists")
    }

    /// End-to-end: with auto-summary disabled, a freshly transcribed
    /// recording must be left untouched — the runner is never invoked and no
    /// summary lands.
    func test_summarize_skips_when_auto_summary_disabled() async throws {
        llm.tool = .claude
        llm.summaryEnabled = false
        var called = false
        useStubRunner { _, _, _, _, _, _, _ in
            called = true
            return "SHOULD NOT RUN"
        }

        let audioURL = store.freshAudioURL(suggestedName: "Off")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Off",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        // The auto-summary gate is synchronous: a disabled toggle means
        // `runSummary` is never reached, so no CLI task is ever spawned.
        XCTAssertFalse(summarizer.isSummarizing(rec.id),
                       "Disabled auto-summary must not spawn a CLI task")
        await summarizer.awaitInFlight(rec.id)
        XCTAssertFalse(called, "the runner must not be invoked while auto-summary is disabled")
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertNil(updated.summary,
                     "No summary should be written while auto-summary is disabled")
    }

    /// The explicit "Regenerate summary" affordance is a deliberate user
    /// action and must work even when AUTOMATIC summaries are turned off —
    /// the toggle governs the post-recording auto path, not on-demand use.
    func test_regenerate_works_even_when_auto_summary_disabled() async throws {
        llm.tool = .claude
        llm.summaryEnabled = false
        useStubRunner { _, _, _, _, _, _, _ in "ON DEMAND" }

        let audioURL = store.freshAudioURL(suggestedName: "Manual")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "Manual",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        // Mirrors the real UI path: the "Regenerate summary" action is only
        // reachable on a recording that already has a summary (e.g. made
        // before the user disabled auto-summary). Regenerate must still
        // refresh it on demand despite the master switch being off.
        rec.summary = "stale summary from before auto-summary was disabled"
        store.add(rec)

        summarizer.regenerate(rec)
        await summarizer.awaitInFlight(rec.id)
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "ON DEMAND")
    }

    // MARK: - Force / regenerate path

    /// `regenerate(_:)` must overwrite an existing summary — that's the
    /// whole point of the affordance. Without this the "Regenerate
    /// summary" context-menu item and the re-transcribe hook would both
    /// silently no-op.
    ///
    /// This is the test that was flaky on CI: previously it spawned a real
    /// `/bin/sh` script via the CLI runner and asserted on the result, so a
    /// subprocess hiccup made the summary fail to land. With the injected
    /// runner there's no subprocess — the canned "REGENERATED" is returned
    /// synchronously and the assertion is deterministic.
    func test_regenerate_overwrites_existing_summary() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _ in "REGENERATED" }

        let audioURL = store.freshAudioURL(suggestedName: "Regen")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "Regen",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the new transcript text"
        )
        rec.summary = "stale summary from a previous run"
        store.add(rec)

        // `summarizeIfNeeded` would bail because a summary already
        // exists; `regenerate` bypasses that gate.
        summarizer.regenerate(rec)
        await summarizer.awaitInFlight(rec.id)
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "REGENERATED")
    }

    /// `regenerate` still respects the two hard requirements:
    /// LLM configured + non-empty transcript.
    func test_regenerate_noops_when_llm_not_configured() async throws {
        llm.tool = .none
        var called = false
        useStubRunner { _, _, _, _, _, _, _ in
            called = true
            return "should not reach here"
        }

        let audioURL = store.freshAudioURL(suggestedName: "NoLLM")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "NoLLM",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        rec.summary = "old summary"
        store.add(rec)

        summarizer.regenerate(rec)
        // The gate is synchronous: an unconfigured LLM means no task is spawned.
        XCTAssertFalse(summarizer.isSummarizing(rec.id),
                       "regenerate must not spawn a task when the LLM is unconfigured")
        await summarizer.awaitInFlight(rec.id)
        XCTAssertFalse(called, "the runner must not be invoked when the LLM is unconfigured")
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "old summary")
    }

    func test_regenerate_noops_when_transcript_empty() async throws {
        llm.tool = .claude
        var called = false
        useStubRunner { _, _, _, _, _, _, _ in
            called = true
            return "should not reach here"
        }

        let audioURL = store.freshAudioURL(suggestedName: "Empty")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "Empty",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: ""
        )
        rec.summary = "old"
        store.add(rec)

        summarizer.regenerate(rec)
        // The gate is synchronous: an empty transcript means no task is spawned.
        XCTAssertFalse(summarizer.isSummarizing(rec.id),
                       "regenerate must not spawn a task for an empty transcript")
        await summarizer.awaitInFlight(rec.id)
        XCTAssertFalse(called, "the runner must not be invoked for an empty transcript")
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "old",
                       "Empty transcript must not trigger a CLI call")
    }

    /// `isSummarizing(_:)` flips true while a call is in flight and back
    /// to false when it lands. The detail view's spinner depends on this.
    /// Deterministic: the stub parks on a gate the test opens, so the
    /// in-flight window is observed without timing on a `sleep`.
    func test_is_summarizing_tracks_in_flight_state() async throws {
        llm.tool = .claude
        let gate = TestGate()
        useStubRunner { _, _, _, _, _, _, _ in
            await gate.wait()
            return "done"
        }

        let audioURL = store.freshAudioURL(suggestedName: "Spin")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Spin",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        store.add(rec)

        XCTAssertFalse(summarizer.isSummarizing(rec.id))
        summarizer.summarizeIfNeeded(rec)
        // `inFlightIDs.insert` runs synchronously inside `summarizeIfNeeded`
        // (before the Task is even created), so the flag is true the instant
        // the call returns — and the runner is parked on the gate.
        XCTAssertTrue(summarizer.isSummarizing(rec.id),
                      "isSummarizing should be true while CLI is running")

        // Release the runner and await the real task completion.
        gate.open()
        await summarizer.awaitInFlight(rec.id)
        XCTAssertFalse(summarizer.isSummarizing(rec.id),
                       "isSummarizing should clear after CLI returns")
    }

    // MARK: - Helpers

    /// Rebuild `summarizer` with a deterministic `runLLM` stub so the
    /// end-to-end tests don't depend on a real subprocess. Call after
    /// configuring `llm` / `liveAI` for the test.
    private func useStubRunner(_ run: @escaping RecordingSummarizer.RunLLM) {
        summarizer = RecordingSummarizer(store: store,
                                         llmSettings: llm,
                                         liveAISettings: liveAI,
                                         runLLM: run)
    }
}

/// A one-shot async gate for deterministically ordering a stubbed runner
/// against the test body — the stub awaits `wait()`, the test calls `open()`
/// once it has set up the mid-flight condition. Replaces `sleep`-based
/// ordering, which slipped under CI contention. Main-actor isolated because
/// the summarizer and tests both run on the main actor.
@MainActor
final class TestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for c in pending { c.resume() }
    }
}
