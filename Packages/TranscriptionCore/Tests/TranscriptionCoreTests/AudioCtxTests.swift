import XCTest
@testable import TranscriptionCore

/// Tests for `WhisperEngine.computeAudioCtx(sampleCount:)`.
///
/// The formula: `audio_ctx = ceil(seconds * 50) + 50`, clamped to [100, 1500],
/// with `0` returned for audio >= the full 30s window (meaning "use default").
final class AudioCtxTests: XCTestCase {

    private let sampleRate = 16_000

    func test_empty_input_returns_zero() {
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: 0), 0)
    }

    func test_full_30s_window_returns_zero() {
        // 30s at 16 kHz = 480_000 samples; default audio_ctx applies.
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: 30 * sampleRate), 0)
    }

    func test_longer_than_window_returns_zero() {
        // Anything past the full window can't be truncated further.
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: 60 * sampleRate), 0)
    }

    func test_short_clip_uses_floor_of_100() {
        // 0.5s -> 25 + 50 = 75 tokens, but floor is 100 to avoid hallucinations.
        let samples = sampleRate / 2
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: samples), 100)
    }

    func test_two_seconds_just_above_floor() {
        // 2s -> 100 + 50 safety = 150 tokens.
        let samples = 2 * sampleRate
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: samples), 150)
    }

    func test_five_seconds_truncates_well_below_default() {
        // 5s -> 250 + 50 safety = 300 tokens. Big speedup vs. default 1500.
        let samples = 5 * sampleRate
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: samples), 300)
        // Sanity: the value we set is much smaller than the full 1500 default.
        XCTAssertLessThan(WhisperEngine.computeAudioCtx(sampleCount: samples), 1500)
    }

    func test_ten_seconds_still_truncates() {
        // 10s -> 500 + 50 safety = 550 tokens.
        let samples = 10 * sampleRate
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: samples), 550)
    }

    func test_just_under_full_window_caps_at_1500() {
        // 29.9s -> 1495 + 50 = 1545; clamps to 1500.
        let samples = Int(29.9 * Double(sampleRate))
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: samples), 1500)
    }

    func test_value_grows_with_sample_count() {
        // Within the active range, more samples -> more ctx tokens.
        let oneSec = WhisperEngine.computeAudioCtx(sampleCount: 1 * sampleRate)
        let fiveSec = WhisperEngine.computeAudioCtx(sampleCount: 5 * sampleRate)
        let tenSec = WhisperEngine.computeAudioCtx(sampleCount: 10 * sampleRate)
        XCTAssertLessThanOrEqual(oneSec, fiveSec)
        XCTAssertLessThan(fiveSec, tenSec)
    }
}
