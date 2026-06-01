import XCTest
@testable import TranscriptionCore

/// Tests for `WhisperEngine.computeAudioCtx(sampleCount:)`.
///
/// Policy (after the live fixture sweep documented in `computeAudioCtx`'s
/// header, plus the post-PR-#32 scoping fix):
///   * audio < 15s  → returns 750 (one of two known-quality-stable values;
///     15s = 750 ctx tokens × 20ms/token, the exact capacity of audio_ctx=750).
///   * audio 15s-30s → returns 0 (= whisper's default 1500). 750 would
///     silently TRUNCATE clips in this range; the formula stays self-correct
///     for any caller that passes nil.
///   * audio ≥ 30s → returns 0 (whisper truncates to its 30s window anyway).
///
/// The earlier "ceil(seconds * 50) + 50" formula was reverted after an
/// integration sweep showed it produced 0 segments on every fixture (silent
/// failure mode of whisper's encoder under unaligned audio_ctx values).
///
/// Per-token capacity for the cover-audio invariant: whisper's encoder
/// downsamples mel frames 2x, so each audio_ctx token covers 20ms of audio
/// (1500 tokens × 20ms = 30s, the model's trained window).
final class AudioCtxTests: XCTestCase {

    private let sampleRate = 16_000
    /// Each audio_ctx token covers 20ms of audio (50 tokens/sec).
    private let msPerToken: Double = 20.0
    /// Whisper's full window: 1500 ctx tokens = 30s of audio.
    private let defaultAudioCtx: Int32 = 1500

    // MARK: - Formula value tests

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

    func test_one_second_clip_uses_750() {
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: sampleRate), 750)
    }

    func test_five_second_clip_uses_750() {
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: 5 * sampleRate), 750)
    }

    func test_ten_second_clip_uses_750() {
        // The VAD's max-utterance cap is 10s — this is the most common
        // live-recording case.
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: 10 * sampleRate), 750)
    }

    func test_just_under_truncation_threshold_uses_750() {
        // 14.9s still fits inside the 15s capacity of audio_ctx=750.
        let samples = Int(14.9 * Double(sampleRate))
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: samples), 750)
    }

    func test_at_truncation_threshold_returns_zero() {
        // Exactly 15s = the capacity ceiling of audio_ctx=750. Inclusive
        // boundary returns 0 so any audio at-or-past 15s gets the full
        // 1500-ctx window and never loses tail.
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: 15 * sampleRate), 0)
    }

    func test_just_under_full_window_returns_zero() {
        // 29.9s — would be massively truncated by audio_ctx=750 (only 15s
        // of capacity). The formula correctly falls back to 0 (= whisper's
        // default 1500) so no audio is lost. This range is not exercised
        // by today's callers (live-VAD caps at 10s; dictation and batch
        // paths opt out with audioCtx=0) but the formula stays safe.
        let samples = Int(29.9 * Double(sampleRate))
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: samples), 0)
    }

    func test_all_short_clip_sizes_below_15s_use_750() {
        // No matter the clip length below 15s, computeAudioCtx returns 750.
        let oneSec = WhisperEngine.computeAudioCtx(sampleCount: sampleRate)
        let fiveSec = WhisperEngine.computeAudioCtx(sampleCount: 5 * sampleRate)
        let tenSec = WhisperEngine.computeAudioCtx(sampleCount: 10 * sampleRate)
        XCTAssertEqual(oneSec, fiveSec)
        XCTAssertEqual(fiveSec, tenSec)
        XCTAssertEqual(oneSec, 750)
    }

    // MARK: - Cover-audio invariant

    /// Sweep representative durations and assert the invariant
    /// `audio_ctx_tokens × 20ms/token >= audio_duration_ms`
    /// — i.e. the returned audio_ctx provides enough mel capacity to
    /// cover the input audio without silent truncation. A returned 0
    /// means "use whisper's default 1500" so the effective capacity is
    /// 30 000 ms.
    ///
    /// This is the invariant that the formula's value-table tests
    /// don't directly verify: a single literal `750` says nothing about
    /// whether the encoder can fit the audio. If a future tweak to the
    /// formula (e.g. raising the boundary, adding a sub-750 step) ever
    /// breaks this, the sweep below catches it before it silently loses
    /// audio in production.
    ///
    /// We cap the sweep at 30s because whisper itself has a hard
    /// architectural ceiling of 30s of mel context — clips longer than
    /// that are processed in chunks by the caller, not by widening
    /// audio_ctx. The cover invariant is "the formula doesn't make
    /// things worse than whisper's own ceiling."
    func test_returned_audio_ctx_covers_input_audio() {
        // Spot-check across the live-VAD range (0-10s), the truncation
        // boundary (12s, 14.9s, 15s, 15.1s), and the fall-through up to
        // whisper's 30s architectural ceiling.
        let durationsSeconds: [Double] = [
            0.5, 1.0, 2.0, 5.0, 8.0, 10.0,
            12.0, 14.0, 14.9, 15.0, 15.1,
            20.0, 25.0, 29.9, 30.0,
        ]

        for seconds in durationsSeconds {
            let sampleCount = Int(seconds * Double(sampleRate))
            let returned = WhisperEngine.computeAudioCtx(sampleCount: sampleCount)
            // 0 is the sentinel for "use whisper's default 1500".
            let effectiveCtx = returned == 0 ? defaultAudioCtx : returned
            let capacityMs = Double(effectiveCtx) * msPerToken
            let audioMs = seconds * 1000.0
            XCTAssertGreaterThanOrEqual(
                capacityMs,
                audioMs,
                "computeAudioCtx(\(sampleCount)) returned \(returned) " +
                "(effective ctx=\(effectiveCtx), capacity=\(capacityMs)ms) " +
                "which does NOT cover \(audioMs)ms of audio. " +
                "This means whisper would silently truncate the tail."
            )
        }
    }
}
