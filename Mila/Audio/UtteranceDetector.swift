import Foundation
import OSLog

private let vadLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "VAD")

/// RMS-based voice-activity detector. Ingests mono16k PCM frames and
/// emits a complete utterance (samples + recording-time start) when a
/// sustained silence follows speech, OR when speech has run for
/// `maxUtteranceSeconds` (a force-cut for monologue speakers who don't
/// pause).
///
/// State machine:
///   `.silence` — every incoming frame's RMS is checked against
///                `rmsThreshold`. While silent, recent frames are kept
///                in a small ring buffer for pre-roll context.
///   `.speech`  — every frame is appended to `current`. Frames whose
///                RMS is below threshold increment `silentTailFrames`;
///                speech frames reset it. When `silentTailFrames`
///                reaches `silenceFrameThreshold`, the utterance is
///                emitted (if it had at least `minUtteranceFrames` of
///                active speech) and we drop back to `.silence`.
///
/// The emitted samples include the pre-roll silence (so whisper sees a
/// clean attack on the first phoneme) and the trailing silence (so
/// whisper hears the natural end of the last word). Whisper's own
/// segmenter handles the in-utterance phrasing.
///
/// Frame size is fixed at 30ms (480 samples at 16kHz) — matches WebRTC
/// VAD's standard frame; small enough to detect sub-half-second pauses.
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
    /// Hysteresis: once in .speech, the cutoff is multiplied by this
    /// ratio (< 1) so a brief mid-word energy dip doesn't flip us back
    /// to silence. Standard VAD design.
    private let stayCutoffRatio: Float

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
    /// during `.silence`. The effective speech cutoff is
    /// `max(rmsThreshold, noiseFloor * noiseFloorMultiplier)` — so a
    /// quiet office gets a low cutoff and a humming AC room gets a
    /// proportionally higher one.
    private var noiseFloor: Float = 0.001
    /// Counts consecutive above-cutoff frames while still in `.silence`.
    /// We only enter `.speech` after `speechOnsetFrames` of them, so a
    /// single click/pop doesn't trigger an utterance.
    private var pendingSpeechFrames: Int = 0
    private var pendingSpeechBuffer: [[Float]] = []

    private enum State { case silence, speech }

    init(
        sampleRate: Double = 16_000,
        frameMs: Double = 30,
        rmsThreshold: Float = 0.008,
        silenceMs: Double = 700,
        minUtteranceMs: Double = 200,
        maxUtteranceMs: Double = 20_000,
        preRollMs: Double = 200,
        noiseFloorAlpha: Float = 0.02,
        noiseFloorMultiplier: Float = 3.0,
        speechOnsetMs: Double = 90,
        stayCutoffRatio: Float = 0.5
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
        self.preRoll = Array(repeating: [Float](), count: preRollFrames)
    }

    /// Wipes detector state. Call when starting a new recording.
    func reset() {
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
        pendingSpeechFrames = 0
        pendingSpeechBuffer.removeAll(keepingCapacity: true)
    }

    /// Force-emit any in-progress utterance regardless of trailing
    /// silence. Used at end-of-recording so the tail doesn't sit in
    /// the detector unpublished.
    func flush() {
        if state == .speech, speechFramesInCurrent >= minUtteranceFrames {
            emit()
        }
        state = .silence
        current.removeAll(keepingCapacity: true)
        silentTailFrames = 0
        speechFramesInCurrent = 0
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
            let cutoff = max(rmsThreshold, noiseFloor * noiseFloorMultiplier)
            vadLog.log("VAD tick: state=\(s, privacy: .public) noiseFloor=\(self.noiseFloor, privacy: .public) cutoff=\(cutoff, privacy: .public) speechFrames=\(self.speechFramesInCurrent, privacy: .public)")
        }
    }

    private func handle(frame: [Float]) {
        let energy = rms(frame)
        // Enter-speech cutoff: capped dynamic threshold (room noise can
        // raise it, but only up to 2.5× the static floor).
        let enterCutoff = max(rmsThreshold, min(rmsThreshold * 2.5, noiseFloor * noiseFloorMultiplier))
        // Hysteresis: once in speech, a lower cutoff keeps us in speech
        // through brief mid-word energy dips (consonants, vowel decay).
        let cutoff = (state == .silence) ? enterCutoff : enterCutoff * stayCutoffRatio
        let isSpeech = energy >= cutoff

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
                // Update adaptive noise floor — but ONLY on deep-silence
                // frames (energy well below the static threshold). Earlier
                // we updated on every below-cutoff frame, which let a
                // quiet talker's between-word audio pull the floor up,
                // triggering a positive feedback loop (cutoff rises →
                // more speech missed → floor rises further). With this
                // gate, the floor reflects actual room noise, not
                // borderline speech.
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
        vadLog.log("VAD emit utterance: startSec=\(startSec, privacy: .public) dur=\(dur, privacy: .public)s noiseFloor=\(self.noiseFloor, privacy: .public) speechFrames=\(self.speechFramesInCurrent, privacy: .public)")
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
