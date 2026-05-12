import XCTest
@testable import IslandWhisper

/// Integration tests for the file-import + transcribe pipeline that runs when
/// the user clicks "Open Files" or drops an audio file onto the app.
///
/// We can't easily exercise live mic / system-audio capture in a unit test
/// (no permissions in CI, no real audio source), but the exact same final
/// path — store add + service.enqueue — is shared with `stopRecording`,
/// so this gives us strong coverage of the wiring change.
@MainActor
final class QuickActionsControllerTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var session: RecordingSession!
    private var languageSettings: RecordingLanguageSettings!
    private var controller: QuickActionsController!
    private var languageDefaults: UserDefaults!
    private let languageSuite = "QuickActionsControllerTests.language"

    private var savedSelection: String?

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "QuickActionsControllerTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        store = RecordingStore(rootDirectory: tempRoot)
        manager = ModelManager(modelsDirectory: tempRoot.appendingPathComponent("Models"))
        savedSelection = UserDefaults.standard.string(forKey: "selectedModelName")
        try TestSupport.installFakeModel(into: manager)

        stub = StubWhisperEngine()
        service = TranscriptionService(store: store, modelManager: manager, engine: stub)
        session = RecordingSession()
        UserDefaults().removePersistentDomain(forName: languageSuite)
        languageDefaults = UserDefaults(suiteName: languageSuite)
        languageSettings = RecordingLanguageSettings(defaults: languageDefaults)
        controller = QuickActionsController(session: session,
                                            store: store,
                                            transcription: service,
                                            languageSettings: languageSettings,
                                            postRecording: PostRecordingCoordinator(
                                                store: store,
                                                transcription: service))
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        if let savedSelection {
            UserDefaults.standard.set(savedSelection, forKey: "selectedModelName")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedModelName")
        }
        languageDefaults?.removePersistentDomain(forName: languageSuite)
        try await super.tearDown()
    }

    // MARK: - File import → enqueue → transcribe

    func test_transcribe_file_adds_recording_and_kicks_off_transcription() async throws {
        let sourceURL = tempRoot.appendingPathComponent("imported.wav")
        try TestSupport.writeStereo48kSineWav(at: sourceURL, durationSeconds: 0.5)
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 0.5, text: "imported text")
        ])

        let beforeCount = store.recordings.count
        await controller.transcribeFile(sourceURL)
        await service.waitForIdle()

        XCTAssertEqual(store.recordings.count, beforeCount + 1)
        let imported = try XCTUnwrap(store.recordings.first { $0.title == "imported" })
        XCTAssertEqual(imported.status, .completed)
        XCTAssertEqual(imported.fullText, "imported text")
        XCTAssertEqual(controller.activeJob, .none)
    }

    /// REGRESSION: Importing two files in quick succession used to hold the
    /// second one in `await transcription.transcribe`, blocking until the
    /// first finished and never showing the second as queued. With the new
    /// `enqueue` path, both should be visible in the queue immediately.
    func test_back_to_back_file_imports_both_complete_in_order() async throws {
        let first = tempRoot.appendingPathComponent("first.wav")
        let second = tempRoot.appendingPathComponent("second.wav")
        try TestSupport.writeStereo48kSineWav(at: first, durationSeconds: 0.4)
        try TestSupport.writeStereo48kSineWav(at: second, durationSeconds: 0.4)

        await stub.setDefaultDelay(0.1)
        await stub.setCannedQueue([
            [TranscriptSegment(start: 0, end: 1, text: "first transcript")],
            [TranscriptSegment(start: 0, end: 1, text: "second transcript")]
        ])

        await controller.transcribeFile(first)
        await controller.transcribeFile(second)
        await service.waitForIdle()

        let firstStored = try XCTUnwrap(store.recordings.first { $0.title == "first" })
        let secondStored = try XCTUnwrap(store.recordings.first { $0.title == "second" })

        XCTAssertEqual(firstStored.fullText, "first transcript")
        XCTAssertEqual(secondStored.fullText, "second transcript")

        let maxConcurrent = await stub.maxConcurrentInFlight
        XCTAssertEqual(maxConcurrent, 1)
    }

    // MARK: - State machine

    func test_active_job_is_none_initially() {
        XCTAssertEqual(controller.activeJob, .none)
        XCTAssertFalse(controller.isRecording)
    }

    func test_failed_file_import_clears_active_job() async {
        let bogus = tempRoot.appendingPathComponent("does-not-exist.wav")
        await controller.transcribeFile(bogus)
        XCTAssertEqual(controller.activeJob, .none)
        XCTAssertNotNil(service.lastError)
    }

    /// File imports must adopt whatever language is currently selected in
    /// the toolbar dropdown — otherwise the user picks "English" but their
    /// dragged-in WAV gets routed to the Hebrew model.
    func test_imported_file_uses_language_from_settings() async throws {
        try TestSupport.installFakeModel(into: manager, model: .openaiTurbo)
        let source = tempRoot.appendingPathComponent("english-source.wav")
        try TestSupport.writeStereo48kSineWav(at: source, durationSeconds: 0.4)

        languageSettings.current = .english
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1, text: "english import")
        ])

        await controller.transcribeFile(source)
        await service.waitForIdle()

        let imported = try XCTUnwrap(store.recordings.first { $0.title == "english-source" })
        XCTAssertEqual(imported.language, "en",
                       "Imported recording must reflect the user-selected language")
        let loaded = await stub.loadedModel
        XCTAssertEqual(loaded?.lastPathComponent,
                       manager.url(for: .openaiTurbo).lastPathComponent,
                       "English-tagged recording must be transcribed with the OpenAI model")
    }

    /// Explicit reproduction of the user-reported bug: enqueue, then
    /// "make a new recording" while the first is still transcribing — the
    /// second must end up with its own transcript, not stay stuck on the
    /// previous one.
    func test_user_bug_repro_second_recording_after_first_started_transcribing() async throws {
        let first = tempRoot.appendingPathComponent("recording-A.wav")
        let second = tempRoot.appendingPathComponent("recording-B.wav")
        try TestSupport.writeStereo48kSineWav(at: first, durationSeconds: 0.6)
        try TestSupport.writeStereo48kSineWav(at: second, durationSeconds: 0.6)

        await stub.setDefaultDelay(0.4)
        await stub.setCannedQueue([
            [TranscriptSegment(start: 0, end: 1, text: "A says hi")],
            [TranscriptSegment(start: 0, end: 1, text: "B says hello")]
        ])

        // Start the first import (this returns once the recording is added
        // and enqueued — does NOT wait for transcription).
        await controller.transcribeFile(first)

        // While the first is still transcribing, kick off the second.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(service.activeRecordingID)
        await controller.transcribeFile(second)

        // After everything settles, both recordings should have the right text.
        await service.waitForIdle()

        let storedA = try XCTUnwrap(store.recordings.first { $0.title == "recording-A" })
        let storedB = try XCTUnwrap(store.recordings.first { $0.title == "recording-B" })
        XCTAssertEqual(storedA.fullText, "A says hi",
                       "First recording should have its own transcript")
        XCTAssertEqual(storedB.fullText, "B says hello",
                       "Second recording must NOT show the first recording's transcript")
        XCTAssertEqual(storedA.status, .completed)
        XCTAssertEqual(storedB.status, .completed)
    }
}
