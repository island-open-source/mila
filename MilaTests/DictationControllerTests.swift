import XCTest
import TranscriptionCore
@testable import Mila

@MainActor
final class DictationControllerTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var hotkeys: HotkeySettings!
    private var defaultsSuite: UserDefaults!
    private var savedSelection: String?

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "DictationControllerTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        manager = ModelManager(modelsDirectory: tempRoot.appendingPathComponent("Models"))
        savedSelection = UserDefaults.standard.string(forKey: "selectedModelName")
        try TestSupport.installFakeModel(into: manager, model: .ivritLarge)
        try TestSupport.installFakeModel(into: manager, model: .openaiTurbo)
        stub = StubWhisperEngine()
        service = TranscriptionService(store: store, modelManager: manager, diarizationSettings: DiarizationSettings(defaults: .init(suiteName: "DictationControllerTests.diarization")!), remoteSettings: TestSupport.isolatedRemoteSettings(label: "DictationControllerTests"), engine: stub)

        UserDefaults().removePersistentDomain(forName: "DictationControllerTests")
        defaultsSuite = UserDefaults(suiteName: "DictationControllerTests")
        hotkeys = HotkeySettings(defaults: defaultsSuite)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        if let savedSelection {
            UserDefaults.standard.set(savedSelection, forKey: "selectedModelName")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedModelName")
        }
        defaultsSuite.removePersistentDomain(forName: "DictationControllerTests")
        try await super.tearDown()
    }

    /// `transcribeOnce` must route Hebrew audio to the ivrit.ai model and
    /// English audio to the OpenAI turbo, even when a different model is
    /// "selected" globally. This is the dictation-language plumbing the new
    /// per-language hotkeys depend on.
    func test_transcribe_once_uses_language_specific_model() async {
        manager.setSelected(.ivritLarge)
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1, text: "hello world")
        ])
        let samples = [Float](repeating: 0.05, count: 16_000)

        _ = await service.transcribeOnce(samples: samples, language: "en")

        let loaded = await stub.loadedModel
        XCTAssertEqual(loaded?.lastPathComponent,
                       manager.url(for: .openaiTurbo).lastPathComponent,
                       "English dictation must load the OpenAI turbo model")
    }

    func test_transcribe_once_routes_hebrew_to_ivrit_model() async {
        manager.setSelected(.openaiTurbo)
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1, text: "שלום עולם")
        ])
        let samples = [Float](repeating: 0.05, count: 16_000)

        _ = await service.transcribeOnce(samples: samples, language: "he")

        let loaded = await stub.loadedModel
        XCTAssertEqual(loaded?.lastPathComponent,
                       manager.url(for: .ivritLarge).lastPathComponent,
                       "Hebrew dictation must load the ivrit.ai large-v3 model")
    }

    /// The TranscriptionService must forward `shutdown` to the engine. This
    /// is the fix path for the on-quit `ggml_abort` crash documented in the
    /// AppDelegate — without it, libc++ destroys the metal-device vector at
    /// `exit()` time before our context is freed.
    func test_shutdown_propagates_to_engine() async {
        await service.shutdown()
        let count = await stub.shutdownCount
        XCTAssertEqual(count, 1)
    }
}
