import Foundation
import whisper

/// Thin Swift wrapper around the whisper.cpp C API.
/// All work happens off the main actor.
public actor WhisperEngine {
    public enum Error: Swift.Error, LocalizedError {
        case modelLoadFailed(String)
        case transcribeFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let path): return "Failed to load Whisper model at \(path)"
            case .transcribeFailed(let code): return "whisper_full failed (code \(code))"
            }
        }
    }

    private var ctx: OpaquePointer?
    private var loadedPath: String?
    public private(set) var modelName: String?

    public init() {}

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    public func loadIfNeeded(modelURL: URL, displayName: String) async throws {
        if loadedPath == modelURL.path { return }
        if let ctx {
            whisper_free(ctx)
            self.ctx = nil
            self.loadedPath = nil
        }
        var params = whisper_context_default_params()
        #if canImport(Metal)
        params.use_gpu = true
        params.flash_attn = true
        #else
        params.use_gpu = false
        params.flash_attn = false
        #endif

        guard let newCtx = modelURL.path.withCString({ cPath in
            whisper_init_from_file_with_params(cPath, params)
        }) else {
            throw Error.modelLoadFailed(modelURL.path)
        }
        self.ctx = newCtx
        self.loadedPath = modelURL.path
        self.modelName = displayName

        #if canImport(Metal)
        // Force ggml-metal to finish its async resource-set init right now.
        //
        // Without this, the user can quit the app while ggml-metal's
        // `__ggml_metal_rsets_init_block_invoke` is still pending on a
        // background dispatch queue. Then when libc++ tears down its global
        // `vector<unique_ptr<ggml_metal_device>>` at exit time,
        // `ggml_metal_rsets_free` aborts because rsets aren't ready (this is
        // exactly the SIGABRT in the on-disk crash reports
        // IvritWhisper-2026-05-08-*.ips). Running a tiny dummy `whisper_full`
        // on 1s of silence makes the kernels actually execute, which forces
        // the init block to run synchronously to completion.
        warmup(ctx: newCtx)
        #endif
    }

    /// Synchronous transcription of a complete sample buffer.
    /// `progress` is invoked with values in `0...1` from inside the C callback.
    public func transcribe(samples rawSamples: [Float],
                    language: String,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)? = nil) throws -> [TranscriptSegment] {
        guard let ctx else {
            throw Error.modelLoadFailed("(no model loaded)")
        }

        // Auto-gain: if the recording is quiet, boost so whisper isn't fooled
        // into thinking it's silence. Capped to a safe ceiling.
        let samples = Self.normalize(rawSamples)
        let peak = samples.map { abs($0) }.max() ?? 0
        let durationSeconds = Double(samples.count) / Double(WhisperAudioFormat.sampleRate)
        print(String(format: "Whisper: transcribing %.2fs of audio, peak=%.3f, lang=%@",
                     durationSeconds, peak, language))

        // Beam search with beam_size=5 is the quality-vs-speed sweet spot for
        // both Hebrew (ivrit.ai) and English (OpenAI) turbo / large models.
        // Greedy sampling was measurably worse on real recordings; the extra
        // ~15-20% runtime is worth it for transcript accuracy.
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = 5
        params.beam_search.patience = -1.0
        params.print_realtime = false
        params.print_progress = false
        params.print_special = false
        params.print_timestamps = false
        params.no_context = true
        params.single_segment = false
        params.translate = false
        params.n_threads = max(1, Int32(ProcessInfo.processInfo.activeProcessorCount - 2))
        params.suppress_blank = true
        params.no_speech_thold = 0.3

        // Shrink the encoder's audio context to match the actual clip length.
        // Whisper's default is 1500 mel ctx tokens (= 30s of audio). For short
        // VAD-emitted utterances (1-10s) processing the full 30s mel-spectrogram
        // is pure wasted compute. Setting `audio_ctx` to the smallest window
        // that fully covers our samples gives a ~3-4x speedup on short clips
        // with no quality loss. See `computeAudioCtx` for the formula.
        params.audio_ctx = Self.computeAudioCtx(sampleCount: samples.count)

        let userBox = CallbackBox(progress: progress, isCancelled: isCancelled)
        let userPtr = Unmanaged.passRetained(userBox).toOpaque()
        defer { Unmanaged<CallbackBox>.fromOpaque(userPtr).release() }

        params.progress_callback = { _, _, p, userData in
            guard let userData else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
            box.progress?(Float(p) / 100.0)
        }
        params.progress_callback_user_data = userPtr

        params.abort_callback = { userData in
            guard let userData else { return false }
            let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
            return box.isCancelled?() ?? false
        }
        params.abort_callback_user_data = userPtr

        let langCString = strdup(language)
        defer { free(langCString) }
        params.language = UnsafePointer(langCString)
        params.detect_language = (language == "auto" || language.isEmpty)

        let result: Int32 = samples.withUnsafeBufferPointer { ptr in
            whisper_full(ctx, params, ptr.baseAddress, Int32(ptr.count))
        }
        if isCancelled?() == true {
            throw CancellationError()
        }
        if result != 0 {
            throw Error.transcribeFailed(result)
        }

        let count = Int(whisper_full_n_segments(ctx))
        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(count)
        for i in 0..<count {
            let t0 = Double(whisper_full_get_segment_t0(ctx, Int32(i))) / 100.0
            let t1 = Double(whisper_full_get_segment_t1(ctx, Int32(i))) / 100.0
            let cText = whisper_full_get_segment_text(ctx, Int32(i))
            let text = cText.flatMap { String(cString: $0) } ?? ""
            segments.append(TranscriptSegment(start: t0, end: t1, text: text))
        }
        return segments
    }

    /// Free the loaded model context synchronously. Calling this from
    /// `applicationShouldTerminate` lets ggml-metal tear down its devices
    /// while the app is still in a normal state (rather than during static
    /// destruction at `exit()`-time, which is what triggered the crash).
    public func shutdown() {
        if let ctx {
            whisper_free(ctx)
            self.ctx = nil
            self.loadedPath = nil
            self.modelName = nil
        }
    }

    // MARK: - Internal

    #if canImport(Metal)
    /// One-shot dummy `whisper_full` on 1 second of silence. Throws are
    /// silently swallowed — warmup is best-effort, and even a non-zero return
    /// has already done what we need (forced ggml-metal kernels to compile +
    /// rsets to populate).
    private func warmup(ctx: OpaquePointer) {
        let silence = [Float](repeating: 0,
                              count: Int(WhisperAudioFormat.sampleRate))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_special = false
        params.print_timestamps = false
        params.no_context = true
        params.single_segment = true
        params.suppress_blank = true
        params.n_threads = 2
        let langCString = strdup("en")
        defer { free(langCString) }
        params.language = UnsafePointer(langCString)
        let r = silence.withUnsafeBufferPointer { ptr in
            whisper_full(ctx, params, ptr.baseAddress, Int32(ptr.count))
        }
        print("WhisperEngine: warmup completed (whisper_full returned \(r))")
    }
    #endif

    /// Compute the `audio_ctx` parameter for a given sample count.
    ///
    /// Whisper's encoder operates on a fixed 30s / 1500-token mel context by
    /// default. Each second of 16 kHz audio = 100 mel frames, downsampled 2x
    /// by the encoder = 50 ctx tokens. So:
    ///
    ///     audio_ctx = ceil(seconds * 50) + safety
    ///
    /// We add ~1s (50 tokens) of safety to give the encoder headroom past the
    /// last real sample. Below ~2s of audio whisper occasionally hallucinates
    /// when the context is tight, so we enforce a floor of 100 tokens. For
    /// audio >= the full 30s window we return 0, meaning "use default" — there
    /// is nothing to truncate.
    ///
    /// Returning Int32 because whisper's `audio_ctx` field is `int` in C.
    static func computeAudioCtx(sampleCount: Int) -> Int32 {
        guard sampleCount > 0 else { return 0 }
        let sampleRate = WhisperAudioFormat.sampleRate
        // Whisper's full window is 30s of audio = 1500 ctx tokens.
        let fullWindowSamples = Int(sampleRate * 30.0)
        if sampleCount >= fullWindowSamples { return 0 }

        let seconds = Double(sampleCount) / sampleRate
        let safetyTokens = 50  // ~1s of headroom
        let needed = Int((seconds * 50.0).rounded(.up)) + safetyTokens
        // Whisper sometimes hallucinates under very tight contexts; clamp up
        // to a minimum of 100 (~2s) and never exceed the default 1500.
        return Int32(min(1500, max(100, needed)))
    }

    /// Apply auto-gain so quiet recordings still hit Whisper's speech threshold.
    /// Targets a peak around 0.5 (≈ -6 dB), capped so we never amplify noise more than 20×.
    static func normalize(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var peak: Float = 0
        for s in samples { let a = abs(s); if a > peak { peak = a } }
        guard peak > 0 else { return samples }
        let target: Float = 0.5
        let gain = min(target / peak, 20.0)
        if gain <= 1.05 { return samples }
        var out = samples
        for i in 0..<out.count { out[i] = max(-1, min(1, out[i] * gain)) }
        return out
    }
}

extension WhisperEngine: TranscribingEngine {}

/// Boxed callback closure for the C bridging layer.
private final class CallbackBox: @unchecked Sendable {
    let progress: (@Sendable (Float) -> Void)?
    let isCancelled: (@Sendable () -> Bool)?
    init(progress: (@Sendable (Float) -> Void)?,
         isCancelled: (@Sendable () -> Bool)?) {
        self.progress = progress
        self.isCancelled = isCancelled
    }
}
