import XCTest
@testable import Mila

/// Unit tests for the pure logic behind the pre-update "What's New" popup:
///   - parsing appcast release notes into scannable highlights
///   - the "show popup for available version X vs last-seen Y" gate
final class WhatsNewUpdateTests: XCTestCase {

    // MARK: - Highlight parsing

    func test_parsesHTMLListItemsAsHighlights() {
        let notes = """
        <h2>What's New in 1.9.0</h2>
        <ul>
          <li>Faster live transcription</li>
          <li>Better speaker labels</li>
          <li>New diagnostic export</li>
        </ul>
        """
        let update = WhatsNewUpdate(displayVersion: "1.9.0", releaseNotesHTML: notes)
        XCTAssertEqual(update.highlights, [
            "Faster live transcription",
            "Better speaker labels",
            "New diagnostic export"
        ])
    }

    func test_stripsInnerTagsAndDecodesEntitiesInListItems() {
        let notes = "<ul><li>Fixed <b>crash</b> &amp; sped things up</li></ul>"
        let update = WhatsNewUpdate(displayVersion: "1.9.0", releaseNotesHTML: notes)
        XCTAssertEqual(update.highlights, ["Fixed crash & sped things up"])
    }

    func test_parsesPlainTextBulletLinesWhenNoHTMLList() {
        let notes = """
        - Live AI summaries
        - Stable speaker labels
        * Diagnostic export
        """
        let update = WhatsNewUpdate(displayVersion: "1.9.0", releaseNotesHTML: notes)
        XCTAssertEqual(update.highlights, [
            "Live AI summaries",
            "Stable speaker labels",
            "Diagnostic export"
        ])
    }

    func test_fallsBackToProseLinesWhenNothingBulleted() {
        let notes = "This release improves performance.\nIt also fixes a few bugs."
        let update = WhatsNewUpdate(displayVersion: "1.9.0", releaseNotesHTML: notes)
        XCTAssertEqual(update.highlights, [
            "This release improves performance.",
            "It also fixes a few bugs."
        ])
    }

    func test_cappsHighlightsAtMax() {
        let items = (1...12).map { "<li>Highlight \($0)</li>" }.joined()
        let notes = "<ul>\(items)</ul>"
        let update = WhatsNewUpdate(displayVersion: "2.0.0", releaseNotesHTML: notes)
        XCTAssertEqual(update.highlights.count, WhatsNewUpdate.maxHighlights)
        XCTAssertEqual(update.highlights.first, "Highlight 1")
    }

    func test_emptyNotesYieldNoHighlights() {
        let update = WhatsNewUpdate(displayVersion: "1.9.0", releaseNotesHTML: nil)
        XCTAssertTrue(update.highlights.isEmpty)
        XCTAssertTrue(update.fullNotes.isEmpty)
    }

    // MARK: - Show / last-seen gate

    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "WhatsNewUpdateTests.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func test_showsWhenNeverSeenBefore() {
        let gate = WhatsNewGate(defaults: freshDefaults())
        XCTAssertTrue(gate.shouldShow(availableVersion: "1.9.0"))
    }

    func test_doesNotShowSameVersionTwice() {
        let defaults = freshDefaults()
        let gate = WhatsNewGate(defaults: defaults)
        XCTAssertTrue(gate.shouldShow(availableVersion: "1.9.0"))
        gate.markSeen(version: "1.9.0")
        XCTAssertFalse(gate.shouldShow(availableVersion: "1.9.0"))
    }

    func test_showsAgainForADifferentVersion() {
        let defaults = freshDefaults()
        let gate = WhatsNewGate(defaults: defaults)
        gate.markSeen(version: "1.9.0")
        XCTAssertFalse(gate.shouldShow(availableVersion: "1.9.0"))
        // A newer advertised version should re-show even though we saw 1.9.0.
        XCTAssertTrue(gate.shouldShow(availableVersion: "1.9.1"))
    }

    func test_emptyVersionNeverShows() {
        let gate = WhatsNewGate(defaults: freshDefaults())
        XCTAssertFalse(gate.shouldShow(availableVersion: ""))
        XCTAssertFalse(gate.shouldShow(availableVersion: "   "))
    }

    func test_lastSeenPersistsAcrossGateInstances() {
        let defaults = freshDefaults()
        WhatsNewGate(defaults: defaults).markSeen(version: "1.9.0")
        // A fresh gate reading the same defaults must see the persisted value.
        XCTAssertEqual(WhatsNewGate(defaults: defaults).lastSeenVersion, "1.9.0")
        XCTAssertFalse(WhatsNewGate(defaults: defaults).shouldShow(availableVersion: "1.9.0"))
    }
}
