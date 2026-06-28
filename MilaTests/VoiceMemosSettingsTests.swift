import XCTest
@testable import Mila

@MainActor
final class VoiceMemosSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "VoiceMemosSettingsTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let suiteName { defaults.removePersistentDomain(forName: suiteName) }
        try await super.tearDown()
    }

    func test_defaults_areOffAndEmpty() {
        let settings = VoiceMemosSettings(defaults: defaults)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertTrue(settings.selectedFolderUUIDs.isEmpty)
        XCTAssertFalse(settings.includeUnfiled)
        XCTAssertFalse(settings.hasSelection)
    }

    func test_selectionPersistsAcrossInstances() {
        let settings = VoiceMemosSettings(defaults: defaults)
        settings.isEnabled = true
        settings.setFolder("UUID-A", selected: true)
        settings.setFolder("UUID-B", selected: true)
        settings.includeUnfiled = true

        let reloaded = VoiceMemosSettings(defaults: defaults)
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertEqual(reloaded.selectedFolderUUIDs, ["UUID-A", "UUID-B"])
        XCTAssertTrue(reloaded.includeUnfiled)
        XCTAssertTrue(reloaded.hasSelection)
    }

    func test_setFolder_removesDeselected() {
        let settings = VoiceMemosSettings(defaults: defaults)
        settings.setFolder("UUID-A", selected: true)
        settings.setFolder("UUID-A", selected: false)
        XCTAssertTrue(settings.selectedFolderUUIDs.isEmpty)
    }

    func test_hasSelection_trueWithOnlyUnfiled() {
        let settings = VoiceMemosSettings(defaults: defaults)
        settings.includeUnfiled = true
        XCTAssertTrue(settings.hasSelection)
    }
}
