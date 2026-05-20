import XCTest
import TranscriptionCore
@testable import IslandWhisper

final class TranscriptFormatterTests: XCTestCase {

    func test_no_speakers_returns_fallback_unchanged() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "hello"),
            TranscriptSegment(start: 1, end: 2, text: " world"),
        ]
        let formatted = TranscriptFormatter.plainText(
            segments: segments,
            fallback: "hello world"
        )
        XCTAssertEqual(formatted, "hello world",
                       "Without diarization the formatter must return the trimmed fallback verbatim — that's what the rest of the app stores in fullText.")
    }

    func test_two_speakers_each_get_their_own_line() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "Hi", speaker: "SPEAKER_00"),
            TranscriptSegment(start: 1, end: 2, text: "Hello back", speaker: "SPEAKER_01"),
        ]
        let formatted = TranscriptFormatter.plainText(
            segments: segments,
            fallback: "Hi Hello back"
        )
        XCTAssertEqual(formatted, "SPEAKER_00: Hi\nSPEAKER_01: Hello back")
    }

    func test_consecutive_same_speaker_segments_collapse_into_one_paragraph() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "First sentence.", speaker: "SPEAKER_00"),
            TranscriptSegment(start: 1, end: 2, text: "Second sentence.", speaker: "SPEAKER_00"),
            TranscriptSegment(start: 2, end: 3, text: "Other person.", speaker: "SPEAKER_01"),
            TranscriptSegment(start: 3, end: 4, text: "Continuing.", speaker: "SPEAKER_01"),
        ]
        let formatted = TranscriptFormatter.plainText(
            segments: segments,
            fallback: "ignored — segments path is taken"
        )
        XCTAssertEqual(
            formatted,
            """
            SPEAKER_00: First sentence. Second sentence.
            SPEAKER_01: Other person. Continuing.
            """
        )
    }

    func test_empty_segments_are_skipped_and_dont_split_a_paragraph() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "Hello", speaker: "SPEAKER_00"),
            TranscriptSegment(start: 1, end: 2, text: "   ", speaker: "SPEAKER_01"),
            TranscriptSegment(start: 2, end: 3, text: "Goodbye", speaker: "SPEAKER_00"),
        ]
        let formatted = TranscriptFormatter.plainText(
            segments: segments,
            fallback: ""
        )
        // The middle segment is whitespace-only and gets dropped entirely
        // — including its speaker label, which never had any audible
        // content attached to it. The two SPEAKER_00 turns then collapse
        // because no labelled-and-non-empty turn ever broke the run.
        XCTAssertEqual(formatted, "SPEAKER_00: Hello Goodbye")
    }

    func test_mixed_unlabelled_and_labelled_segments_render_unlabelled_segments_as_bare_lines() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "Untagged opener", speaker: nil),
            TranscriptSegment(start: 1, end: 2, text: "Tagged line", speaker: "SPEAKER_00"),
        ]
        let formatted = TranscriptFormatter.plainText(
            segments: segments,
            fallback: "ignored"
        )
        XCTAssertEqual(formatted, "Untagged opener\nSPEAKER_00: Tagged line")
    }
}
