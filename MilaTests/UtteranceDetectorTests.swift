import XCTest
@testable import Mila

@MainActor
final class UtteranceDetectorTests: XCTestCase {

    private let sr: Double = 16_000
    private let frameMs: Double = 30
    private var framesPerSec: Int { Int(1000 / frameMs) }

    /// 30ms frame at the given amplitude.
    private func frame(amp: Float) -> [Float] {
        let n = Int(sr * frameMs / 1000)
        return Array(repeating: amp, count: n)
    }

    /// Synthesize N seconds of speech-like audio (white noise at the
    /// given amplitude — its RMS equals the amplitude for constant
    /// signals, well above the detector's 0.005 default threshold).
    private func speech(seconds: Double, amp: Float = 0.05) -> [Float] {
        let n = Int(sr * seconds)
        return Array(repeating: amp, count: n)
    }

    private func silence(seconds: Double) -> [Float] {
        let n = Int(sr * seconds)
        return Array(repeating: 0.0, count: n)
    }

    func test_silence_only_emits_nothing() {
        let det = UtteranceDetector()
        var fired = 0
        det.onUtterance = { _, _ in fired += 1 }
        det.ingest(silence(seconds: 5)[...])
        XCTAssertEqual(fired, 0, "Pure silence must never emit an utterance")
    }

    func test_speech_then_silence_emits_one_utterance() {
        let det = UtteranceDetector()
        var captured: (samples: [Float], start: Double)?
        det.onUtterance = { samples, start in
            captured = (samples, start)
        }

        // 1s silence, then 2s of speech, then 900ms of trailing silence
        // (default silenceMs threshold is 700ms).
        det.ingest(silence(seconds: 1.0)[...])
        det.ingest(speech(seconds: 2.0)[...])
        det.ingest(silence(seconds: 0.9)[...])

        XCTAssertNotNil(captured, "Expected an emitted utterance after silence followed speech")
        guard let captured else { return }
        // Pre-roll prepends ~200ms; emit fires the moment silence
        // crosses the 400ms threshold, so total length ≈ pre-roll +
        // 2s speech + 400ms silence ≈ 2.6s.
        let durSec = Double(captured.samples.count) / sr
        XCTAssertGreaterThan(durSec, 2.0)
        XCTAssertLessThan(durSec, 3.0)
        // Start should land in the pre-roll window: just before
        // speech began (1.0s mark), minus up-to-200ms pre-roll.
        XCTAssertGreaterThan(captured.start, 0.6)
        XCTAssertLessThan(captured.start, 1.05)
    }

    func test_two_separate_bursts_emit_two_utterances() {
        let det = UtteranceDetector()
        var fired = 0
        det.onUtterance = { _, _ in fired += 1 }

        det.ingest(silence(seconds: 0.5)[...])
        det.ingest(speech(seconds: 1.5)[...])
        det.ingest(silence(seconds: 0.9)[...])   // pause > 700ms ends 1st
        det.ingest(speech(seconds: 1.0)[...])
        det.ingest(silence(seconds: 0.9)[...])   // pause ends 2nd

        XCTAssertEqual(fired, 2)
    }

    func test_below_min_utterance_is_dropped() {
        let det = UtteranceDetector(minUtteranceMs: 500)
        var fired = 0
        det.onUtterance = { _, _ in fired += 1 }

        // 200ms speech — below the 500ms min — followed by long silence.
        det.ingest(silence(seconds: 0.5)[...])
        det.ingest(speech(seconds: 0.2)[...])
        det.ingest(silence(seconds: 0.6)[...])

        XCTAssertEqual(fired, 0, "Sub-min-duration speech must be dropped (tongue-click filter)")
    }

    func test_max_utterance_force_cuts_for_monologue() {
        let det = UtteranceDetector(maxUtteranceMs: 2_000)
        var fired = 0
        var lastDur: Double = 0
        det.onUtterance = { samples, _ in
            fired += 1
            lastDur = Double(samples.count) / 16_000
        }

        // 5s of unbroken speech (no silence to trigger normal cut).
        det.ingest(silence(seconds: 0.3)[...])
        det.ingest(speech(seconds: 5.0)[...])

        XCTAssertGreaterThanOrEqual(fired, 1,
            "Max-utterance cap must force-emit when speech runs past the limit")
        XCTAssertLessThan(lastDur, 2.5,
            "Forced cut must fire at ~maxUtteranceMs, not at the end of all 5s")
    }

    func test_flush_emits_in_progress_utterance() {
        let det = UtteranceDetector()
        var fired = 0
        det.onUtterance = { _, _ in fired += 1 }

        det.ingest(silence(seconds: 0.3)[...])
        det.ingest(speech(seconds: 1.0)[...])
        // No trailing silence — without flush this would sit forever.
        det.flush()

        XCTAssertEqual(fired, 1,
            "flush() must emit any in-progress utterance so end-of-recording tail isn't lost")
    }

    func test_reset_clears_state() {
        let det = UtteranceDetector()
        var fired = 0
        det.onUtterance = { _, _ in fired += 1 }

        det.ingest(silence(seconds: 0.3)[...])
        det.ingest(speech(seconds: 1.5)[...])
        det.reset()
        // After reset, no trailing silence event should fire.
        det.ingest(silence(seconds: 0.6)[...])

        XCTAssertEqual(fired, 0,
            "reset() must discard the in-progress utterance — only NEW speech post-reset should emit")
    }

    // MARK: - AGC-amplified scenarios (envelope-relative cutoff)

    /// Deterministic pseudo-random Float32 noise generator. Fixed seed so
    /// the AGC tests below are reproducible across runs and machines.
    private struct DeterministicNoise {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed | 1 }
        mutating func next() -> Float {
            // xorshift64 — good enough for noise burst tests.
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let u = Float(state & 0xFFFFFF) / Float(0xFFFFFF)
            return u * 2 - 1
        }
    }

    /// `seconds` of white-noise-style audio with the requested RMS. This
    /// is far more realistic than constant-amplitude "speech" — the
    /// envelope tracker sees a real peak/avg spread, just like live
    /// speech.
    private func noise(seconds: Double, rms: Float, seed: UInt64 = 0xCAFEBABE) -> [Float] {
        let n = Int(sr * seconds)
        var rng = DeterministicNoise(seed: seed)
        var out = [Float](repeating: 0, count: n)
        // Uniform [-1,1] noise has RMS ≈ sqrt(1/3) ≈ 0.577; scale to hit
        // the requested RMS exactly.
        let gain = rms / 0.5773503
        for i in 0..<n {
            out[i] = rng.next() * gain
        }
        return out
    }

    /// AGC-amplified inter-phrase silence: noise close-to-but-below
    /// speech amplitude, simulating room tone after AGC has boosted it.
    /// 0.018 RMS sits ABOVE the legacy absolute cutoff (0.012) — only the
    /// envelope-relative cutoff can recognise this as silence.
    func test_agc_amplified_silence_between_phrases_splits_into_utterances() {
        let det = UtteranceDetector()
        var emits: [(samples: [Float], start: Double)] = []
        det.onUtterance = { s, start in emits.append((s, start)) }

        // Pre-roll silence (truly quiet — so the noise floor settles low).
        det.ingest(silence(seconds: 0.5)[...])
        // Phrase 1: 1.2s of "speech" at peak RMS 0.08 (envelope will track ~0.08+).
        det.ingest(noise(seconds: 1.2, rms: 0.08, seed: 0x11)[...])
        // Inter-phrase "silence" at RMS 0.018 — well above the legacy
        // absolute cutoff of 0.012, but only 0.225× the envelope. The
        // envelope-relative cutoff is 0.40 × envelope ≈ 0.032 (the
        // relative portion is NOT scaled by stayCutoffRatio — only the
        // absolute portion is; envelopeSilenceRatio already sits between
        // syllable-dip and inter-phrase-silence territory, so halving
        // it would slide it into syllable-dip range). stayCutoff =
        // max(absCutoff × 0.5, relCutoff) = max(~0.006, 0.032) ≈ 0.032,
        // which is above the 0.018 inter-phrase RMS so frames register
        // as silent. 700ms is enough to cross the 500ms default
        // silenceMs threshold.
        det.ingest(noise(seconds: 0.7, rms: 0.018, seed: 0x22)[...])
        // Phrase 2: 1.2s more speech at peak RMS 0.08.
        det.ingest(noise(seconds: 1.2, rms: 0.08, seed: 0x33)[...])
        // Inter-phrase silence again.
        det.ingest(noise(seconds: 0.7, rms: 0.018, seed: 0x44)[...])
        // Phrase 3: short closer.
        det.ingest(noise(seconds: 0.8, rms: 0.08, seed: 0x55)[...])
        // Tail silence (truly quiet) so phrase 3 flushes via the silence
        // threshold rather than relying on flush().
        det.ingest(silence(seconds: 0.9)[...])

        // With the old single-absolute-cutoff detector this would emit
        // ONE giant utterance covering everything (or hit the max-cap),
        // because the 0.018-RMS "silence" never falls below 0.012. With
        // the envelope-relative cutoff active, each phrase ends cleanly.
        XCTAssertGreaterThanOrEqual(
            emits.count, 2,
            "AGC-amplified silence (RMS=0.018, above absolute cutoff) must still register as silence via the envelope-relative cutoff — expected ≥2 utterances, got \(emits.count)"
        )
        // None of the emits should hit / approach the 10s max-cap.
        for (i, e) in emits.enumerated() {
            let dur = Double(e.samples.count) / sr
            XCTAssertLessThan(
                dur, 5.0,
                "Emit #\(i) (\(dur)s) is suspiciously long for a ~1.2s phrase — detector likely failed to split on the AGC-amplified pause"
            )
        }
    }

    /// Sanity: even at AGC speech levels (RMS 0.08 — well above the
    /// legacy 0.012 cutoff) the detector still ENTERS speech and emits.
    /// Guards against the relative cutoff accidentally suppressing
    /// speech entry.
    func test_agc_amplified_speech_is_still_detected() {
        let det = UtteranceDetector()
        var fired = 0
        det.onUtterance = { _, _ in fired += 1 }

        det.ingest(silence(seconds: 0.5)[...])
        det.ingest(noise(seconds: 1.5, rms: 0.08, seed: 0x77)[...])
        det.ingest(silence(seconds: 0.9)[...])

        XCTAssertEqual(fired, 1, "Loud speech (RMS=0.08) must still emit a single utterance")
    }

    /// Quiet-room regression: a low-amplitude speaker (RMS just above the
    /// 0.012 floor, no AGC) must still emit. The envelope-relative
    /// cutoff must NOT clobber detection here — the envelope floor
    /// (0.005 default) keeps relCutoff at 0 below that envelope, so the
    /// absolute cutoff alone governs and the detector behaves as before.
    func test_quiet_speaker_no_agc_still_emits() {
        let det = UtteranceDetector()
        var fired = 0
        det.onUtterance = { _, _ in fired += 1 }

        det.ingest(silence(seconds: 0.5)[...])
        det.ingest(noise(seconds: 1.5, rms: 0.025, seed: 0x88)[...])
        det.ingest(silence(seconds: 0.9)[...])

        XCTAssertEqual(fired, 1, "Quiet but clearly-speech audio (RMS=0.025) must still emit — relative cutoff must not suppress modest speech")
    }

    /// The envelope-relative cutoff must release after a long quiet
    /// gap so the next utterance can be detected from a low absolute
    /// floor, even after a previous loud burst.
    func test_envelope_releases_after_long_silence() {
        let det = UtteranceDetector()
        var fired = 0
        det.onUtterance = { _, _ in fired += 1 }

        det.ingest(silence(seconds: 0.5)[...])
        // Loud burst — envelope shoots up.
        det.ingest(noise(seconds: 1.0, rms: 0.15, seed: 0x99)[...])
        // Long pure silence — envelope must decay back below floor so a
        // quieter follow-up speaker can still be picked up.
        det.ingest(silence(seconds: 5.0)[...])
        // Quieter follow-up — barely above the absolute cutoff. Without
        // envelope release, the relative cutoff would still be stuck
        // near 0.15 × 0.40 × 0.5 = 0.030 and this would be missed.
        det.ingest(noise(seconds: 1.0, rms: 0.025, seed: 0xAA)[...])
        det.ingest(silence(seconds: 0.9)[...])

        XCTAssertEqual(fired, 2, "Detector must emit BOTH the loud burst AND the quiet follow-up after a long inter-utterance silence")
    }
}
