import Foundation
import whisper
#if canImport(os)
import os.log
private let vadLog = Logger(subsystem: "io.island.mila.TranscriptionCore", category: "SileroVAD")
#endif

@inline(__always) private func sileroNotice(_ message: String) {
#if canImport(os)
    vadLog.notice("\(message, privacy: .public)")
#endif
}

/// Thin Swift wrapper around whisper.cpp's bundled **Silero** Voice
/// Activity Detection model.
///
/// Why this exists: the live path's `UtteranceDetector` is a pure
/// *energy* (RMS) detector — it tells loud from quiet, not voice from
/// noise. In a noisy room (fan, traffic, music, keyboard) a non-speech
/// burst clears the energy cutoff, gets emitted as an "utterance", and
/// whisper hallucinates filler text on it (the classic Hebrew
/// `תודה רבה אדוני יושב ראש הכנסת`). Silero is a tiny RNN trained to
/// recognise *human speech* specifically, so we run it as a
/// confirmatory gate: if Silero finds no speech in an utterance, we
/// drop it before it ever reaches whisper. That both removes the
/// hallucination source and *saves* CPU (whisper, far more expensive
/// than Silero, never runs on noise-only audio).
///
/// CPU cost: the model is ~0.9 MB and runs on a 32 ms (512-sample)
/// hop; a few-second utterance is a handful of milliseconds on CPU.
/// We keep it on the CPU (no Metal) to avoid contending with whisper's
/// GPU/ANE work.
///
/// Not thread-safe for the same context (whisper.cpp stores per-context
/// probability state), so this is an `actor` — calls serialise.
public actor SileroVAD {
    public enum Error: Swift.Error, LocalizedError {
        case modelLoadFailed(String)
        public var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let path):
                // Surface only the filename — the absolute path leaks the
                // user's home dir / checkout location into logs.
                return "Failed to load VAD model \(URL(fileURLWithPath: path).lastPathComponent)"
            }
        }
    }

    private var vctx: OpaquePointer?

    /// Load the Silero VAD model from `modelPath` (the bundled
    /// `ggml-silero-v5.1.2.bin`). Throws if the file can't be loaded so
    /// the caller can fall back to running without the gate rather than
    /// silently dropping every utterance.
    public init(modelPath: String) throws {
        var ctxParams = whisper_vad_default_context_params()
        // CPU-only: Silero is cheap and we don't want it competing with
        // whisper for the GPU/ANE. Two threads is plenty for a 512-sample hop.
        ctxParams.use_gpu = false
        ctxParams.n_threads = 2
        let ctx = modelPath.withCString { cPath in
            whisper_vad_init_from_file_with_params(cPath, ctxParams)
        }
        guard let ctx else {
            throw Error.modelLoadFailed(modelPath)
        }
        self.vctx = ctx
        sileroNotice("SileroVAD loaded from \(URL(fileURLWithPath: modelPath).lastPathComponent)")
    }

    deinit {
        if let vctx { whisper_vad_free(vctx) }
    }

    /// Returns true if `samples` (mono 16 kHz PCM in [-1, 1]) contains at
    /// least one Silero-detected speech segment.
    ///
    /// **Fail-open:** on any error (no context, detection failure) this
    /// returns `true` so a malfunctioning VAD never eats real speech —
    /// the worst case degrades to today's behaviour (everything reaches
    /// whisper), never to "transcript goes silent".
    ///
    /// `minSpeechMs` / `minSilenceMs` map onto Silero's segment
    /// post-processing. The defaults match `whisper_vad_default_params`
    /// (250 ms / 100 ms), tuned so a single click/pop doesn't register
    /// as speech but a short word does.
    public func containsSpeech(_ samples: [Float],
                               threshold: Float = 0.5,
                               minSpeechMs: Int32 = 250,
                               minSilenceMs: Int32 = 100) -> Bool {
        guard let vctx else { return true }
        guard !samples.isEmpty else { return false }

        var params = whisper_vad_default_params()
        params.threshold = threshold
        params.min_speech_duration_ms = minSpeechMs
        params.min_silence_duration_ms = minSilenceMs

        let segs: OpaquePointer? = samples.withUnsafeBufferPointer { ptr in
            whisper_vad_segments_from_samples(vctx, params, ptr.baseAddress, Int32(ptr.count))
        }
        guard let segs else { return true }
        defer { whisper_vad_free_segments(segs) }
        return whisper_vad_segments_n_segments(segs) > 0
    }
}
