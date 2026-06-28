import Foundation
import OSLog
import TranscriptionCore

private let remoteLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                               category: "RemoteWhisperEngine")

/// A `TranscribingEngine` that offloads transcription to an OpenAI-compatible
/// `/v1/audio/transcriptions` endpoint instead of running whisper.cpp locally.
///
/// The protocol hands us 16 kHz mono `Float` samples (the same buffer the
/// local engine would consume), so the recording's audio never has to be
/// re-read from disk — we encode the samples to a compact AAC/`.m4a` blob and
/// upload that. We ask for `verbose_json` so we get per-segment timestamps,
/// which map straight onto `TranscriptSegment` and keep diarization /
/// SRT-export working exactly as they do for the local path.
///
/// Config (endpoint, key, model) is injected via `configure(_:)` before each
/// transcription — the protocol's `transcribe` signature is fixed by the local
/// engine, so the remote-specific bits ride alongside on the actor's state.
actor RemoteWhisperEngine: TranscribingEngine {
    enum RemoteError: LocalizedError {
        case notConfigured
        case http(status: Int, body: String)
        case badResponse
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Remote transcription endpoint is not configured."
            case .http(let status, let body):
                let detail = Self.shortMessage(from: body)
                return "Remote server returned HTTP \(status)\(detail.map { ": \($0)" } ?? "")."
            case .badResponse:
                return "Remote server returned a response Mila couldn't parse."
            case .emptyResult:
                return "Remote server returned no transcript."
            }
        }

        /// Pull a human-readable `error.message` out of an OpenAI-style error
        /// body, falling back to a trimmed prefix of the raw body.
        private static func shortMessage(from body: String) -> String? {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let data = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = obj["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            return String(trimmed.prefix(200))
        }
    }

    private var config: RemoteTranscriptionConfig?
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        // A long meeting can take a while to transcribe server-side; the
        // resource timeout has to clear the whole round trip, not just the
        // upload.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60
        self.session = URLSession(configuration: configuration)
    }

    func configure(_ config: RemoteTranscriptionConfig) {
        self.config = config
    }

    // MARK: - TranscribingEngine

    /// No local weights to load. The connectivity check lives in
    /// `RemoteTranscriptionSettings.testConnection()`; here we just confirm
    /// the engine was configured.
    func loadIfNeeded(modelURL: URL, displayName: String) async throws {
        guard config != nil else { throw RemoteError.notConfigured }
    }

    func shutdown() async {
        session.invalidateAndCancel()
    }

    func transcribe(samples: [Float],
                    language: String,
                    audioCtx: Int32?,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment] {
        guard let config else { throw RemoteError.notConfigured }
        if isCancelled?() == true { throw CancellationError() }

        progress?(0.05)
        let audioData = try await Self.encodeM4A(samples: samples)
        progress?(0.2)

        let boundary = "MilaBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: config.endpoint.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body = Self.multipartBody(boundary: boundary,
                                      audio: audioData,
                                      model: config.model,
                                      language: language)

        remoteLog.log("transcribe: POST \(request.url?.absoluteString ?? "?", privacy: .public) model=\(config.model, privacy: .public) lang=\(language, privacy: .public) bytes=\(body.count, privacy: .public)")

        // The protocol's `isCancelled` is a polled flag (the batch Cancel
        // button), not Swift task cancellation. Bridge it: run the upload in a
        // child task and a watchdog that cancels it the moment the flag flips.
        let netTask = Task { try await session.upload(for: request, from: body) }
        let watchdog = Task {
            while !Task.isCancelled {
                if isCancelled?() == true { netTask.cancel(); return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { watchdog.cancel() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await netTask.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if isCancelled?() == true { throw CancellationError() }
            throw error
        }

        guard let http = response as? HTTPURLResponse else { throw RemoteError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteError.http(status: http.statusCode,
                                   body: String(data: data, encoding: .utf8) ?? "")
        }

        progress?(0.95)
        let segments = try Self.parseSegments(data: data)
        progress?(1.0)
        remoteLog.log("transcribe: ok segs=\(segments.count, privacy: .public)")
        return segments
    }

    // MARK: - Encoding

    /// Encode 16 kHz mono float samples to an in-memory AAC/`.m4a` blob via the
    /// app's existing WAV → m4a path (~14 MB/hour vs ~230 MB/hour for raw WAV),
    /// keeping uploads well under typical API size limits. Temp files are
    /// cleaned up before returning.
    static func encodeM4A(samples: [Float]) async throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        let wavURL = tmp.appendingPathComponent("mila-remote-\(token).wav")
        let m4aURL = tmp.appendingPathComponent("mila-remote-\(token).m4a")
        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: m4aURL)
        }
        try AudioConvert.writeWhisperWAV(samples: samples, to: wavURL)
        try await AudioCompressor.compress(wavURL: wavURL, toM4A: m4aURL)
        return try Data(contentsOf: m4aURL)
    }

    /// Build a `multipart/form-data` body for the transcription request.
    /// Fields: `file` (the m4a), `model`, `response_format=verbose_json`, and
    /// `language` (omitted when "auto" so the server detects it).
    static func multipartBody(boundary: String,
                              audio: Data,
                              model: String,
                              language: String) -> Data {
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        appendField("model", model)
        appendField("response_format", "verbose_json")
        let lang = language.lowercased()
        if !lang.isEmpty && lang != "auto" {
            // OpenAI expects ISO-639-1; Mila already uses "he"/"en".
            appendField("language", lang)
        }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
        body.append("Content-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")
        return body
    }

    // MARK: - Parsing

    private struct VerboseResponse: Decodable {
        struct Segment: Decodable {
            let start: Double
            let end: Double
            let text: String
        }
        let text: String?
        let duration: Double?
        let segments: [Segment]?
    }

    /// Parse a `verbose_json` (preferred) or plain `json` transcription
    /// response into `TranscriptSegment`s. Static + pure so it can be unit
    /// tested without a server.
    static func parseSegments(data: Data) throws -> [TranscriptSegment] {
        let decoder = JSONDecoder()
        guard let parsed = try? decoder.decode(VerboseResponse.self, from: data) else {
            throw RemoteError.badResponse
        }

        if let segments = parsed.segments, !segments.isEmpty {
            let mapped = segments.compactMap { seg -> TranscriptSegment? in
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(start: seg.start, end: seg.end, text: seg.text)
            }
            if !mapped.isEmpty { return mapped }
        }

        // No segment array (server returned `response_format=json`, or an empty
        // segment list with a top-level transcript). Fall back to one segment
        // spanning the whole clip.
        if let text = parsed.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return [TranscriptSegment(start: 0, end: parsed.duration ?? 0, text: text)]
        }

        throw RemoteError.emptyResult
    }
}

private extension Data {
    /// Append UTF-8 bytes of a string. Used to assemble multipart bodies.
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
