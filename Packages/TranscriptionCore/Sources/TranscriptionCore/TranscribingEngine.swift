import Foundation

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
}
