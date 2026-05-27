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
}
