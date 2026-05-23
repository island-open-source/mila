import XCTest

/// End-to-end GUI automation that proves the speaker-diarization
/// self-heal converges from a wiped state.
///
/// The test:
///   1. Removes `~/Library/Application Support/Mila/torch-site-
///      packages/` so the bootstrap + iterative self-heal both run from
///      scratch (no leftover caches from previous runs).
///   2. Launches the app.
///   3. Opens Settings → Speakers.
///   4. Toggles "Enable speaker diarization" on.
///   5. Waits up to 8 minutes for the badge to flip green (`probe == "ok"`).
///
/// 8 minutes is a generous budget: torch wheel download (~60 MB at slow
/// VPN speed) + numpy/matplotlib/Pillow installs + any iterative
/// self-heal passes. Runs on macos-15 in CI; locally completes in 1–2
/// minutes on a warm pip cache.
final class SpeakerSelfHealUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        wipeUserSitePackages()
    }

    /// Wipe `~/Library/Application Support/Mila/torch-site-packages/`
    /// before each run so the test always starts in the "nothing
    /// downloaded yet" state. Living in user-Application-Support means
    /// this is the same directory the production app reads from — wiping
    /// it here is equivalent to a first launch on a clean install.
    private func wipeUserSitePackages() {
        let fm = FileManager.default
        let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: false)
        guard let dir = appSupport?
            .appendingPathComponent("Mila", isDirectory: true)
            .appendingPathComponent("torch-site-packages", isDirectory: true)
        else { return }
        try? fm.removeItem(at: dir)
    }

    func test_self_heal_converges_to_ok_from_clean_state() throws {
        // The test downloads ~60 MB of torch wheels and waits up to 8
        // minutes for the diarization pipeline to converge. GitHub-hosted
        // runners are too flaky for that — network rate-limits, pip
        // cache stalls, and slow CPU all push it past the budget. We
        // still run it locally where a developer can wait out a real
        // pipeline failure.
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
                || ProcessInfo.processInfo.environment["CI"] == "true",
            "Skipping speakers self-heal e2e on CI — too slow + network-bound. Runs locally."
        )

        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-clean-store"]
        app.launch()

        // Open Settings via the menu bar (Cmd+,).
        let settingsApp = XCUIApplication()
        settingsApp.typeKey(",", modifierFlags: .command)

        // The SettingsView is a TabView. macOS exposes each tab as a
        // toolbar button; "Speakers" is the label.
        let speakersTab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Speakers'"))
            .firstMatch
        XCTAssertTrue(speakersTab.waitForExistence(timeout: 10),
                      "Speakers settings tab not found")
        speakersTab.click()

        // Toggle "Enable speaker diarization" on.
        let toggle = app.checkBoxes["speakers.enable.toggle"]
            .firstMatchIfAvailable
            ?? app.descendants(matching: .any)
                .matching(identifier: "speakers.enable.toggle")
                .firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "Enable-speakers toggle not found")
        if toggle.value as? String != "1" {
            toggle.click()
        }

        // Watch the probe for ok. Polls every 5s for up to 8 minutes.
        let probe = app.descendants(matching: .any)
            .matching(identifier: "speakers.health.ok.probe")
            .firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 30),
                      "ok-probe view never appeared in the Speakers tab")

        let deadline = Date().addingTimeInterval(8 * 60)
        var converged = false
        while Date() < deadline {
            if probe.label == "ok" {
                converged = true
                break
            }
            Thread.sleep(forTimeInterval: 5)
        }
        XCTAssertTrue(converged,
                      "Speakers self-heal did not converge to ok within 8 min (probe label: '\(probe.label)')")
    }
}

private extension XCUIElement {
    /// `firstMatch` on an empty query produces an element that exists
    /// but is invalid. This helper returns nil in that case so the
    /// caller can fall back to a different lookup.
    var firstMatchIfAvailable: XCUIElement? {
        exists ? self : nil
    }
}
