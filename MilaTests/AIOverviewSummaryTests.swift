import XCTest
@testable import Mila

/// Covers `AIOverviewSection.summaryAttributed` — the saved-recording
/// summary renderer. A single-paragraph summary is split into one bullet
/// per sentence; the key risk (the bug a naive ".!?" split introduced) is
/// chopping decimals / abbreviations / domains / URLs mid-token.
final class AIOverviewSummaryTests: XCTestCase {

    private func plain(_ a: AttributedString) -> String { String(a.characters) }

    func test_multiSentence_paragraph_splits_into_bullets() {
        let s = "We shipped the beta. Dana will send the deck. Yossi books the room."
        let out = plain(AIOverviewSection.summaryAttributed(s))
        let bulletLines = out.components(separatedBy: "\n").filter { $0.contains("•") }
        XCTAssertEqual(bulletLines.count, 3, "three sentences → three bullet lines")
    }

    func test_decimals_and_abbreviations_are_not_split_midtoken() {
        let s = "The sync is at 3.30 p.m. and the budget is 1.5M."
        let out = plain(AIOverviewSection.summaryAttributed(s))
        XCTAssertTrue(out.contains("3.30"), "decimal time must stay intact")
        XCTAssertTrue(out.contains("1.5M"), "decimal figure must stay intact")
        XCTAssertFalse(out.contains("3.\u{00A0}") || out.contains("•\u{00A0}30"),
                       "must not bullet in the middle of a decimal")
    }

    func test_domains_and_urls_are_not_split() {
        let s = "Check acme.com and https://example.com/path for details."
        let out = plain(AIOverviewSection.summaryAttributed(s))
        XCTAssertTrue(out.contains("acme.com"))
        XCTAssertTrue(out.contains("https://example.com/path"))
    }

    func test_single_sentence_is_not_bulleted() {
        let out = plain(AIOverviewSection.summaryAttributed("Just one short note."))
        XCTAssertFalse(out.contains("•"), "a single sentence shouldn't get a bullet")
    }

    func test_empty_or_blank_is_safe() {
        XCTAssertTrue(plain(AIOverviewSection.summaryAttributed("")).isEmpty)
        XCTAssertTrue(plain(AIOverviewSection.summaryAttributed("   ")).isEmpty)
    }

    func test_existing_multiline_markdown_is_preserved() {
        let s = "**Topic:** test\n\n- did a thing\n- found a bug"
        let out = plain(AIOverviewSection.summaryAttributed(s))
        // Already structured → kept as-is (not re-bulleted by sentence split).
        XCTAssertTrue(out.contains("did a thing"))
        XCTAssertTrue(out.contains("found a bug"))
    }
}
