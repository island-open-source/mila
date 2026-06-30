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
///     Hebrew CT2 model. Drives Mila's INTEGRATED live pipeline
///     (`LiveTranscriber` + RMS `UtteranceDetector` + neural Silero
///     `speechGate`) headlessly and proves, in ONE path, both that (a) real
///     Hebrew survives the VAD gate and reaches speaches transcribed (WER), and
///     (b) silence/noise in the same stream is dropped client-side by the VAD
///     before it ever reaches the server.
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

    // MARK: - Real Hebrew transcription through the INTEGRATED VAD→remote path

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

    /// THE INTEGRATED PROOF: real Hebrew speech flows through Mila's live
    /// pipeline (`LiveTranscriber` + RMS `UtteranceDetector` + neural Silero
    /// `speechGate`) out to the live speaches server — AND noise/silence in the
    /// SAME stream is dropped client-side before it ever reaches the server.
    ///
    /// Earlier this suite proved the two halves *separately*: it called
    /// `RemoteWhisperEngine.transcribe()` directly for Hebrew, and poked
    /// `SileroVAD.containsSpeech()` directly for noise. That bypassed the real
    /// pipeline — nothing tied "the VAD gate" to "the remote backend." Here we
    /// drive the production `LiveTranscriber` path end to end, headlessly (no
    /// mic): `ingest()` a single concatenated stream of
    /// `silence → Hebrew speech → silence → loud white noise → silence`, then
    /// `transcribeNow()` to flush. Two things must hold at once:
    ///
    ///   (a) the Hebrew speech IS transcribed (WER/substring vs the reference)
    ///       — proving real Hebrew survives the VAD gate and reaches speaches;
    ///   (b) the silence + noise produce ZERO segments — proving the neural VAD
    ///       dropped them LOCALLY (pure silence never even trips the RMS
    ///       detector; the loud-noise burst trips RMS but Silero rejects it) so
    ///       speaches never sees them and can't hallucinate the classic Hebrew
    ///       filler (`תודה רבה אדוני יושב ראש הכנסת`).
    ///
    /// Gated on `MILA_REMOTE_HEBREW=1` so it's dormant in the echo-mock
    /// workflow (where speaches isn't up and the mock doesn't transcribe).
    @MainActor
    func test_hebrewSpeech_throughVADGate_reachesRemote_noiseDropped() async throws {
        try XCTSkipUnless(isRealServer, "Integrated VAD→remote Hebrew E2E runs only against a real speaches server (MILA_REMOTE_HEBREW=1).")
        let model = ProcessInfo.processInfo.environment["MILA_REMOTE_MODEL"]
            ?? "ivrit-ai/whisper-large-v3-turbo-ct2"

        // 1. Point a real RemoteTranscriptionSettings at the speaches server.
        //    Isolated UserDefaults suite + keychain key so we never touch the
        //    user's real config (project convention).
        let suite = UserDefaults(suiteName: "RemoteTranscriptionE2ETests.integrated")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionE2ETests.integrated")
        let remoteSettings = RemoteTranscriptionSettings(
            defaults: suite,
            apiKeyKeychainKey: "RemoteTranscriptionE2ETests.integrated.apiKey")
        remoteSettings.backend = .remote
        remoteSettings.endpoint = endpoint.absoluteString
        // Self-hosted speaches accepts anonymous requests; a dummy non-empty key
        // is fine (OpenAI SDKs require one, speaches ignores it).
        remoteSettings.apiKey = "speaches"
        remoteSettings.model = model

        // 2. Build a TranscriptionService routed to the remote backend. The
        //    local `engine` is never exercised once `remoteSettings.isActive`
        //    (TranscriptionService routes every call through its internal
        //    RemoteWhisperEngine), so a stub keeps us off the 1.5 GB whisper
        //    weights. The diarization settings stay unconfigured (default
        //    isolated suite) so no pyannote subprocess spins up.
        let tempRoot = TestSupport.makeTempRoot(label: "RemoteIntegratedE2E")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let store = RecordingStore(rootDirectory: tempRoot)
        let manager = ModelManager(modelsDirectory: tempRoot.appendingPathComponent("Models"))
        let service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(
                defaults: .init(suiteName: "RemoteTranscriptionE2ETests.integrated.diar")!),
            remoteSettings: remoteSettings,
            engine: StubWhisperEngine()
        )

        // 3. Build the LiveTranscriber on it with the neural VAD gate attached —
        //    exactly how `MilaApp.wireLiveAIPipeline` wires it in production.
        let modelPath = repoRoot
            .appendingPathComponent("Mila/Resources/ggml-silero-v5.1.2.bin").path
        let transcriber = LiveTranscriber(transcription: service)
        transcriber.useVAD = true
        transcriber.speechGate = try SileroVAD(modelPath: modelPath)
        transcriber.start(language: "he")

        // 4. Build ONE concatenated stream: silence → Hebrew speech → silence →
        //    loud white noise → silence. The RMS UtteranceDetector emits an
        //    utterance on each speech→silence boundary, so we get two candidate
        //    utterances: the Hebrew (real speech) and the loud-noise burst
        //    (clears the energy cutoff). The pure silence never trips RMS.
        let rate = Int(WhisperAudioFormat.sampleRate)
        let name = "he_toda_raba"
        let wavURL = hebrewFixturesDir.appendingPathComponent("\(name).wav")
        let speech = try WAVReader.loadSamples(url: wavURL)
        let reference = try expectedText(for: name)
        XCTAssertGreaterThan(speech.count, rate / 2, "Hebrew fixture suspiciously short")

        let gap = [Float](repeating: 0, count: rate)          // 1s silence
        // Loud white noise (~0.3 amplitude) — the energy is well above the
        // detector's RMS cutoff, so the RMS stage emits it as an "utterance";
        // the neural Silero gate must then reject it (no human speech). This is
        // the exact shape that, ungated, makes whisper hallucinate Hebrew filler.
        var prng: UInt64 = 0x9E3779B97F4A7C15
        func nextNoise() -> Float {
            prng ^= prng << 13; prng ^= prng >> 7; prng ^= prng << 17
            return Float(Double(prng % 20001) / 10000.0 - 1.0) * 0.3
        }
        let noise = (0..<(rate * 2)).map { _ in nextNoise() }   // 2s loud noise
        let stream = gap + speech + gap + noise + gap

        // 5. Pump the stream through ingest() in 30 ms frames (the UtteranceDetector
        //    frame size), then flush. transcribeNow() force-emits any in-progress
        //    utterance and awaits every queued remote transcribe.
        let chunkSize = 480
        var offset = 0
        while offset < stream.count {
            let end = min(offset + chunkSize, stream.count)
            transcriber.ingest(stream[offset..<end])
            offset = end
        }
        await transcriber.transcribeNow()

        let segments = transcriber.segments
        let transcript = transcriber.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        print("IntegratedVADRemote[he]: \(segments.count) segments -> \"\(transcript)\"")

        // (a) Real Hebrew reached speaches and came back transcribed.
        XCTAssertFalse(
            transcript.isEmpty,
            "No Hebrew transcript — speech was dropped before the remote, or the remote returned nothing.")
        let wer = WERCalculator.calculate(reference: reference, hypothesis: transcript)
        // Loose bound: HTTP round trip through a tunnel to a turbo CT2 model at
        // int8 — proving "real Hebrew survived the gate and came back", not
        // benchmarking accuracy. NOISE LEAKING THROUGH would inflate this WER
        // (extra hallucinated tokens), so the bound also guards half (b).
        XCTAssertLessThanOrEqual(
            wer, 0.5,
            "Hebrew WER \(wer) too high.\n  reference: \"\(reference)\"\n  got:       \"\(transcript)\"")

        // (b) The silence + loud-noise segments were dropped LOCALLY by the VAD
        //     gate. With the gate working we expect a small number of segments,
        //     all of them from the Hebrew utterance — never the noise window.
        //     The Hebrew clip is short (a single phrase) so speaches returns a
        //     handful of segments at most; the noise burst would add its own if
        //     it leaked. A tight cap catches a regression where the gate stops
        //     dropping noise (the segments collection would balloon with filler).
        XCTAssertLessThanOrEqual(
            segments.count, 4,
            "Too many segments (\(segments.count)) — noise likely leaked past the VAD gate to the remote. Transcript: \"\(transcript)\"")
        // No segment may start inside the noise window. The Hebrew sits in
        // [1s, 1s+speechDur]; the noise sits after a further 1s gap. Any segment
        // whose absolute start lands at/after the noise onset proves the noise
        // burst reached the remote and produced a (hallucinated) segment.
        let noiseOnsetSeconds = 1.0 + Double(speech.count) / Double(rate) + 1.0
        let leaked = segments.filter { $0.startSeconds >= noiseOnsetSeconds - 0.25 }
        XCTAssertTrue(
            leaked.isEmpty,
            "VAD gate failed: \(leaked.count) segment(s) originate in the noise window (>= \(noiseOnsetSeconds)s): \(leaked.map(\.text))")
    }
}
