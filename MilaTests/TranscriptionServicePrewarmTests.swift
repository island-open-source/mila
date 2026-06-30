import XCTest
import TranscriptionCore
@testable import Mila

/// Cover the "first-time model load preparing banner" plumbing:
/// the engine fires a preparation observer around `loadIfNeeded`,
/// `TranscriptionService` bridges that onto its `@Published`
/// `isPreparingModel` / `preparationStatus`, and `prewarm` kicks the
/// load on a detached task. Without this regression test, an engine
/// change that drops the observer callback would silently revert the
/// HomeView "Preparing AI…" UX.
@MainActor
final class TranscriptionServicePrewarmTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "TranscriptionServicePrewarmTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        manager = ModelManager(modelsDirectory: tempRoot.appendingPathComponent("Models"))
        try TestSupport.installFakeModel(into: manager)
        stub = StubWhisperEngine()
        service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(defaults: .init(suiteName: "TranscriptionServicePrewarmTests.diarization")!),
            remoteSettings: TestSupport.isolatedRemoteSettings(label: "TranscriptionServicePrewarmTests"),
            engine: stub
        )
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try await super.tearDown()
    }

    func test_prewarm_kicks_loadIfNeeded_on_default_language_model() async throws {
        let initialCount = await stub.loadCallCount
        XCTAssertEqual(initialCount, 0)
        service.prewarm(language: "he")
        // Polled wait: the prewarm task is detached, so we can't rely on a
        // single yield. The deadline is generous (15s) because the heavy CI
        // `build-and-test` job can delay detached-Task scheduling well past
        // 1s under load (that was the observed flake). The loop breaks the
        // instant the call lands, so a longer ceiling costs nothing normally.
        let deadline = Date().addingTimeInterval(15.0)
        var count = 0
        while Date() < deadline {
            count = await stub.loadCallCount
            if count > 0 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(count, 1, "prewarm should have triggered exactly one loadIfNeeded")
    }

    func test_preparing_state_flips_around_slow_load() async throws {
        // Configure the stub to emulate a real first-time CoreML
        // compile: emit the observer's `true` signal, sleep, then
        // emit `false`. We pick 150ms so the test can observe the
        // intermediate state without being flaky.
        await stub.setLoadDelay(0.15)
        await stub.setLoadPreparationStatus("Preparing Neural Engine…")

        // Initial state — no load in flight.
        XCTAssertFalse(service.isPreparingModel)
        XCTAssertNil(service.preparationStatus)

        // Kick the load. The observer fires twice in total:
        // `true` synchronously inside the stub's `loadIfNeeded`, then
        // `false` after the sleep. Both hops trampoline through
        // `Task { @MainActor }` so we poll the @Published values.
        service.prewarm(language: "he")

        // Poll until we observe the preparing=true state.
        var sawPreparing = false
        var observedStatus: String?
        let preparingDeadline = Date().addingTimeInterval(15.0)
        while Date() < preparingDeadline {
            if service.isPreparingModel {
                sawPreparing = true
                observedStatus = service.preparationStatus
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(sawPreparing, "isPreparingModel should flip to true while loadIfNeeded is in flight")
        XCTAssertEqual(observedStatus, "Preparing Neural Engine…",
                       "preparationStatus should mirror the engine-supplied caption")

        // Poll until we observe the load finishing.
        let doneDeadline = Date().addingTimeInterval(15.0)
        while Date() < doneDeadline {
            if !service.isPreparingModel { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(service.isPreparingModel,
                       "isPreparingModel should flip back to false after loadIfNeeded returns")
        XCTAssertNil(service.preparationStatus,
                     "preparationStatus should clear once preparation ends")
    }

    func test_prewarm_no_op_when_model_not_installed() async throws {
        // Wipe the fake model so the manager reports nothing installed.
        // setSelected to a model that wasn't installed; `isInstalled`
        // returns false → prewarm should bail before calling the engine.
        let url = manager.url(for: .ivritLarge)
        try? FileManager.default.removeItem(at: url)
        manager.refreshInstalled()

        service.prewarm(language: "he")
        // Give the (no-op) detached task a moment to *not* fire.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let finalCount = await stub.loadCallCount
        XCTAssertEqual(finalCount, 0,
                       "prewarm should not load anything when no model is installed")
        XCTAssertFalse(service.isPreparingModel)
    }
}
