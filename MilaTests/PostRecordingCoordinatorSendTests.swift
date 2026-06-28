import XCTest
import TranscriptionCore
@testable import Mila

/// Tests for `PostRecordingCoordinator`'s background "Send to <LLM>"
/// runner — the path the rename sheet's "Send to Claude" button and the
/// right-click "Send to <LLM>…" sheet now delegate to.
///
/// Like `RecordingSummarizerTests`, end-to-end invocation uses a shell
/// script masquerading as `claude` so the test runs without the real CLI
/// installed.
@MainActor
final class PostRecordingCoordinatorSendTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var coordinator: PostRecordingCoordinator!

    private let diarSuite = "PostRecordingCoordinatorSendTests.diarization"

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "PostRecordingCoordinatorSendTests")
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        manager = ModelManager(modelsDirectory: tempRoot.appendingPathComponent("Models"))
        stub = StubWhisperEngine()
        service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(defaults: .init(suiteName: diarSuite)!),
            engine: stub
        )
        coordinator = PostRecordingCoordinator(store: store, transcription: service,
                                               llm: LLMSettings(defaults: UserDefaults(suiteName: "PostRecordingCoordinatorSendTests.llm")!))
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        UserDefaults().removePersistentDomain(forName: diarSuite)
        try await super.tearDown()
    }

    // MARK: - Background send runs + survives the caller

    /// The send must run to completion on the coordinator even though the
    /// caller (the sheet) returns immediately. We assert the banner ends
    /// up carrying the scripted CLI output, and that `isSending` flips
    /// true while in flight and clears afterward (id-keyed bookkeeping).
    func test_send_runs_in_background_and_reports_via_banner() async throws {
        let script = makeScript("""
            #!/bin/sh
            sleep 0.3
            printf 'CLI ANSWER'
            """)
        defer { try? FileManager.default.removeItem(at: script) }

        let rec = addCompletedRecording(text: "the transcript text")

        XCTAssertFalse(coordinator.isSending(rec.id))
        coordinator.sendToLLM(recordingID: rec.id,
                              tool: .claude,
                              prompt: "Summarize",
                              transcript: "the transcript text",
                              summary: "",
                              executableOverride: script.path)
        // Yield so the task body starts and registers itself.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(coordinator.isSending(rec.id),
                      "isSending should be true while the CLI is running")

        try await waitForBanner(containing: "CLI ANSWER", timeoutSeconds: 30)
        XCTAssertFalse(coordinator.isSending(rec.id),
                       "isSending should clear once the CLI returns")
        XCTAssertEqual(coordinator.activityIsError, false)
    }

    /// A second send for the same recording id cancels + replaces the
    /// first — no two competing CLI calls writing the same banner.
    func test_second_send_for_same_id_replaces_the_first() async throws {
        // First script blocks long enough that the replacement lands while
        // it's still "running".
        let slow = makeScript("""
            #!/bin/sh
            sleep 5
            printf 'SLOW'
            """)
        let fast = makeScript("""
            #!/bin/sh
            printf 'FAST'
            """)
        defer {
            try? FileManager.default.removeItem(at: slow)
            try? FileManager.default.removeItem(at: fast)
        }

        let rec = addCompletedRecording(text: "transcript")

        coordinator.sendToLLM(recordingID: rec.id, tool: .claude, prompt: "p",
                              transcript: "transcript", summary: "",
                              executableOverride: slow.path)
        try await Task.sleep(nanoseconds: 100_000_000)
        coordinator.sendToLLM(recordingID: rec.id, tool: .claude, prompt: "p",
                              transcript: "transcript", summary: "",
                              executableOverride: fast.path)

        // The fast replacement wins; the slow one was cancelled (its
        // .cancelled error is swallowed silently).
        try await waitForBanner(containing: "FAST", timeoutSeconds: 30)
        XCTAssertFalse(coordinator.activityStatus?.contains("SLOW") ?? false,
                       "Replaced send must not surface its output")
    }

    // MARK: - Discard cancels an in-flight send

    /// Discarding the recording (cancelAndDiscard) must cancel a pending
    /// send so the CLI isn't left chewing on a transcript whose recording
    /// has been deleted out from under it. After discard, `isSending`
    /// clears and the recording is gone from the store.
    func test_discard_cancels_in_flight_send() async throws {
        let slow = makeScript("""
            #!/bin/sh
            sleep 10
            printf 'SHOULD NOT LAND'
            """)
        defer { try? FileManager.default.removeItem(at: slow) }

        // The recording must be `pending` in the coordinator for
        // cancelAndDiscard to act on it.
        let audioURL = store.freshAudioURL(suggestedName: "Discard")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(title: "Discard", source: .microphone,
                            audioFileName: audioURL.lastPathComponent,
                            fullText: "transcript")
        rec.status = .completed
        store.add(rec)
        coordinator.present(rec)

        coordinator.sendToLLM(recordingID: rec.id, tool: .claude, prompt: "p",
                              transcript: "transcript", summary: "",
                              executableOverride: slow.path)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(coordinator.isSending(rec.id))

        coordinator.cancelAndDiscard()
        // Cancellation propagates to the CLI (SIGTERM) — give it a beat.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(coordinator.isSending(rec.id),
                       "Discard must cancel + clear the in-flight send")
        XCTAssertNil(store.recordings.first(where: { $0.id == rec.id }),
                     "Discard permanently deletes the recording")
    }

    // MARK: - Fired before the transcript is ready

    /// "Send" can now be pressed before transcription finishes. With an
    /// empty transcript snapshot the coordinator waits for the recording
    /// to leave the in-progress states, then pulls the finished transcript
    /// from the store and sends THAT — rather than no-op'ing on empty.
    func test_send_waits_for_transcript_when_fired_early() async throws {
        // Script echoes back enough of its argv that we can confirm the
        // late-arriving transcript made it into the prompt.
        let script = makeScript("""
            #!/bin/sh
            printf 'sent:%s' "$2"
            """)
        defer { try? FileManager.default.removeItem(at: script) }

        // Recording starts in-progress with no text — mimics pressing
        // Send while whisper is still running.
        let audioURL = store.freshAudioURL(suggestedName: "Early")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(title: "Early", source: .microphone,
                            audioFileName: audioURL.lastPathComponent,
                            fullText: "")
        rec.status = .running
        store.add(rec)

        coordinator.sendToLLM(recordingID: rec.id, tool: .claude, prompt: "Do it",
                              transcript: "",  // empty: fired early
                              summary: "",
                              executableOverride: script.path)
        // It should still be in flight (waiting on the transcript), not
        // bailed out.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(coordinator.isSending(rec.id),
                      "Send should wait, not give up, on an empty transcript")

        // Transcription finishes a moment later.
        if var current = store.recordings.first(where: { $0.id == rec.id }) {
            current.fullText = "finished transcript"
            current.segments = [TranscriptSegment(start: 0, end: 1, text: "finished transcript")]
            current.status = .completed
            store.update(current)
        }

        try await waitForBanner(containing: "finished transcript", timeoutSeconds: 30)
        XCTAssertFalse(coordinator.isSending(rec.id))
    }

    // MARK: - Helpers

    /// Add a `.completed` recording with the given transcript text, with a
    /// placeholder audio file so `RecordingStore.add` is happy.
    private func addCompletedRecording(text: String) -> Recording {
        let audioURL = store.freshAudioURL(suggestedName: "Send")
        try? Data("not-audio".utf8).write(to: audioURL)
        var rec = Recording(title: "Send", source: .microphone,
                            audioFileName: audioURL.lastPathComponent,
                            fullText: text)
        rec.status = .completed
        store.add(rec)
        return rec
    }

    private func waitForBanner(containing needle: String,
                               timeoutSeconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let status = coordinator.activityStatus, status.contains(needle) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for banner containing \"\(needle)\" (was: \(coordinator.activityStatus ?? "nil"))")
    }

    private func makeScript(_ body: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-send-test-\(UUID().uuidString).sh")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url
    }
}
