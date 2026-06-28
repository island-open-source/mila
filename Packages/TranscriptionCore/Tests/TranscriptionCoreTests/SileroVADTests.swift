import XCTest
@testable import TranscriptionCore

/// Validates the Silero neural VAD gate against the same regression
/// that motivated it (issue #26): whisper hallucinates filler text
/// (e.g. the Hebrew `תודה רבה אדוני יושב ראש הכנסת`) on noise/silence
/// that the RMS detector mistook for speech. The gate must say "speech"
/// for real speech fixtures and "no speech" for synthetic noise/silence.
///
/// The model (`ggml-silero-v5.1.2.bin`) and the WAV fixtures are both
/// committed in the repo, so these paths resolve from `#filePath`
/// regardless of where the checkout lives.
final class SileroVADTests: XCTestCase {

    /// `.../Packages/TranscriptionCore/Tests/TranscriptionCoreTests/SileroVADTests.swift`
    /// → repo root is five directories up.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TranscriptionCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TranscriptionCore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repo root
    }

    private static var modelPath: String {
        repoRoot
            .appendingPathComponent("Mila/Resources/ggml-silero-v5.1.2.bin")
            .path
    }

    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    private func makeVAD() throws -> SileroVAD {
        // The model is committed in the repo and the feature depends on it
        // being bundled — a missing file is a real regression, not a reason
        // to skip. Let `SileroVAD.init` throw and fail the test loudly.
        return try SileroVAD(modelPath: Self.modelPath)
    }

    func test_real_speech_fixtures_detected_as_speech() async throws {
        let vad = try makeVAD()
        // Includes he_toda_raba — the exact phrase whisper hallucinates
        // on Hebrew silence. As real speech it MUST pass the gate.
        for name in ["en_hello_world", "he_toda_raba", "en_the_quick_brown_fox"] {
            let url = Self.fixturesDir.appendingPathComponent("\(name).wav")
            let samples = try WAVReader.loadSamples(url: url)
            let hasSpeech = await vad.containsSpeech(samples)
            XCTAssertTrue(hasSpeech, "\(name).wav should be detected as speech")
        }
    }

    func test_silence_rejected() async throws {
        let vad = try makeVAD()
        let silence = [Float](repeating: 0, count: Int(WhisperAudioFormat.sampleRate) * 3)
        let hasSpeech = await vad.containsSpeech(silence)
        XCTAssertFalse(hasSpeech, "3s of pure silence must not register as speech")
    }

    func test_white_noise_rejected() async throws {
        let vad = try makeVAD()
        // Deterministic pseudo-random white noise at ~0.3 amplitude —
        // well above the RMS energy cutoff (0.012), so the OLD detector
        // would have emitted it and whisper would have hallucinated on
        // it. Silero, trained on human speech, should find none.
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(Double(state % 20001) / 10000.0 - 1.0) * 0.3
        }
        let noise = (0..<(Int(WhisperAudioFormat.sampleRate) * 3)).map { _ in next() }
        let hasSpeech = await vad.containsSpeech(noise)
        XCTAssertFalse(hasSpeech, "loud white noise must not register as speech")
    }

    /// Regression for state bleed across calls on a SHARED context (the
    /// production usage — `LiveTranscriber` holds one `SileroVAD` and gates
    /// every utterance through it). whisper.cpp v1.8.4 only exposes
    /// `whisper_vad_detect_speech`, which resets the Silero LSTM state on
    /// every call (the `_no_reset` streaming variant landed upstream
    /// later), so `whisper_vad_segments_from_samples` starts clean each
    /// time. This alternates speech → silence → speech → noise on one
    /// instance and asserts each verdict matches its own input — i.e. a
    /// prior speech utterance never bleeds a false-positive into the
    /// following silence/noise call.
    func test_consecutive_calls_do_not_bleed_state() async throws {
        let vad = try makeVAD()
        let speech = try WAVReader.loadSamples(
            url: Self.fixturesDir.appendingPathComponent("en_hello_world.wav"))
        let silence = [Float](repeating: 0, count: Int(WhisperAudioFormat.sampleRate) * 2)

        var state: UInt64 = 0xD1B54A32D192ED03
        func noiseSample() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(Double(state % 20001) / 10000.0 - 1.0) * 0.3
        }
        let noise = (0..<(Int(WhisperAudioFormat.sampleRate) * 2)).map { _ in noiseSample() }

        // Speech right before silence/noise is the case most likely to
        // expose a stale-state false positive.
        let speech1 = await vad.containsSpeech(speech)
        let silenceAfterSpeech = await vad.containsSpeech(silence)
        let speech2 = await vad.containsSpeech(speech)
        let noiseAfterSpeech = await vad.containsSpeech(noise)
        XCTAssertTrue(speech1, "speech call 1")
        XCTAssertFalse(silenceAfterSpeech, "silence after speech must stay silent")
        XCTAssertTrue(speech2, "speech call 2")
        XCTAssertFalse(noiseAfterSpeech, "noise after speech must stay non-speech")
    }
}
