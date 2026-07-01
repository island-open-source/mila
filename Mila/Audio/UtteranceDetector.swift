import Foundation
import OSLog

private let vadLog = MilaLog(category: "VAD")

/// RMS-based voice-activity detector. Ingests mono16k PCM frames and
/// emits a complete utterance (samples + recording-time start) when a
/// sustained silence follows speech, OR when speech has run for
/// `maxUtteranceSeconds` (a force-cut for monologue speakers who don't
/// pause).
///
/// State machine:
///   `.silence` — every incoming frame's RMS is checked against the
///                enter-speech cutoff. While silent, recent frames are
///                kept in a small ring buffer for pre-roll context.
///   `.speech`  — every frame is appended to `current`. Frames whose
///                RMS is below the stay-speech cutoff increment
///                `silentTailFrames`; speech frames reset it. When
///                `silentTailFrames` reaches `silenceFrameThreshold`,
///                the utterance is emitted (if it had at least
///                `minUtteranceFrames` of active speech) and we drop
///                back to `.silence`.
///
/// ## Dual-cutoff: absolute + envelope-relative
///
/// A single absolute RMS threshold (e.g. 0.012) fails when Adaptive
/// Gain Control is amplifying input: AGC pulls background hiss and
/// between-phrase room tone UP to near-speech RMS (~0.02–0.04), so
/// frames that *should* count as silence never fall below the static
/// floor — the detector latches into `.speech` for the entire
/// max-utterance window (the "always emits 10s slabs" bug).
///
/// Instead, the detector compares each frame's energy against the
/// **max** of two cutoffs:
///   1. `absoluteCutoff = max(rmsThreshold, noiseFloor × multiplier)`
///      — the legacy adaptive absolute floor. Catches speech in quiet
///      rooms where the envelope-relative cutoff is too small.
///   2. `relativeCutoff = signalEnvelope × envelopeSilenceRatio`
///      — a fraction of the recent speech peak. Catches silence
///      inside AGC-amplified audio, where the absolute floor is too
///      low to discriminate.
///
/// `signalEnvelope` is a peak-with-decay tracker: it follows the
/// loudest recent frame and decays exponentially, so it stays high
/// through brief mid-word dips but releases over ~1.5–2s when speech
/// truly stops. That window is roughly synced with AGC's release
/// time, so by the time the envelope releases, AGC has also released
/// the gain back down and the absolute floor becomes the binding
/// cutoff again on the next utterance — both mechanisms stay in sync.
///
/// Hysteresis: entering `.speech` uses the absolute cutoff only (the
/// envelope is small at that point; using a relative cutoff would
/// chase its own tail). Once in `.speech`, the combined cutoff
/// applies and is further scaled by `stayCutoffRatio` so a brief
/// mid-word energy dip doesn't flip us back to silence.
///
/// The emitted samples include the pre-roll silence (so whisper sees
/// a clean attack on the first phoneme) and the trailing silence (so
/// whisper hears the natural end of the last word). Whisper's own
/// segmenter handles the in-utterance phrasing.
///
/// Frame size is fixed at 30ms (480 samples at 16kHz) — matches
/// WebRTC VAD's standard frame; small enough to detect sub-half-
/// second pauses.
@MainActor
final class UtteranceDetector {
    /// Fires on the main actor whenever a complete utterance is detected.
    /// `samples` is mono16k PCM in [-1, 1]; `startSeconds` is the absolute
    /// recording-time position of `samples[0]`.
    var onUtterance: (([Float], Double) -> Void)?

    let sampleRate: Double
    private let frameSize: Int
    private let preRollFrames: Int
    private let silenceFrameThreshold: Int
    private let minUtteranceFrames: Int
    private let maxUtteranceFrames: Int
    let rmsThreshold: Float
    private let noiseFloorAlpha: Float
    private let noiseFloorMultiplier: Float
    private let speechOnsetFrames: Int
    /// Hysteresis: once in .speech, the stay cutoff is multiplied by
    /// this ratio (< 1) so a brief mid-word energy dip doesn't flip
    /// us back to silence. Standard VAD design.
    private let stayCutoffRatio: Float
    /// Fraction of the running signal envelope that defines the
    /// envelope-relative cutoff. With AGC enabled, between-phrase
    /// background sits at ~0.2–0.4× the speech peak; a ratio around
    /// 0.40 separates between-syllable dips (typically 0.5–0.7× of
    /// peak — must stay speech) from inter-phrase silence (≤0.3× of
    /// peak — must trigger emit).
    private let envelopeSilenceRatio: Float
    /// Per-frame multiplicative decay of the signal-envelope tracker.
    /// 0.985 at 30ms ≈ a 2-second half-life — long enough that
    /// between-syllable dips don't drop the envelope, short enough
    /// that inter-phrase silences let it fall so the relative cutoff
    /// can release before the next utterance starts.
    private let envelopeDecay: Float
    /// Floor below which the envelope is treated as inactive: the
    /// relative cutoff returns 0 until the envelope rises above this
    /// floor. Prevents the relative cutoff from collapsing to ~0
    /// after a long pause (which would let any whisper of room tone
    /// pretend to be "speech relative to nothing").
    private let envelopeFloor: Float

    private var state: State = .silence
    private var preRoll: [[Float]] = []
    private var preRollHead: Int = 0
    private var current: [Float] = []
    private var silentTailFrames: Int = 0
    private var speechFramesInCurrent: Int = 0
    private var partial: [Float] = []
    private var samplesIngested: Int = 0
    private var currentStartSample: Int = 0
    /// Rolling estimate of the room's background RMS, tracked only
    /// during `.silence`. The effective absolute cutoff is
    /// `max(rmsThreshold, noiseFloor * noiseFloorMultiplier)` — so a
    /// quiet office gets a low cutoff and a humming AC room gets a
    /// proportionally higher one.
    private var noiseFloor: Float = 0.001
    /// Peak-with-decay tracker of the recent speech energy. Acts as a
    /// "running loudness" estimate so we can derive a relative-silence
    /// cutoff that scales with whatever the speaker (and AGC) is
    /// doing. Updated every frame:
    /// `signalEnvelope = max(energy, signalEnvelope * decay)`.
    private var signalEnvelope: Float = 0
    /// Counts consecutive above-cutoff frames while still in `.silence`.
    /// We only enter `.speech` after `speechOnsetFrames` of them, so a
    /// single click/pop doesn't trigger an utterance.
    private var pendingSpeechFrames: Int = 0
    private var pendingSpeechBuffer: [[Float]] = []
    /// Peak frame RMS seen since the previous tick log. Logged + reset
    /// every ~1s so we can see actual energy levels in real
    /// environments when speech vs silence detection misbehaves.
    private var peakRmsSinceTick: Float = 0
    private var sumRmsSinceTick: Float = 0
    private var framesSinceTick: Int = 0

    private enum State { case silence, speech }

    init(
        sampleRate: Double = 16_000,
        frameMs: Double = 30,
        rmsThreshold: Float = 0.012,
        silenceMs: Double = 500,
        minUtteranceMs: Double = 200,
        maxUtteranceMs: Double = 10_000,
        preRollMs: Double = 200,
        noiseFloorAlpha: Float = 0.02,
        noiseFloorMultiplier: Float = 3.0,
        speechOnsetMs: Double = 90,
        stayCutoffRatio: Float = 0.5,
        envelopeSilenceRatio: Float = 0.40,
        envelopeDecay: Float = 0.985,
        envelopeFloor: Float = 0.005
    ) {
        self.sampleRate = sampleRate
        self.frameSize = max(1, Int((sampleRate * frameMs / 1000).rounded()))
        self.rmsThreshold = rmsThreshold
        self.silenceFrameThreshold = max(1, Int((silenceMs / frameMs).rounded()))
        self.minUtteranceFrames = max(1, Int((minUtteranceMs / frameMs).rounded()))
        self.maxUtteranceFrames = max(1, Int((maxUtteranceMs / frameMs).rounded()))
        self.preRollFrames = max(0, Int((preRollMs / frameMs).rounded()))
        self.noiseFloorAlpha = noiseFloorAlpha
        self.noiseFloorMultiplier = noiseFloorMultiplier
        self.speechOnsetFrames = max(1, Int((speechOnsetMs / frameMs).rounded()))
        self.stayCutoffRatio = max(0.0, min(1.0, stayCutoffRatio))
        self.envelopeSilenceRatio = max(0.0, min(1.0, envelopeSilenceRatio))
        self.envelopeDecay = max(0.0, min(1.0, envelopeDecay))
        self.envelopeFloor = max(0.0, envelopeFloor)
        self.preRoll = Array(repeating: [Float](), count: preRollFrames)
    }

    /// Wipes detector state. Call when starting a new recording.
    ///
    /// `reset()` and `flush()` wipe the **same** set of fields — the
    /// only difference is that `flush()` first emits any in-flight
    /// utterance, while `reset()` discards it. Keep these two in sync:
    /// any caller reusing a detector across recordings should see a
    /// fresh envelope / noise floor / pre-roll / pending-speech buffer
    /// regardless of which entry point they use.
    func reset() {
        clearAllState()
    }

    /// Force-emit any in-progress utterance regardless of trailing
    /// silence (so end-of-recording tail isn't lost), then wipe state.
    /// Symmetric with `reset()` — see the note there. The only
    /// difference is "wipe AND emit in-flight" vs "wipe AND discard
    /// in-flight".
    func flush() {
        if state == .speech, speechFramesInCurrent >= minUtteranceFrames {
            emit()
        }
        clearAllState()
    }

    /// Shared state-wipe used by both `reset()` and `flush()`. Wipes
    /// the state machine, in-progress utterance, pre-roll ring buffer,
    /// pending-speech onset buffer, partial-frame accumulator, sample
    /// counter, envelope tracker, noise floor, and tick statistics.
    /// Keep this exhaustive so a wiped detector is indistinguishable
    /// from a freshly-constructed one (modulo init parameters).
    private func clearAllState() {
        state = .silence
        preRoll = Array(repeating: [Float](), count: preRollFrames)
        preRollHead = 0
        current.removeAll(keepingCapacity: true)
        silentTailFrames = 0
        speechFramesInCurrent = 0
        partial.removeAll(keepingCapacity: true)
        samplesIngested = 0
        currentStartSample = 0
        noiseFloor = 0.001
        signalEnvelope = 0
        pendingSpeechFrames = 0
        pendingSpeechBuffer.removeAll(keepingCapacity: true)
        peakRmsSinceTick = 0
        sumRmsSinceTick = 0
        framesSinceTick = 0
    }

    func ingest(_ samples: ArraySlice<Float>) {
        partial.append(contentsOf: samples)
        while partial.count >= frameSize {
            let frame = Array(partial.prefix(frameSize))
            partial.removeFirst(frameSize)
            samplesIngested += frameSize
            handle(frame: frame)
        }
        // Periodic state log every ~1 second so we can debug
        // "nothing happens" reports without spamming the log.
        if samplesIngested % Int(sampleRate) < frameSize {
            let s = state == .speech ? "speech" : "silence"
            let absC = absoluteCutoff()
            let relC = relativeCutoff()
            let enterC = enterCutoff()
            let stayC = stayCutoff()
            let avg = framesSinceTick > 0 ? sumRmsSinceTick / Float(framesSinceTick) : 0
            vadLog.log("VAD tick: state=\(s, privacy: .public) noiseFloor=\(self.noiseFloor, privacy: .public) envelope=\(self.signalEnvelope, privacy: .public) absCutoff=\(absC, privacy: .public) relCutoff=\(relC, privacy: .public) enterCutoff=\(enterC, privacy: .public) stayCutoff=\(stayC, privacy: .public) peakRms=\(self.peakRmsSinceTick, privacy: .public) avgRms=\(avg, privacy: .public) speechFrames=\(self.speechFramesInCurrent, privacy: .public)")
            peakRmsSinceTick = 0
            sumRmsSinceTick = 0
            framesSinceTick = 0
        }
    }

    /// Adaptive absolute cutoff: the static `rmsThreshold` raised by
    /// the noise floor (capped at 2.5× the static value), so a humming
    /// AC room doesn't constantly false-trigger. Same as the legacy
    /// single-cutoff path.
    private func absoluteCutoff() -> Float {
        max(rmsThreshold, min(rmsThreshold * 2.5, noiseFloor * noiseFloorMultiplier))
    }

    /// Envelope-relative cutoff: a fraction of the recent speech
    /// peak. Returns 0 when the envelope is below the floor — i.e.,
    /// at start of recording or after a long quiet — so the absolute
    /// cutoff alone governs in those windows.
    private func relativeCutoff() -> Float {
        guard signalEnvelope > envelopeFloor else { return 0 }
        return signalEnvelope * envelopeSilenceRatio
    }

    /// Cutoff used to *enter* speech from silence. Absolute-only —
    /// using the relative cutoff while no speech is in progress would
    /// chase its own tail (envelope ≈ 0 → cutoff ≈ 0 → any tiny noise
    /// qualifies → bumps envelope → ...).
    private func enterCutoff() -> Float {
        absoluteCutoff()
    }

    /// Cutoff used to *stay* in speech. Combines both mechanisms —
    /// the higher of the two wins (a frame must overcome BOTH kinds
    /// of "this is silent" test to count as speech).
    ///
    /// The absolute portion is multiplied by `stayCutoffRatio` (< 1)
    /// for mid-word hysteresis: brief energy dips in a quiet room
    /// shouldn't drop us back to silence.
    ///
    /// The relative portion is **NOT** scaled — `envelopeSilenceRatio`
    /// already encodes the dip-vs-silence threshold directly (it sits
    /// between "between-syllable dip ≈ 0.5-0.7× peak" and "inter-phrase
    /// silence ≈ 0.1-0.3× peak"). Halving it again would slide the
    /// cutoff into syllable-dip territory and prevent silence from
    /// ever registering — the original AGC-amplified bug.
    private func stayCutoff() -> Float {
        max(absoluteCutoff() * stayCutoffRatio, relativeCutoff())
    }

    private func handle(frame: [Float]) {
        let energy = rms(frame)
        if energy > peakRmsSinceTick { peakRmsSinceTick = energy }
        sumRmsSinceTick += energy
        framesSinceTick += 1

        // Update the running signal envelope (peak-with-decay). We
        // update on EVERY frame regardless of state so the envelope
        // is ready the instant we enter .speech, and so it can decay
        // during long silences to release the relative cutoff.
        let decayed = signalEnvelope * envelopeDecay
        signalEnvelope = max(energy, decayed)

        let isSpeech: Bool
        switch state {
        case .silence:
            isSpeech = energy >= enterCutoff()
        case .speech:
            isSpeech = energy >= stayCutoff()
        }

        switch state {
        case .silence:
            if isSpeech {
                pendingSpeechFrames += 1
                pendingSpeechBuffer.append(frame)
                if pendingSpeechFrames >= speechOnsetFrames {
                    // Confirmed speech onset. Pre-roll context + the
                    // buffered pending frames become the head of the
                    // utterance so we don't clip the first phoneme.
                    let preRollSamples = orderedPreRoll().flatMap { $0 }
                    let pendingSamples = pendingSpeechBuffer.flatMap { $0 }
                    currentStartSample = samplesIngested - pendingSamples.count - preRollSamples.count
                    current.removeAll(keepingCapacity: true)
                    current.reserveCapacity(preRollSamples.count + pendingSamples.count)
                    current.append(contentsOf: preRollSamples)
                    current.append(contentsOf: pendingSamples)
                    silentTailFrames = 0
                    speechFramesInCurrent = pendingSpeechFrames
                    pendingSpeechFrames = 0
                    pendingSpeechBuffer.removeAll(keepingCapacity: true)
                    state = .speech
                }
            } else {
                // Sub-onset spike: drop pending counter; the pending
                // buffered frames return to pre-roll on the next cycle.
                if pendingSpeechFrames > 0 {
                    // Recycle pending frames into the pre-roll so we
                    // don't lose them — they may still be needed if
                    // speech actually starts a moment later.
                    for f in pendingSpeechBuffer {
                        if preRollFrames > 0 {
                            preRoll[preRollHead] = f
                            preRollHead = (preRollHead + 1) % preRollFrames
                        }
                    }
                    pendingSpeechFrames = 0
                    pendingSpeechBuffer.removeAll(keepingCapacity: true)
                }
                // Update adaptive noise floor — but ONLY on
                // deep-silence frames (energy well below the static
                // threshold). Earlier we updated on every
                // below-cutoff frame, which let a quiet talker's
                // between-word audio pull the floor up, triggering a
                // positive feedback loop (cutoff rises → more speech
                // missed → floor rises further). With this gate, the
                // floor reflects actual room noise, not borderline
                // speech.
                if energy < rmsThreshold * 0.5 {
                    noiseFloor = noiseFloor * (1 - noiseFloorAlpha) + energy * noiseFloorAlpha
                }
                if preRollFrames > 0 {
                    preRoll[preRollHead] = frame
                    preRollHead = (preRollHead + 1) % preRollFrames
                }
            }

        case .speech:
            current.append(contentsOf: frame)
            if isSpeech {
                silentTailFrames = 0
                speechFramesInCurrent += 1
            } else {
                silentTailFrames += 1
            }
            let endedBySilence = silentTailFrames >= silenceFrameThreshold
            let endedByCap = current.count >= maxUtteranceFrames * frameSize
            if endedBySilence || endedByCap {
                if speechFramesInCurrent >= minUtteranceFrames {
                    emit()
                }
                state = .silence
                current.removeAll(keepingCapacity: true)
                silentTailFrames = 0
                speechFramesInCurrent = 0
                preRoll = Array(repeating: [Float](), count: preRollFrames)
                preRollHead = 0
            }
        }
    }

    private func emit() {
        let startSec = max(0, Double(currentStartSample) / sampleRate)
        let dur = Double(current.count) / sampleRate
        vadLog.log("VAD emit utterance: startSec=\(startSec, privacy: .public) dur=\(dur, privacy: .public)s noiseFloor=\(self.noiseFloor, privacy: .public) envelope=\(self.signalEnvelope, privacy: .public) speechFrames=\(self.speechFramesInCurrent, privacy: .public)")
        onUtterance?(current, startSec)
    }

    private func orderedPreRoll() -> [[Float]] {
        guard preRollFrames > 0 else { return [] }
        var result: [[Float]] = []
        result.reserveCapacity(preRollFrames)
        for i in 0..<preRollFrames {
            let idx = (preRollHead + i) % preRollFrames
            if !preRoll[idx].isEmpty {
                result.append(preRoll[idx])
            }
        }
        return result
    }

    private func rms(_ frame: [Float]) -> Float {
        var sum: Float = 0
        for s in frame { sum += s * s }
        return (sum / Float(frame.count)).squareRoot()
    }
}
