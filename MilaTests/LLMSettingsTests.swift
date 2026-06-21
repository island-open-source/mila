import XCTest
@testable import Mila

/// Settings-model tests for `LLMSettings`. Isolated to a custom UserDefaults
/// suite per the project convention so they don't pollute (or read from) the
/// user's real `.standard` defaults.
@MainActor
final class LLMSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "LLMSettingsTests"

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    /// Fresh install: the "Send to LLM" content choice defaults to the
    /// transcript — preserving today's behaviour for users who don't touch
    /// the new setting.
    func test_send_content_defaults_to_transcript() {
        let settings = LLMSettings(defaults: defaults)
        XCTAssertEqual(settings.sendContent, .transcript)
    }

    func test_send_content_persists_across_instances() {
        let first = LLMSettings(defaults: defaults)
        first.sendContent = .summaryAndActionItems

        let reloaded = LLMSettings(defaults: defaults)
        XCTAssertEqual(reloaded.sendContent, .summaryAndActionItems)
    }
}
