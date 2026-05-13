import Foundation
import whisper

/// Thin Swift wrapper around the whisper.cpp C API.
/// All work happens off the main actor.
actor WhisperEngine {
    enum Error: Swift.Error, LocalizedError {
        case modelLoadFailed(String)
        case transcribeFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let path): return "Failed to load Whisper model at \(path)"
            case .transcribeFailed(let code): return "whisper_full failed (code \(code))"
            }
        }
    }

    private var ctx: OpaquePointer?
    private var loadedPath: String?
    private(set) var modelName: String?

    init() {}

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    func loadIfNeeded(modelURL: URL, displayName: String) async throws {
        if loadedPath == modelURL.path { return }
        if let ctx {
            whisper_free(ctx)
            self.ctx = nil
            self.loadedPath = nil
        }
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        let path = (modelURL.path as NSString).utf8String
        guard let newCtx = whisper_init_from_file_with_params(path, params) else {
            throw Error.modelLoadFailed(modelURL.path)
        }
        self.ctx = newCtx
        self.loadedPath = modelURL.path
        self.modelName = displayName

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
    }

    /// Synchronous transcription of a complete sample buffer.
    /// `progress` is invoked with values in `0...1` from inside the C callback.
    func transcribe(samples rawSamples: [Float],
                    language: String,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) throws -> [TranscriptSegment] {
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

        let userBox = CallbackBox(progress: progress, isCancelled: isCancelled)
        let userPtr = Unmanaged.passRetained(userBox).toOpaque()
        defer { Unmanaged<CallbackBox>.fromOpaque(userPtr).release() }

        params.progress_callback = { _, _, p, userData in
            guard let userData else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
            box.progress?(Float(p) / 100.0)
        }
        params.progress_callback_user_data = userPtr

        // Wire ggml's abort_callback to our cancellation flag. ggml polls this
        // between every compute step, so when the user hits Cancel mid-run
        // whisper_full unwinds within ~100ms instead of running to completion
        // and burning CPU on a transcript we're about to throw away.
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
        // The user cancelled mid-run. whisper_full returns non-zero when the
        // abort_callback fires — swallow that as cancellation, not as a
        // surprise engine failure the UI should surface to the user.
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
    func shutdown() {
        if let ctx {
            whisper_free(ctx)
            self.ctx = nil
            self.loadedPath = nil
            self.modelName = nil
        }
    }

    // MARK: - Internal

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
        print("WhisperEngine: metal warmup completed (whisper_full returned \(r))")
    }
}

extension WhisperEngine: TranscribingEngine {}

extension WhisperEngine {
    /// Apply auto-gain so quiet recordings still hit Whisper's speech threshold.
    /// Targets a peak around 0.5 (≈ -6 dB), capped so we never amplify noise more than 20×.
    fileprivate static func normalize(_ samples: [Float]) -> [Float] {
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
