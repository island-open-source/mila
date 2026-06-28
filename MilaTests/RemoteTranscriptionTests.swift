import XCTest
import TranscriptionCore
@testable import Mila

@MainActor
final class RemoteTranscriptionSettingsTests: XCTestCase {

    private func makeSettings(_ label: String = #function) -> RemoteTranscriptionSettings {
        let suite = UserDefaults(suiteName: "RemoteTranscriptionSettingsTests.\(label)")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionSettingsTests.\(label)")
        return RemoteTranscriptionSettings(defaults: suite)
    }

    func test_defaults_areLocalAndOpenAI() {
        let settings = makeSettings()
        XCTAssertEqual(settings.backend, .local)
        XCTAssertFalse(settings.isActive)
        XCTAssertEqual(settings.endpoint, RemoteTranscriptionSettings.defaultEndpoint)
        XCTAssertEqual(settings.model, RemoteTranscriptionSettings.defaultModel)
    }

    func test_isConfigured_requiresKeyForOpenAI() {
        let settings = makeSettings()
        settings.backend = .remote
        settings.endpoint = "https://api.openai.com/v1"
        settings.apiKey = ""
        XCTAssertFalse(settings.isConfigured, "OpenAI endpoint must require a key")
        settings.apiKey = "sk-test"
        XCTAssertTrue(settings.isConfigured)
    }

    func test_isConfigured_allowsAnonymousSelfHosted() {
        let settings = makeSettings()
        settings.backend = .remote
        settings.endpoint = "http://localhost:8000/v1"
        settings.apiKey = ""
        XCTAssertTrue(settings.isConfigured, "Self-hosted endpoints may be anonymous")
    }

    func test_endpointURL_rejectsGarbage() {
        let settings = makeSettings()
        settings.endpoint = "not a url"
        XCTAssertNil(settings.endpointURL)
        settings.endpoint = "ftp://example.com"
        XCTAssertNil(settings.endpointURL, "Only http(s) is allowed")
        settings.endpoint = "https://example.com/v1"
        XCTAssertNotNil(settings.endpointURL)
    }

    func test_currentConfig_trimsAndFallsBackModel() {
        let settings = makeSettings()
        settings.backend = .remote
        settings.endpoint = "  https://example.com/v1  "
        settings.model = "   "
        let config = settings.currentConfig()
        XCTAssertEqual(config?.endpoint.absoluteString, "https://example.com/v1")
        XCTAssertEqual(config?.model, RemoteTranscriptionSettings.defaultModel)
    }

    func test_editingEndpointResetsTestStatus() {
        let settings = makeSettings()
        settings.endpoint = "https://example.com/v1"
        // testStatus starts .idle; just assert mutation path doesn't crash and
        // stays idle without a network call.
        XCTAssertEqual(settings.testStatus, .idle)
    }
}

final class RemoteWhisperEngineParsingTests: XCTestCase {

    func test_parsesVerboseJSONSegments() throws {
        let json = """
        {
          "task": "transcribe",
          "language": "hebrew",
          "duration": 5.0,
          "text": "שלום עולם",
          "segments": [
            { "id": 0, "start": 0.0, "end": 2.5, "text": " שלום" },
            { "id": 1, "start": 2.5, "end": 5.0, "text": " עולם" }
          ]
        }
        """.data(using: .utf8)!

        let segments = try RemoteWhisperEngine.parseSegments(data: json)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, 0.0)
        XCTAssertEqual(segments[1].end, 5.0)
        // Original text preserved (leading space intact for joining).
        XCTAssertEqual(segments[0].text, " שלום")
    }

    func test_fallsBackToSingleSegmentWhenNoSegments() throws {
        let json = """
        { "text": "hello world", "duration": 3.2 }
        """.data(using: .utf8)!

        let segments = try RemoteWhisperEngine.parseSegments(data: json)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[0].end, 3.2)
        XCTAssertEqual(segments[0].text, "hello world")
    }

    func test_throwsOnEmptyResult() {
        let json = """
        { "text": "   ", "segments": [] }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try RemoteWhisperEngine.parseSegments(data: json))
    }

    func test_multipartBodyContainsRequiredFields() {
        let audio = Data([0x00, 0x01, 0x02, 0x03])
        let body = RemoteWhisperEngine.multipartBody(boundary: "B",
                                                     audio: audio,
                                                     model: "whisper-1",
                                                     language: "he")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"model\""))
        XCTAssertTrue(text.contains("whisper-1"))
        XCTAssertTrue(text.contains("name=\"response_format\""))
        XCTAssertTrue(text.contains("verbose_json"))
        XCTAssertTrue(text.contains("name=\"language\""))
        XCTAssertTrue(text.contains("filename=\"audio.m4a\""))
        XCTAssertTrue(text.contains("--B--"), "Must be terminated with the closing boundary")
    }

    func test_multipartBodyOmitsLanguageWhenAuto() {
        let body = RemoteWhisperEngine.multipartBody(boundary: "B",
                                                     audio: Data(),
                                                     model: "whisper-1",
                                                     language: "auto")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("name=\"language\""),
                       "Auto-detect must omit the language field")
    }
}
