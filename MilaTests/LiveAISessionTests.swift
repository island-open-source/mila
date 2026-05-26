import XCTest
@testable import Mila

/// Unit tests for the LLM JSON parsing + dedup in `LiveAISession`. We
/// don't spawn the actual `claude` / `cursor-agent` CLI here — those
/// tests live in `LLMRunnerTests.swift` and are gated on the binary
/// being present. The parser is pure, so it's the part most worth
/// pinning down: bad output from the model is the most common failure
/// mode in practice.
@MainActor
final class LiveAISessionTests: XCTestCase {

    func test_parseActionItems_strict_json_array_round_trips() {
        let json = """
        [
          {"id":"a1","text":"Send the slides","speaker":"SPEAKER_00","timestamp_seconds":42.0,"source":"inferred"},
          {"id":"v1","text":"Remind Bob to file his expenses","speaker":null,"timestamp_seconds":120,"source":"voice_command"}
        ]
        """
        let items = LiveAISession.parseActionItems(from: json)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, "a1")
        XCTAssertEqual(items[0].text, "Send the slides")
        XCTAssertEqual(items[0].speaker, "SPEAKER_00")
        XCTAssertEqual(items[0].timestampSeconds, 42.0, accuracy: 0.001)
        XCTAssertEqual(items[0].source, .llmInferred)
        XCTAssertEqual(items[1].id, "v1")
        XCTAssertNil(items[1].speaker)
        XCTAssertEqual(items[1].source, .voiceCommand)
    }

    func test_parseActionItems_extracts_array_from_prose_wrapper() {
        // The CLI sometimes prefixes "Here is the JSON:" even when told
        // to output JSON only. We pluck out the first balanced array
        // rather than insisting on a clean parse.
        let raw = """
        Here is the JSON you asked for:
        [{"id":"x","text":"Do the thing","speaker":null,"timestamp_seconds":0,"source":"inferred"}]
        That should cover it.
        """
        let items = LiveAISession.parseActionItems(from: raw)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "x")
        XCTAssertEqual(items[0].text, "Do the thing")
    }

    func test_parseActionItems_handles_code_fences() {
        let raw = """
        ```json
        [{"id":"f1","text":"Fenced item","speaker":null,"timestamp_seconds":0,"source":"inferred"}]
        ```
        """
        let items = LiveAISession.parseActionItems(from: raw)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "f1")
    }

    func test_parseActionItems_skips_items_with_missing_fields() {
        // The LLM occasionally emits items without an id or with an
        // empty text. Those are dropped rather than crashing the parser.
        let raw = """
        [
          {"text":"no id here","speaker":null,"timestamp_seconds":0,"source":"inferred"},
          {"id":"","text":"empty id","speaker":null,"timestamp_seconds":0,"source":"inferred"},
          {"id":"keep","text":"","speaker":null,"timestamp_seconds":0,"source":"inferred"},
          {"id":"good","text":"keeper","speaker":null,"timestamp_seconds":0,"source":"inferred"}
        ]
        """
        let items = LiveAISession.parseActionItems(from: raw)
        XCTAssertEqual(items.map(\.id), ["good"])
    }

    func test_parseActionItems_empty_array_yields_no_items() {
        XCTAssertTrue(LiveAISession.parseActionItems(from: "[]").isEmpty)
    }

    func test_parseActionItems_returns_empty_on_unparseable_output() {
        XCTAssertTrue(LiveAISession.parseActionItems(from: "I cannot find any action items.").isEmpty)
        XCTAssertTrue(LiveAISession.parseActionItems(from: "").isEmpty)
        XCTAssertTrue(LiveAISession.parseActionItems(from: "[unterminated").isEmpty)
    }

    func test_findFirstJSONArray_handles_nested_arrays() {
        // The outer array opens at idx 0 and closes after the inner
        // close-bracket — the parser must track depth, not just the
        // first close.
        let s = #"[{"id":"a","text":"hi","speaker":null,"timestamp_seconds":0,"source":"inferred","tags":["x","y"]}]"#
        let range = LiveAISession.findFirstJSONArray(in: s)
        XCTAssertNotNil(range)
        let extracted = String(s[range!])
        // The extracted string should round-trip through JSON decode.
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: extracted.data(using: .utf8)!))
    }

    func test_findFirstJSONArray_ignores_brackets_inside_strings() {
        // Bracket characters inside quoted strings must NOT mess with
        // depth tracking. This catches the "naive depth counter" bug.
        let s = #"prefix [{"id":"a","text":"He said [verbatim]","speaker":null,"timestamp_seconds":0,"source":"inferred"}] suffix"#
        let range = LiveAISession.findFirstJSONArray(in: s)
        XCTAssertNotNil(range)
        let extracted = String(s[range!])
        XCTAssertTrue(extracted.hasSuffix("]"))
        XCTAssertTrue(extracted.hasPrefix("["))
    }
}
