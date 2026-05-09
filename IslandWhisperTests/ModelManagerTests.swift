import XCTest
@testable import IslandWhisper

@MainActor
final class ModelManagerTests: XCTestCase {

    private var tempRoot: URL!

    private var savedSelection: String?

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelManagerTests-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        savedSelection = UserDefaults.standard.string(forKey: "selectedModelName")
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        if let savedSelection {
            UserDefaults.standard.set(savedSelection, forKey: "selectedModelName")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedModelName")
        }
        super.tearDown()
    }

    func test_catalog_contains_ivrit_large_as_default_selected_model() {
        let mgr = ModelManager(modelsDirectory: tempRoot)
        XCTAssertNotNil(mgr.selectedModel())
        XCTAssertEqual(mgr.selectedModelName, WhisperModel.ivritLarge.name,
                       "Default selection should be the ivrit.ai large-v3 Hebrew model")
        XCTAssertEqual(WhisperModel.all.contains { $0.name.contains("ivrit") },
                       true,
                       "Expected at least one ivrit.ai model in the catalog")
    }

    func test_models_have_consistent_metadata() {
        for model in WhisperModel.all {
            XCTAssertFalse(model.name.isEmpty)
            XCTAssertFalse(model.displayName.isEmpty)
            XCTAssertGreaterThan(model.sizeBytes, 100_000_000, "\(model.name) size implausibly small")
            XCTAssertEqual(model.url.scheme, "https")
            XCTAssertTrue(model.url.host?.contains("huggingface.co") == true,
                          "Expected HuggingFace URL for \(model.name)")
        }
    }

    func test_url_for_model_lives_under_models_directory() {
        let mgr = ModelManager(modelsDirectory: tempRoot)
        let url = mgr.url(for: WhisperModel.ivritLarge)
        XCTAssertEqual(url.deletingLastPathComponent().path, tempRoot.path)
        XCTAssertEqual(url.lastPathComponent, "ivrit-ai-whisper-large-v3.bin")
    }

    func test_install_state_reflects_files_in_directory() throws {
        let mgr = ModelManager(modelsDirectory: tempRoot)
        XCTAssertFalse(mgr.isInstalled(.ivritLarge))

        let path = mgr.url(for: .ivritLarge)
        try Data("not-a-real-model".utf8).write(to: path)
        mgr.refreshInstalled()
        XCTAssertTrue(mgr.isInstalled(.ivritLarge))

        try mgr.delete(.ivritLarge)
        XCTAssertFalse(mgr.isInstalled(.ivritLarge))
    }

    func test_set_selected_persists_choice() {
        let mgr = ModelManager(modelsDirectory: tempRoot)
        mgr.setSelected(.openaiTurbo)
        XCTAssertEqual(mgr.selectedModelName, WhisperModel.openaiTurbo.name)

        let reloaded = ModelManager(modelsDirectory: tempRoot)
        XCTAssertEqual(reloaded.selectedModelName, WhisperModel.openaiTurbo.name)
    }

    func test_best_model_for_language_routes_hebrew_to_ivrit() {
        XCTAssertEqual(WhisperModel.bestModel(for: "he"), .ivritLarge)
        XCTAssertEqual(WhisperModel.bestModel(for: "iw"), .ivritLarge)
        XCTAssertEqual(WhisperModel.bestModel(for: "en"), .openaiTurbo)
        XCTAssertEqual(WhisperModel.bestModel(for: "auto"), .openaiTurbo)
    }

    func test_model_for_language_falls_back_to_selected_when_best_not_installed() throws {
        let mgr = ModelManager(modelsDirectory: tempRoot)
        // Install only the OpenAI turbo, then ask for the Hebrew best model.
        let openaiPath = mgr.url(for: .openaiTurbo)
        try Data("not-a-real-model".utf8).write(to: openaiPath)
        mgr.refreshInstalled()
        mgr.setSelected(.openaiTurbo)

        // Hebrew best is ivritLarge (not installed) so we should fall back.
        let resolved = mgr.model(for: "he")
        XCTAssertEqual(resolved, .openaiTurbo)
    }
}
