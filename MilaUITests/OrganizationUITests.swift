import XCTest

/// End-to-end tests for the data-organization features:
///   - inline rename of a recording from the detail view
///   - folder create / assign / filter
///
/// The app is launched with `--ui-test-clean-store` (so it never touches the
/// user's real Application Support directory) plus `--ui-test-seed-recording`
/// (so we always have one recording to act on). See `RecordingStore.init()`.
final class OrganizationUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-clean-store", "--ui-test-seed-recording"]
        app.launch()
        return app
    }

    /// Click a sidebar entry by its accessibility identifier. SwiftUI's
    /// macOS sidebar surfaces rows as outline items, but the identifier we
    /// set on the inner Label still propagates — we find it via the generic
    /// `.any` descendant query instead of betting on the precise element type.
    private func tapSidebarCategory(_ app: XCUIApplication, _ identifier: String) {
        let item = app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5),
                      "Sidebar item '\(identifier)' not found")
        item.click()
    }

    func test_seed_recording_visible_in_default_folder() {
        // The Transcriptions / Meetings / Dictations history categories
        // were collapsed into a single "Default" virtual folder; the
        // seeded recording (folder == nil) now lives there.
        let app = launchApp()
        tapSidebarCategory(app, "sidebar.folder.default")

        let row = app.descendants(matching: .any)
            .matching(identifier: "history.row.Seed Recording")
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "Seeded recording not visible in Default folder")
    }

    func test_rename_recording_via_detail_inline_edit() {
        let app = launchApp()
        tapSidebarCategory(app, "sidebar.folder.default")

        let row = app.descendants(matching: .any)
            .matching(identifier: "history.row.Seed Recording")
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()

        // Click the title label in the detail header to enter edit mode.
        let titleLabel = app.descendants(matching: .any)
            .matching(identifier: "detail.title.label")
            .firstMatch
        XCTAssertTrue(titleLabel.waitForExistence(timeout: 5),
                      "Detail title label not found")
        titleLabel.click()

        let titleField = app.textFields["detail.title.field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 3),
                      "Inline title field did not appear")
        // Select-all + replace, so we don't depend on the current cursor pos.
        titleField.typeKey("a", modifierFlags: .command)
        titleField.typeText("Renamed by UI Test\r")

        // Title in the Default folder list now reflects the new name.
        tapSidebarCategory(app, "sidebar.folder.default")
        let renamedRow = app.descendants(matching: .any)
            .matching(identifier: "history.row.Renamed by UI Test")
            .firstMatch
        XCTAssertTrue(renamedRow.waitForExistence(timeout: 5),
                      "Renamed recording did not appear in the list")
    }

    func test_create_folder_from_sidebar_and_navigate_to_empty_folder() {
        let app = launchApp()

        // Section-header buttons in SwiftUI's macOS sidebar can land outside
        // `app.buttons` — the safer query is a flat .any/identifier match
        // (same pattern we use for sidebar rows).
        let newFolderButton = app.descendants(matching: .any)
            .matching(identifier: "sidebar.folders.new")
            .firstMatch
        XCTAssertTrue(newFolderButton.waitForExistence(timeout: 5),
                      "New-folder button not found in sidebar")
        newFolderButton.click()

        let nameField = app.descendants(matching: .any)
            .matching(identifier: "folder.name.field")
            .firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 3),
                      "Folder-name sheet did not appear")
        // The sheet animates in — `waitForExistence` returns as soon as the
        // element is in the hierarchy, but a click can still land mid-animation
        // and miss the field's hit area ("not hittable"). Wait for the
        // isHittable predicate to flip true before tapping.
        let hittable = NSPredicate(format: "isHittable == YES")
        let hittableExp = expectation(for: hittable, evaluatedWith: nameField)
        wait(for: [hittableExp], timeout: 3)
        nameField.click()
        nameField.typeText("Work")
        let confirmButton = app.descendants(matching: .any)
            .matching(identifier: "folder.name.confirm")
            .firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 2),
                      "Folder-confirm button missing")
        confirmButton.click()

        // The new folder appears in the sidebar (and the detail navigates
        // straight to its empty list).
        let folderRow = app.descendants(matching: .any)
            .matching(identifier: "sidebar.folder.Work")
            .firstMatch
        XCTAssertTrue(folderRow.waitForExistence(timeout: 5),
                      "New folder did not appear in sidebar")
        let folderList = app.descendants(matching: .any)
            .matching(identifier: "folder.list.Work")
            .firstMatch
        XCTAssertTrue(folderList.waitForExistence(timeout: 3),
                      "Folder list view did not render")
    }
}
