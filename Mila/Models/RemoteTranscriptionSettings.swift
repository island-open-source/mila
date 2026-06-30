import Foundation
import Combine

/// Which engine Mila uses to turn audio into text. A single app-wide choice,
/// mirroring the privacy-first default: on-device whisper.cpp unless the user
/// deliberately opts into a remote endpoint.
enum TranscriptionBackend: String, CaseIterable, Identifiable, Codable {
    /// In-process whisper.cpp (the default). Audio never leaves the device.
    case local
    /// An OpenAI-compatible `/v1/audio/transcriptions` endpoint — OpenAI's own
    /// API or any self-hosted server that speaks the same protocol (e.g.
    /// `speaches` serving an ivrit.ai model). Audio is uploaded off-device.
    case remote

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:  return "On-device"
        case .remote: return "Remote API"
        }
    }
}

/// Immutable snapshot handed to `RemoteWhisperEngine` for one transcription.
/// `Sendable` so it can cross from the `@MainActor` settings object to the
/// engine actor without a data race.
struct RemoteTranscriptionConfig: Sendable, Equatable {
    /// Base URL, e.g. `https://api.openai.com/v1`. The engine appends
    /// `audio/transcriptions`.
    var endpoint: URL
    /// Bearer token. Empty for self-hosted servers that don't authenticate.
    var apiKey: String
    /// Model identifier the server expects, e.g. `whisper-1` (OpenAI) or
    /// `ivrit-ai/whisper-large-v3-turbo-ct2` (a self-hosted faster-whisper).
    var model: String
}

/// User-configurable remote transcription backend. Opt-in, off by default.
///
/// Follows the app's settings conventions: namespaced `UserDefaults` keys for
/// non-secret values, and the **Keychain** for the API token so it's encrypted
/// at rest rather than sitting in the plist. Constructed once in
/// `MilaApp.init()` and injected via `.environmentObject` on both scenes.
@MainActor
final class RemoteTranscriptionSettings: ObservableObject {
    /// Result of the last "Test connection" attempt. Advisory only — it never
    /// gates transcription (a server may not implement `/models`); it just
    /// gives the user fast feedback that the endpoint + token are plausible.
    enum TestStatus: Equatable {
        case idle
        case testing
        case ok(String)
        case failed(String)
    }

    @Published var backend: TranscriptionBackend {
        didSet {
            guard backend != oldValue else { return }
            defaults.set(backend.rawValue, forKey: Keys.backend)
            // Defer the Keychain read until the user actually switches to the
            // remote backend (see `loadAPIKeyIfNeeded`). Local-only users never
            // trigger the macOS "Mila wants to use confidential information"
            // prompt because we never touch the Keychain for them.
            if backend == .remote { loadAPIKeyIfNeeded() }
        }
    }

    @Published var endpoint: String {
        didSet {
            guard endpoint != oldValue else { return }
            defaults.set(endpoint, forKey: Keys.endpoint)
            testStatus = .idle
        }
    }

    @Published var model: String {
        didSet {
            guard model != oldValue else { return }
            defaults.set(model, forKey: Keys.model)
        }
    }

    /// The bearer token. Stored in the Keychain, never in `UserDefaults`. The
    /// `@Published` mirror lets SwiftUI bind a `SecureField` directly; every
    /// edit writes through to the Keychain.
    @Published var apiKey: String {
        didSet {
            guard apiKey != oldValue else { return }
            // Skip the write-back when we're just adopting the value we read
            // from the Keychain — re-saving it would be a redundant write that
            // could itself trigger a Keychain prompt.
            guard !isAdoptingStoredAPIKey else { return }
            KeychainHelper.save(key: apiKeyKeychainKey, value: apiKey)
            testStatus = .idle
        }
    }

    @Published private(set) var testStatus: TestStatus = .idle

    static let defaultEndpoint = "https://api.openai.com/v1"
    static let defaultModel = "whisper-1"

    private let defaults: UserDefaults
    private let urlSession: URLSession
    /// Keychain item the API token is stored under. Injectable so tests /
    /// previews / alternate instances don't read or clobber the real app's
    /// `remote.apiKey` item (mirrors how `defaults` is injected).
    private let apiKeyKeychainKey: String
    /// Whether the stored token has been read from the Keychain yet. Guards the
    /// lazy load so it happens at most once, and so an explicit user edit before
    /// the first switch to remote isn't clobbered by a later load.
    private var hasLoadedAPIKey = false

    init(defaults: UserDefaults = .standard,
         urlSession: URLSession = .shared,
         apiKeyKeychainKey: String = Keys.apiKey) {
        self.defaults = defaults
        self.urlSession = urlSession
        self.apiKeyKeychainKey = apiKeyKeychainKey
        self.backend = TranscriptionBackend(rawValue: defaults.string(forKey: Keys.backend) ?? "")
            ?? .local
        self.endpoint = defaults.string(forKey: Keys.endpoint) ?? Self.defaultEndpoint
        self.model = defaults.string(forKey: Keys.model) ?? Self.defaultModel
        // Start empty and defer the Keychain read. Reading the token at launch
        // unconditionally pops the macOS "Mila wants to use confidential
        // information stored in your keychain" prompt for *every* user — even
        // the local-only majority who never configure a remote endpoint. We
        // only read once the user actually selects the remote backend (here if
        // it's the restored choice, otherwise lazily in `backend.didSet`).
        self.apiKey = ""
        if backend == .remote { loadAPIKeyIfNeeded() }
    }

    /// Lazily read the bearer token from the Keychain the first time the remote
    /// backend is selected. Idempotent (guarded by `hasLoadedAPIKey`) and
    /// non-destructive: if the user has already typed a key we keep theirs
    /// rather than overwrite it with the stored value.
    private func loadAPIKeyIfNeeded() {
        guard !hasLoadedAPIKey else { return }
        hasLoadedAPIKey = true
        // Don't clobber an in-progress edit. Only adopt the stored token when
        // the in-memory field is still empty.
        guard apiKey.isEmpty else { return }
        guard let stored = KeychainHelper.load(key: apiKeyKeychainKey), !stored.isEmpty else { return }
        // Assigning here triggers `apiKey.didSet`, but since `stored != ""` only
        // when it differs from the current empty value, the write-through guard
        // (`guard apiKey != oldValue`) lets it pass and re-saves the identical
        // value. KeychainHelper.save is delete-then-add, so writing the same
        // value back is harmless — but to avoid even that redundant Keychain
        // write (which could itself prompt), suppress the write-through for this
        // one assignment.
        isAdoptingStoredAPIKey = true
        apiKey = stored
        isAdoptingStoredAPIKey = false
    }

    /// Set only while `loadAPIKeyIfNeeded` adopts the stored token, so the
    /// `apiKey.didSet` write-through skips re-saving a value we just read.
    private var isAdoptingStoredAPIKey = false

    /// True when the user has chosen the remote backend (regardless of whether
    /// it's fully configured). Drives routing in `TranscriptionService`.
    var isActive: Bool { backend == .remote }

    /// Parsed, validated base URL — `nil` if the string isn't a usable
    /// absolute http(s) URL.
    var endpointURL: URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    /// "Enabled AND ready to use" — the invariant the routing layer relies on
    /// before it skips the local-model gate. The endpoint must parse, and
    /// OpenAI's own endpoint additionally needs an API key (self-hosted servers
    /// usually accept anonymous requests, so we don't force a token there).
    var isConfigured: Bool {
        guard isActive, let url = endpointURL else { return false }
        if Self.requiresAPIKey(url) {
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    /// Snapshot for the engine, or `nil` if the endpoint can't be parsed.
    func currentConfig() -> RemoteTranscriptionConfig? {
        guard let url = endpointURL else { return nil }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteTranscriptionConfig(
            endpoint: url,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: trimmedModel.isEmpty ? Self.defaultModel : trimmedModel
        )
    }

    /// Human-readable label written to `Recording.modelName` when a remote
    /// transcription completes (so the detail view shows where the text came
    /// from).
    var modelLabel: String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Remote · \(trimmedModel.isEmpty ? Self.defaultModel : trimmedModel)"
    }

    /// OpenAI's hosted API rejects unauthenticated requests, so we treat a key
    /// as mandatory there. Self-hosted endpoints are assumed open unless the
    /// user supplies one.
    static func requiresAPIKey(_ url: URL) -> Bool {
        (url.host ?? "").lowercased().hasSuffix("openai.com")
    }

    /// Probe the endpoint with a cheap `GET /models`. Treats any 2xx as
    /// reachable. Purely advisory — surfaced as a status pill in Settings.
    func testConnection() async {
        guard let url = endpointURL else {
            testStatus = .failed("Enter a valid http(s) URL.")
            return
        }
        testStatus = .testing
        var request = URLRequest(url: url.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await urlSession.data(for: request)
            // Drop the result if the user edited the endpoint/key while the
            // request was in flight — `didSet` already reset status to .idle,
            // and a stale result for the previous values would be misleading.
            guard endpointURL == url,
                  apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == key else { return }
            guard let http = response as? HTTPURLResponse else {
                testStatus = .failed("No HTTP response.")
                return
            }
            switch http.statusCode {
            case 200..<300:
                testStatus = .ok("Reachable")
            case 401, 403:
                testStatus = .failed("Authentication failed (HTTP \(http.statusCode)). Check the API key.")
            case 404:
                // Some servers don't implement /models but still transcribe.
                testStatus = .ok("Reachable (no /models endpoint)")
            default:
                testStatus = .failed("Server returned HTTP \(http.statusCode).")
            }
        } catch {
            guard endpointURL == url,
                  apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == key else { return }
            testStatus = .failed(error.localizedDescription)
        }
    }

    private enum Keys {
        static let backend = "transcription.backend"
        static let endpoint = "remote.endpoint"
        static let model = "remote.model"
        static let apiKey = "remote.apiKey"
    }
}
