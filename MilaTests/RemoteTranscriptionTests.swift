import XCTest
import TranscriptionCore
@testable import Mila

@MainActor
final class RemoteTranscriptionSettingsTests: XCTestCase {

    private func makeSettings(_ label: String = #function) -> RemoteTranscriptionSettings {
        let suite = UserDefaults(suiteName: "RemoteTranscriptionSettingsTests.\(label)")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionSettingsTests.\(label)")
        // Isolated Keychain item so these tests never read/clobber the real
        // app's `remote.apiKey`.
        return RemoteTranscriptionSettings(defaults: suite,
                                           apiKeyKeychainKey: "RemoteTranscriptionSettingsTests.\(label).apiKey")
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

    func test_localBackend_doesNotReadKeychain() {
        // Seed a real token under an isolated key, then construct with the
        // default (local) backend. A local-only user must come up with an empty
        // apiKey and we must NOT have read the Keychain (which would prompt).
        let key = "RemoteTranscriptionSettingsTests.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        KeychainHelper.save(key: key, value: "sk-stored")
        defer { KeychainHelper.delete(key: key) }

        let suite = UserDefaults(suiteName: "RemoteTranscriptionSettingsTests.\(#function)")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionSettingsTests.\(#function)")
        let settings = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: key)

        XCTAssertEqual(settings.backend, .local)
        XCTAssertEqual(settings.apiKey, "", "Local-only launch must not load the stored token")
    }

    func test_switchingToRemote_lazilyLoadsStoredToken() {
        let key = "RemoteTranscriptionSettingsTests.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        KeychainHelper.save(key: key, value: "sk-stored")
        defer { KeychainHelper.delete(key: key) }

        let suite = UserDefaults(suiteName: "RemoteTranscriptionSettingsTests.\(#function)")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionSettingsTests.\(#function)")
        let settings = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: key)
        XCTAssertEqual(settings.apiKey, "")

        settings.backend = .remote
        XCTAssertEqual(settings.apiKey, "sk-stored",
                       "Switching to remote must lazily load the stored token")
    }

    func test_remoteBackendAtLaunch_loadsStoredToken() {
        // If remote was the persisted choice, the token should be present right
        // after construction (the one case where reading at launch is correct).
        let key = "RemoteTranscriptionSettingsTests.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        KeychainHelper.save(key: key, value: "sk-stored")
        defer { KeychainHelper.delete(key: key) }

        let suite = UserDefaults(suiteName: "RemoteTranscriptionSettingsTests.\(#function)")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionSettingsTests.\(#function)")
        suite.set(TranscriptionBackend.remote.rawValue, forKey: "transcription.backend")
        let settings = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: key)

        XCTAssertEqual(settings.backend, .remote)
        XCTAssertEqual(settings.apiKey, "sk-stored")
    }

    func test_lazyLoad_doesNotClobberInProgressEdit() {
        // User typed a key before ever switching to remote. Switching must keep
        // their edit, not overwrite it with the stored value.
        let key = "RemoteTranscriptionSettingsTests.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        KeychainHelper.save(key: key, value: "sk-stored")
        defer { KeychainHelper.delete(key: key) }

        let suite = UserDefaults(suiteName: "RemoteTranscriptionSettingsTests.\(#function)")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionSettingsTests.\(#function)")
        let settings = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: key)

        settings.apiKey = "sk-user-typed"
        settings.backend = .remote
        XCTAssertEqual(settings.apiKey, "sk-user-typed",
                       "An in-progress edit must not be clobbered by the lazy load")
    }

    func test_lazyLoad_isIdempotentAcrossBackendToggles() {
        // Once loaded, toggling local <-> remote must not re-read or clobber.
        let key = "RemoteTranscriptionSettingsTests.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        KeychainHelper.save(key: key, value: "sk-stored")
        defer { KeychainHelper.delete(key: key) }

        let suite = UserDefaults(suiteName: "RemoteTranscriptionSettingsTests.\(#function)")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionSettingsTests.\(#function)")
        let settings = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: key)

        settings.backend = .remote
        XCTAssertEqual(settings.apiKey, "sk-stored")
        // User clears the field, then flips back to local and to remote again.
        settings.apiKey = ""
        settings.backend = .local
        settings.backend = .remote
        XCTAssertEqual(settings.apiKey, "",
                       "Already-loaded token must not be re-read on a later switch")
    }

    func test_editingEndpointResetsTestStatus() async {
        // Stub the network so testConnection() actually seeds a non-idle
        // status (.ok), then assert that editing the endpoint resets it —
        // exercising the real reset path rather than a no-op from .idle.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubOKURLProtocol.self]
        let session = URLSession(configuration: config)
        let suite = UserDefaults(suiteName: "RemoteTranscriptionSettingsTests.reset")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionSettingsTests.reset")
        let settings = RemoteTranscriptionSettings(
            defaults: suite,
            urlSession: session,
            apiKeyKeychainKey: "RemoteTranscriptionSettingsTests.reset.apiKey")
        settings.backend = .remote
        settings.endpoint = "https://example.com/v1"

        await settings.testConnection()
        guard case .ok = settings.testStatus else {
            return XCTFail("Expected testConnection to seed .ok, got \(settings.testStatus)")
        }

        settings.endpoint = "https://example.com/v2"
        XCTAssertEqual(settings.testStatus, .idle, "Editing the endpoint must reset the status")
    }
}

/// Returns 200 for any request — lets `testConnection()` reach `.ok` without a
/// real server.
private final class StubOKURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
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
