import Foundation

/// Status of CoreML / Apple Neural Engine offload for whisper's encoder
/// after the most recent successful `loadIfNeeded`.
///
/// whisper.cpp v1.8+ auto-loads a sibling `<modelpath-without-ext>-encoder.mlmodelc`
/// next to the `.bin` weights. When present and loadable, the encoder runs on
/// CoreML (which schedules to ANE on Apple Silicon when possible); the decoder
/// continues to run on Metal / CPU. This enum exposes that outcome — verifiable
/// via the whisper.cpp log callback rather than guessed from file presence.
public enum CoreMLStatus: Sendable, Equatable, CustomStringConvertible {
    /// No sibling `.mlmodelc` was loaded — encoder runs on Metal/CPU as before.
    case unavailable
    /// Sibling `.mlmodelc` loaded successfully — encoder is on CoreML/ANE.
    case loaded(path: String)
    /// Sibling existed but whisper.cpp's CoreML init failed (e.g. arch mismatch).
    case failed(reason: String)

    public var description: String {
        switch self {
        case .unavailable: return "unavailable"
        case .loaded(let p): return "loaded(\(p))"
        case .failed(let r): return "failed(\(r))"
        }
    }
}

public protocol TranscribingEngine: Sendable {
    func loadIfNeeded(modelURL: URL, displayName: String) async throws
    /// Transcribe samples.
    ///
    /// `audioCtx` controls the whisper encoder's mel-context truncation:
    ///   * `nil`  → use the engine's default formula (currently 750 for
    ///     short clips, 0 / "whisper default 1500" otherwise). Validated
    ///     against the labelled-fixture sweep for VAD-bounded utterances
    ///     (1-10s); see `WhisperEngine.computeAudioCtx`. Use this only
    ///     for the live-VAD path.
    ///   * `0`    → opt out: whisper's full 1500-token context (= 30s of
    ///     mel capacity). The baseline "no truncation" behavior. Use for
    ///     paths whose quality has not been validated against truncation
    ///     (dictation, imported-file batch transcription).
    ///   * any positive Int32 → explicit override (advanced / testing).
    func transcribe(samples: [Float],
                    language: String,
                    audioCtx: Int32?,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment]
    func shutdown() async

    /// CoreML status after the most recent successful `loadIfNeeded`. The
    /// default implementation returns `.unavailable` so non-whisper engines
    /// (stubs in tests) opt out without boilerplate.
    var coreMLStatus: CoreMLStatus { get async }

    /// Install a callback that fires on the start/end of each
    /// `loadIfNeeded` that the engine considers "long-running" (i.e. the
    /// first CoreML compile of a given mlmodelc on this device, which
    /// pegs CPU for ~13s on M-series). The callback is invoked with
    /// `true` immediately before the heavy work begins and `false` once
    /// the load completes (or fails).
    ///
    /// The closure must be `@Sendable` because the engine may invoke it
    /// from any actor. UI bridges should hop to `@MainActor` inside.
    ///
    /// Default implementation is a no-op so stub engines used in tests
    /// don't need to implement it.
    func setPreparationObserver(_ observer: (@Sendable (Bool, String?) -> Void)?) async
}

extension TranscribingEngine {
    public var coreMLStatus: CoreMLStatus {
        get async { .unavailable }
    }

    public func setPreparationObserver(_ observer: (@Sendable (Bool, String?) -> Void)?) async {
        // no-op default
    }
}
