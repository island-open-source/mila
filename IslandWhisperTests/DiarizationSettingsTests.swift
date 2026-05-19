import XCTest
@testable import IslandWhisper

@MainActor
final class DiarizationSettingsTests: XCTestCase {

    private var tempRoot: URL!
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "DiarizationSettingsTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defaultsSuiteName = "DiarizationSettingsTests.\(UUID())"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        if let defaultsSuiteName { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        try await super.tearDown()
    }

    // MARK: - Regression test for the launch-time gate bug

    /// Regression: if the user previously enabled diarization AND torch was
    /// already installed in the user-writable site-packages, the first
    /// transcription after each app launch silently skipped diarization.
    ///
    /// Cause: `bootstrap.isReady` defaults to `false`, and the `didSet` on
    /// `isEnabled` that would have called `bootstrap.bootstrapIfNeeded()`
    /// (which calls `refreshReadyState()`) does NOT fire when the value is
    /// assigned in `init`. So the file-existence check that flips
    /// `isReady` to `true` never ran, and `isConfigured` returned `false`.
    ///
    /// Fix: `DiarizationSettings.init` now calls `bootstrap.refreshReadyState()`
    /// explicitly. This test stages a fake bundled-python + installed-torch
    /// layout, restores `isEnabled = true` from UserDefaults, and asserts
    /// the gate now reports configured at construction time.
    func test_init_refreshes_bootstrap_ready_state_so_isConfigured_is_true_at_launch() throws {
        let bundledPython = try makeFakeBundledPython()
        let sitePackages = try makeFakeTorchSitePackages()

        defaults.set(true, forKey: "diarization.enabled")

        let bootstrap = DiarizationBootstrap(bundledPython: bundledPython.path,
                                             sitePackages: sitePackages)
        XCTAssertFalse(bootstrap.isReady,
                       "Sanity: bootstrap.isReady must default to false; the fix is that init flips it.")

        let settings = DiarizationSettings(defaults: defaults, bootstrap: bootstrap)

        XCTAssertTrue(bootstrap.isReady,
                      "init must refresh bootstrap.isReady from disk; otherwise the gate locks closed even when torch is installed.")
        XCTAssertTrue(settings.hasBundledRuntime,
                      "hasBundledRuntime must reflect the injected bootstrap.")
        XCTAssertTrue(settings.isConfigured,
                      "isConfigured must be true when isEnabled persists + bootstrap files exist on disk.")
    }

    /// The opposite case: when torch is NOT yet installed (only bundled
    /// python exists), `isConfigured` must stay false so transcription
    /// proceeds without speaker labels rather than launching a subprocess
    /// that's doomed to fail.
    func test_init_leaves_isConfigured_false_when_torch_missing() throws {
        let bundledPython = try makeFakeBundledPython()
        let emptySitePackages = tempRoot.appendingPathComponent("empty-site")
        try FileManager.default.createDirectory(at: emptySitePackages, withIntermediateDirectories: true)

        defaults.set(true, forKey: "diarization.enabled")

        let bootstrap = DiarizationBootstrap(bundledPython: bundledPython.path,
                                             sitePackages: emptySitePackages)
        let settings = DiarizationSettings(defaults: defaults, bootstrap: bootstrap)

        XCTAssertFalse(bootstrap.isReady)
        XCTAssertTrue(settings.hasBundledRuntime)
        XCTAssertFalse(settings.isConfigured,
                       "isConfigured must remain false until torch is installed, even after the init refresh.")
    }

    // MARK: - Fixtures

    private func makeFakeBundledPython() throws -> URL {
        let url = tempRoot.appendingPathComponent("python3.11")
        try Data().write(to: url)
        return url
    }

    private func makeFakeTorchSitePackages() throws -> URL {
        let site = tempRoot.appendingPathComponent("torch-site")
        for pkg in ["torch", "torchaudio"] {
            let initFile = site.appendingPathComponent(pkg).appendingPathComponent("__init__.py")
            try FileManager.default.createDirectory(at: initFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data().write(to: initFile)
        }
        return site
    }
}
