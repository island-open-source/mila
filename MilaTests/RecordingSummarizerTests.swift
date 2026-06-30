import XCTest
@testable import Mila

/// Tests for the post-record summarizer that runs whenever the LLM CLI
/// is configured (not just when Live AI mode was active). End-to-end
/// invocation uses a shell script masquerading as `claude` so we don't
/// depend on the user having the real CLI installed — same trick as
/// `LLMRunnerTests`.
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
        // Short CLI timeout so a genuinely-stuck scripted CLI is SIGKILL'd in
        // seconds (bounding `awaitInFlight`, which awaits the real task) rather
        // than the 300s production default. The test scripts are instant; this
        // only caps a pathological hang under CI contention so the suite fails
        // fast instead of stalling.
        llm.cliTimeout = 15
        liveAI = LiveAISettings(defaults: liveDefaults)
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

    // MARK: - End-to-end via script-as-CLI

    /// Verify the summarizer actually writes the LLM output to the
    /// recording's `summary` field, and that the sidecar lands too.
    /// Uses a shell script in place of `claude` so the test runs without
    /// any real CLI installed.
    func test_summarize_stores_output_on_recording_and_writes_sidecar() async throws {
        let script = makeScript("""
            #!/bin/sh
            printf 'A concise summary of the meeting.'
            """)
        defer { try? FileManager.default.removeItem(at: script) }

        llm.tool = .claude
        llm.executablePath = script.path
        // Empty model so we don't pass --model to the script (which
        // would just be passed through as an arg the script ignores,
        // but cleaner to keep argv minimal).
        liveAI.model = ""

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
    /// `LLMRunner.composedPrompt`. A capturing stub records the exact argv so
    /// we assert the wire call the app makes — no real model, no API key.
    /// This is what replaced the old real-Anthropic e2e: instead of asking a
    /// live model and judging its answer, we verify Mila issues the correct
    /// invocation off the back of a transcription.
    func test_summarize_invokes_cli_with_transcript_in_one_shot_prompt() async throws {
        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-llm-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: capture) }

        // Stub `claude`: record every argv entry (NUL-separated, so prompts
        // containing newlines round-trip intact) to the capture file, then
        // emit a canned summary so the summarizer has output to store. The
        // capture path is baked into the script body rather than passed via
        // env, so we don't depend on ProcessInfo.environment snapshotting.
        let script = makeScript("""
            #!/bin/sh
            printf '%s\\0' "$@" > '\(capture.path)'
            printf 'A concise summary of the meeting.'
            """)
        defer { try? FileManager.default.removeItem(at: script) }

        llm.tool = .claude
        llm.executablePath = script.path
        liveAI.model = ""   // keep argv minimal: no --model passthrough

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

        // The CLI ran and its output was stored — proves the call completed.
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "A concise summary of the meeting.")

        // Assert the SHAPE of the call the app made.
        let data = try XCTUnwrap(try? Data(contentsOf: capture),
                                 "stub CLI was never invoked — no capture file written")
        let args = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertTrue(args.contains("-p"),
                      "claude must be invoked in one-shot `-p` mode; got argv=\(args)")
        let prompt = try XCTUnwrap(args.first { $0.contains(transcript) },
                                   "the transcript must be embedded in the prompt; argv=\(args)")
        XCTAssertTrue(prompt.contains("Transcript:"),
                      "prompt should use LLMRunner.composedPrompt's labelled format")
    }

    /// Empty CLI output must NOT clobber a (currently nil) summary — we
    /// don't want a wedged CLI to mask the recording as "summarized".
    func test_summarize_drops_empty_output() async throws {
        let script = makeScript("""
            #!/bin/sh
            # Print nothing.
            true
            """)
        defer { try? FileManager.default.removeItem(at: script) }

        llm.tool = .claude
        llm.executablePath = script.path

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
        // Await the real task: the (empty-output) CLI run completes and the
        // summarizer must have left the recording's summary alone.
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertNil(updated.summary)
    }

    /// If a live summary lands between enqueue and the CLI returning,
    /// the summarizer must NOT overwrite it. Simulated by having the
    /// script sleep for a moment while we patch the store mid-flight.
    func test_summarize_does_not_overwrite_summary_that_landed_mid_flight() async throws {
        let script = makeScript("""
            #!/bin/sh
            sleep 0.5
            printf 'OVERWRITE'
            """)
        defer { try? FileManager.default.removeItem(at: script) }

        llm.tool = .claude
        llm.executablePath = script.path

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
        // Patch the store mid-flight to simulate a live summary
        // landing while the one-shot CLI was still running.
        try await Task.sleep(nanoseconds: 100_000_000)
        if var current = store.recordings.first(where: { $0.id == rec.id }) {
            current.summary = "live_summary_from_recording"
            store.update(current)
        }

        // Await the real CLI task: when it returns it must NOT clobber the
        // summary that landed mid-flight.
        await summarizer.awaitInFlight(rec.id)
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "live_summary_from_recording",
                       "Late-arriving CLI output must not overwrite a summary that already exists")
    }

    /// End-to-end: with auto-summary disabled, a freshly transcribed
    /// recording must be left untouched — the CLI is never invoked and no
    /// summary lands. The script would write "SHOULD NOT RUN" if reached.
    func test_summarize_skips_when_auto_summary_disabled() async throws {
        let script = makeScript("""
            #!/bin/sh
            printf 'SHOULD NOT RUN'
            """)
        defer { try? FileManager.default.removeItem(at: script) }

        llm.tool = .claude
        llm.executablePath = script.path
        llm.summaryEnabled = false

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
        // `runSummary` is never reached, so no CLI task is ever spawned. Assert
        // that deterministically (no in-flight work), then await for safety —
        // `awaitInFlight` returns immediately when nothing is in flight.
        XCTAssertFalse(summarizer.isSummarizing(rec.id),
                       "Disabled auto-summary must not spawn a CLI task")
        await summarizer.awaitInFlight(rec.id)
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertNil(updated.summary,
                     "No summary should be written while auto-summary is disabled")
    }

    /// The explicit "Regenerate summary" affordance is a deliberate user
    /// action and must work even when AUTOMATIC summaries are turned off —
    /// the toggle governs the post-recording auto path, not on-demand use.
    func test_regenerate_works_even_when_auto_summary_disabled() async throws {
        let script = makeScript("""
            #!/bin/sh
            printf 'ON DEMAND'
            """)
        defer { try? FileManager.default.removeItem(at: script) }

        llm.tool = .claude
        llm.executablePath = script.path
        llm.summaryEnabled = false

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
        // Deterministic: await the actual in-flight task rather than polling
        // the store on a timer (which slipped under CI contention).
        await summarizer.awaitInFlight(rec.id)
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "ON DEMAND")
    }

    // MARK: - Force / regenerate path

    /// `regenerate(_:)` must overwrite an existing summary — that's the
    /// whole point of the affordance. Without this the "Regenerate
    /// summary" context-menu item and the re-transcribe hook would both
    /// silently no-op.
    func test_regenerate_overwrites_existing_summary() async throws {
        let script = makeScript("""
            #!/bin/sh
            printf 'REGENERATED'
            """)
        defer { try? FileManager.default.removeItem(at: script) }

        llm.tool = .claude
        llm.executablePath = script.path

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
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "old summary")
    }

    func test_regenerate_noops_when_transcript_empty() async throws {
        llm.tool = .claude
        let script = makeScript("""
            #!/bin/sh
            printf 'should not reach here'
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        llm.executablePath = script.path

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
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "old",
                       "Empty transcript must not trigger a CLI call")
    }

    /// `isSummarizing(_:)` flips true while a call is in flight and back
    /// to false when it lands. The detail view's spinner depends on this.
    func test_is_summarizing_tracks_in_flight_state() async throws {
        let script = makeScript("""
            #!/bin/sh
            sleep 0.3
            printf 'done'
            """)
        defer { try? FileManager.default.removeItem(at: script) }

        llm.tool = .claude
        llm.executablePath = script.path

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
        // the call returns — no sleep/yield needed.
        XCTAssertTrue(summarizer.isSummarizing(rec.id),
                      "isSummarizing should be true while CLI is running")

        // Await the real task completion rather than polling on a timer.
        await summarizer.awaitInFlight(rec.id)
        XCTAssertFalse(summarizer.isSummarizing(rec.id),
                       "isSummarizing should clear after CLI returns")
    }

    // MARK: - Helpers

    private func makeScript(_ body: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-summarizer-test-\(UUID().uuidString).sh")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url
    }
}
