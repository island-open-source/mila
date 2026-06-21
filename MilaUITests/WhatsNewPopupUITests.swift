import XCTest

/// UI test for the pre-update "What's New" popup.
///
/// The popup normally appears only when Sparkle's scheduled background poll
/// finds a newer published version — which can't be exercised locally or in
/// CI. So the app exposes a `--ui-test-show-whats-new` launch arg that forces
/// `UpdaterViewModel.availableUpdate` to a fixture with bulleted release
/// notes (see `UpdaterViewModel.init` in `MilaApp.swift`). This test drives
/// that seam and asserts the popup renders its highlights and the prominent
/// "Update Now" button.
final class WhatsNewPopupUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_whats_new_popup_shows_highlights_and_update_button() {
        let app = XCUIApplication()
        // --ui-test-clean-store keeps the test off the user's real data;
        // --ui-test-show-whats-new forces the popup with fixture content.
        app.launchArguments = ["--ui-test-clean-store", "--ui-test-show-whats-new"]
        app.launch()

        // The popup is presented as a sheet on first render.
        let popup = app.descendants(matching: .any)
            .matching(identifier: "whatsNew.popup")
            .firstMatch
        XCTAssertTrue(popup.waitForExistence(timeout: 10),
                      "What's New popup did not appear")

        // Title carries the fixture version.
        let title = app.descendants(matching: .any)
            .matching(identifier: "whatsNew.title")
            .firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5),
                      "What's New title not found")
        XCTAssertTrue(title.label.contains("9.9.9"),
                      "Title should mention the fixture version, got '\(title.label)'")

        // At least the first parsed highlight bullet is shown.
        let firstHighlight = app.descendants(matching: .any)
            .matching(identifier: "whatsNew.highlight.0")
            .firstMatch
        XCTAssertTrue(firstHighlight.waitForExistence(timeout: 5),
                      "First highlight row not found")

        // The prominent "Update Now" button is present and hittable.
        let updateNow = app.descendants(matching: .any)
            .matching(identifier: "whatsNew.updateNow")
            .firstMatch
        XCTAssertTrue(updateNow.waitForExistence(timeout: 5),
                      "Update Now button not found")
        XCTAssertTrue(updateNow.isHittable, "Update Now button is not hittable")

        // And the low-key "Later" dismiss exists; clicking it dismisses the
        // popup gracefully (no Sparkle install dialog kicks in).
        let later = app.descendants(matching: .any)
            .matching(identifier: "whatsNew.later")
            .firstMatch
        XCTAssertTrue(later.waitForExistence(timeout: 5),
                      "Later button not found")
        later.click()

        XCTAssertTrue(popup.waitForNonExistence(timeout: 5),
                      "What's New popup did not dismiss after tapping Later")
    }
}
