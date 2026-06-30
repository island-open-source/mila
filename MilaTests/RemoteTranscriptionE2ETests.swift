import XCTest
import TranscriptionCore
@testable import Mila

/// End-to-end tests of the remote transcription client against a live HTTP
/// server. Two workflows drive this suite, distinguished by `MILA_REMOTE_HEBREW`:
///
///   * `e2e-remote-transcription` (echo mock) — `MILA_REMOTE_TEST_ENDPOINT`
///     points at the stdlib mock in `scripts/mock-openai-transcription-server.py`,
///     which validates the request *contract* and echoes `model`/`language`
///     back. Proves, over a real socket, that `RemoteWhisperEngine` encodes
///     samples to m4a, uploads a well-formed multipart request with Bearer auth,
///     and parses `verbose_json` segments + timestamps back.
///
///   * `e2e-hebrew-remote` (real speaches server, `MILA_REMOTE_HEBREW=1`) — the
///     endpoint is a tunnel to a Docker speaches container serving an ivrit.ai
///     Hebrew CT2 model. Proves (a) real Hebrew speech transcribes correctly via
///     the remote backend (WER), and (b) Mila's neural VAD drops silence/noise.
///
/// When `MILA_REMOTE_TEST_ENDPOINT` is absent (every normal `MilaTests` run) the
/// whole suite XCTSkips. Within a workflow, the tests that don't apply to that
/// server (echo-mock assertions vs. real-Hebrew) skip via `isRealServer`.
final class RemoteTranscriptionE2ETests: XCTestCase {

    private var endpoint: URL!

    /// True when the endpoint is the real speaches server (the
    /// `e2e-hebrew-remote` workflow) rather than the echo mock. The echo-mock
    /// tests below assert mock-specific behaviour (echoed `model=`/`lang=`
    /// segments), which a real transcription server won't produce — so they
    /// skip in the Hebrew workflow, and the Hebrew tests skip in the mock one.
    private var isRealServer: Bool {
        ProcessInfo.processInfo.environment["MILA_REMOTE_HEBREW"] == "1"
    }

    override func setUpWithError() throws {
        guard let raw = ProcessInfo.processInfo.environment["MILA_REMOTE_TEST_ENDPOINT"],
              let url = URL(string: raw) else {
            throw XCTSkip("MILA_REMOTE_TEST_ENDPOINT not set — remote E2E runs only in the e2e-remote-transcription / e2e-hebrew-remote workflows.")
        }
        endpoint = url
    }

    /// 1 second of a 220 Hz sine at 16 kHz — real, non-silent audio for the
    /// engine to encode and upload.
    private func sineSamples(seconds: Double = 1.0) -> [Float] {
        let rate = WhisperAudioFormat.sampleRate
        let count = Int(rate * seconds)
        return (0..<count).map { i in
            0.3 * Float(sin(2.0 * Double.pi * 220.0 * Double(i) / rate))
        }
    }

    func test_roundTrip_uploadsAndParsesSegments() async throws {
        try XCTSkipIf(isRealServer, "echo-mock assertions don't apply to a real transcription server.")
        let engine = RemoteWhisperEngine()
        await engine.configure(RemoteTranscriptionConfig(
            endpoint: endpoint,
            apiKey: "test-key-123",
            model: "mila-echo-model"
        ))

        let segments = try await engine.transcribe(
            samples: sineSamples(),
            language: "he",
            audioCtx: 0,
            progress: nil,
            isCancelled: nil
        )

        // The mock echoes the received model + language into the segments, so
        // these assertions prove the client transmitted them and parsed the
        // verbose_json (segments + timestamps) back.
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.first?.text, "model=mila-echo-model")
        XCTAssertEqual(segments.last?.text, "lang=he")
        XCTAssertEqual(try XCTUnwrap(segments.last?.end), 1.0, accuracy: 0.0001)
    }

    func test_autoLanguage_isOmitted() async throws {
        try XCTSkipIf(isRealServer, "echo-mock assertions don't apply to a real transcription server.")
        let engine = RemoteWhisperEngine()
        await engine.configure(RemoteTranscriptionConfig(
            endpoint: endpoint,
            apiKey: "test-key-123",
            model: "m"
        ))

        let segments = try await engine.transcribe(
            samples: sineSamples(),
            language: "auto",
            audioCtx: 0,
            progress: nil,
            isCancelled: nil
        )

        // "auto" must NOT send a language field; the mock reports "none" then.
        XCTAssertEqual(segments.last?.text, "lang=none")
    }

    @MainActor
    func test_testConnection_reachesModelsEndpoint() async {
        let suite = UserDefaults(suiteName: "RemoteTranscriptionE2ETests.conn")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionE2ETests.conn")
        let settings = RemoteTranscriptionSettings(
            defaults: suite,
            apiKeyKeychainKey: "RemoteTranscriptionE2ETests.conn.apiKey")
        settings.backend = .remote
        settings.endpoint = endpoint.absoluteString
        settings.apiKey = "test-key-123"

        await settings.testConnection()

        guard case .ok = settings.testStatus else {
            return XCTFail("Expected .ok, got \(settings.testStatus)")
        }
    }

    // MARK: - Real Hebrew transcription (against a live speaches server)

    /// Repo root. On CI the `e2e-hebrew-remote` workflow exports it via
    /// `MILA_REPO_ROOT`; locally we derive it from this file's path.
    private var repoRoot: URL {
        if let v = ProcessInfo.processInfo.environment["MILA_REPO_ROOT"] {
            return URL(fileURLWithPath: v)
        }
        // `#filePath` → `…/MilaTests/RemoteTranscriptionE2ETests.swift`
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MilaTests
            .deletingLastPathComponent()   // repo root
    }

    private var hebrewFixturesDir: URL {
        repoRoot.appendingPathComponent("Packages/TranscriptionCore/Fixtures")
    }

    /// Load a `*.expected.txt` fixture: first line is the language, the rest is
    /// the reference transcript (same format the WhisperE2E CLI uses).
    private func expectedText(for name: String) throws -> String {
        let url = hebrewFixturesDir.appendingPathComponent("\(name).expected.txt")
        let lines = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        return lines.dropFirst().joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// (a) REAL HEBREW SPEECH transcribes correctly via the remote backend.
    ///
    /// Uploads a Hebrew fixture WAV to the live speaches server (the
    /// `e2e-hebrew-remote` workflow stands it up with an ivrit.ai model) through
    /// the production `RemoteWhisperEngine`, and asserts the returned Hebrew
    /// transcript is close to the reference (WER). Gated on `MILA_REMOTE_HEBREW`
    /// so it stays dormant in the echo-mock workflow (where it would fail — the
    /// mock doesn't transcribe).
    func test_hebrew_realSpeech_transcribesViaRemote() async throws {
        try XCTSkipUnless(isRealServer, "Hebrew transcription runs only against a real speaches server (MILA_REMOTE_HEBREW=1).")
        let model = ProcessInfo.processInfo.environment["MILA_REMOTE_MODEL"]
            ?? "ivrit-ai/whisper-large-v3-turbo-ct2"

        let engine = RemoteWhisperEngine()
        // Self-hosted speaches accepts anonymous requests; a dummy non-empty key
        // is fine (OpenAI SDKs require one, speaches ignores it).
        await engine.configure(RemoteTranscriptionConfig(
            endpoint: endpoint, apiKey: "speaches", model: model))

        // he_toda_raba — the exact phrase whisper hallucinates on Hebrew
        // silence; as real speech it must come back transcribed.
        let name = "he_toda_raba"
        let wavURL = hebrewFixturesDir.appendingPathComponent("\(name).wav")
        let samples = try WAVReader.loadSamples(url: wavURL)
        let reference = try expectedText(for: name)

        let segments = try await engine.transcribe(
            samples: samples, language: "he", audioCtx: 0,
            progress: nil, isCancelled: nil)

        let transcript = segments.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(transcript.isEmpty, "remote returned an empty Hebrew transcript")

        let wer = WERCalculator.calculate(reference: reference, hypothesis: transcript)
        // Loose bound: this is an HTTP round trip through a tunnel against a
        // turbo CT2 model at int8 — we're proving "real Hebrew came back", not
        // benchmarking accuracy. (The local whisper.cpp E2E owns the tight WER
        // gate.)
        XCTAssertLessThanOrEqual(
            wer, 0.5,
            "Hebrew WER \(wer) too high.\n  reference: \"\(reference)\"\n  got:       \"\(transcript)\"")
    }

    /// (b) NOISE/SILENCE is DROPPED by Mila's neural VAD with zero hallucinated
    /// segments.
    ///
    /// The VAD (`SileroVAD`) is a CLIENT-SIDE gate that runs in `LiveTranscriber`
    /// BEFORE any engine (local or remote) — it is not part of the remote HTTP
    /// path, so the right place to prove "noise is dropped" is the gate itself.
    /// This asserts the gate rejects pure silence and loud white noise (which,
    /// ungated, make whisper emit the classic Hebrew filler hallucination). It
    /// runs alongside the Hebrew remote check so this one workflow validates
    /// BOTH halves the VAD exists for.
    ///
    /// (The cross-platform `SileroVADTests` cover this on Linux too; asserted
    /// here as well so the Hebrew-VAD story is self-contained.)
    func test_noiseAndSilence_droppedByVADGate() async throws {
        try XCTSkipUnless(isRealServer, "Runs only in the Hebrew VAD E2E workflow (MILA_REMOTE_HEBREW=1).")
        let modelPath = repoRoot
            .appendingPathComponent("Mila/Resources/ggml-silero-v5.1.2.bin").path
        let vad = try SileroVAD(modelPath: modelPath)
        let rate = Int(WhisperAudioFormat.sampleRate)

        // Pure silence.
        let silence = [Float](repeating: 0, count: rate * 3)
        let silenceHasSpeech = await vad.containsSpeech(silence)
        XCTAssertFalse(silenceHasSpeech, "3s of silence must be dropped by the VAD")

        // Loud white noise (~0.3 amplitude) — clears the live RMS energy cutoff,
        // so the OLD detector emitted it and whisper hallucinated Hebrew filler.
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(Double(state % 20001) / 10000.0 - 1.0) * 0.3
        }
        let noise = (0..<(rate * 3)).map { _ in next() }
        let noiseHasSpeech = await vad.containsSpeech(noise)
        XCTAssertFalse(noiseHasSpeech, "loud white noise must be dropped by the VAD")
    }
}
