import Foundation
import whisper
import os.log

private let whisperLog = Logger(subsystem: "io.island.mila.TranscriptionCore", category: "whisper")

/// whisper.cpp's `whisper_log_set` is a process-global single-slot
/// callback, so capture lives at file scope rather than per-actor. Lines
/// are only retained while `capturing == true` (during `loadIfNeeded`'s
/// `whisper_init_from_file_with_params` call), so steady-state allocation
/// is one empty array.
fileprivate final class WhisperLogCapture: @unchecked Sendable {
    static let shared = WhisperLogCapture()
    private let lock = NSLock()
    private var capturing = false
    private var lines: [String] = []

    /// Idempotent: safe to call multiple times. We install the callback
    /// once on first `loadIfNeeded` so any whisper.cpp output during init
    /// flows through us.
    func install() {
        whisper_log_set({ _, text, _ in
            guard let text else { return }
            WhisperLogCapture.shared.append(String(cString: text))
        }, nil)
    }

    private func append(_ s: String) {
        lock.lock()
        if capturing { lines.append(s) }
        lock.unlock()
    }

    func startCapture() {
        lock.lock()
        lines.removeAll(keepingCapacity: true)
        capturing = true
        lock.unlock()
    }

    func stopCapture() -> [String] {
        lock.lock()
        let snapshot = lines
        capturing = false
        lines.removeAll(keepingCapacity: false)
        lock.unlock()
        return snapshot
    }
}

private let installLogCaptureOnce: Void = {
    WhisperLogCapture.shared.install()
}()

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

    /// CoreML / ANE status after the most recent successful `loadIfNeeded`.
    /// Reset to `.unavailable` before each load attempt and re-derived
    /// from whisper.cpp's own init log lines (see `parseCoreMLStatus`).
    public private(set) var coreMLStatus: CoreMLStatus = .unavailable

    /// Optional callback fired around `loadIfNeeded` when the engine
    /// expects the load to take a noticeable amount of time (i.e. when
    /// a sibling `-encoder.mlmodelc` exists but has never been
    /// CoreML-compiled on this device — see
    /// `coreml.compiled.<modelName>` in UserDefaults). Called with
    /// `true` immediately before the C init, and `false` after the
    /// init returns. The second argument is an optional human-readable
    /// status string the UI can surface (e.g. "Compiling Neural Engine
    /// model…").
    private var preparationObserver: (@Sendable (Bool, String?) -> Void)?

    /// Threshold above which we consider a load to have been a "real"
    /// CoreML compile and persist the `coreml.compiled.<modelName>`
    /// flag so the next launch can skip the banner. Tuned to be well
    /// above the warm-cache load time (<1s on M-series) and well below
    /// the observed cold-compile time (~13s).
    private static let coreMLCompileThresholdSeconds: TimeInterval = 2

    public init() {}

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    public func setPreparationObserver(_ observer: (@Sendable (Bool, String?) -> Void)?) {
        self.preparationObserver = observer
    }

    public func loadIfNeeded(modelURL: URL, displayName: String) async throws {
        _ = installLogCaptureOnce
        // Reload if path matches but we previously loaded WITHOUT
        // CoreML and the sibling .mlmodelc has since appeared. The
        // race window: app-launch prewarm fires `loadIfNeeded` before
        // ModelManager finishes downloading the mlmodelc. Without this
        // re-check, the first transcribe wins and whisper stays on
        // Metal-only for the rest of the session even after the
        // mlmodelc lands. Cursor flagged on 62e1c3b.
        if loadedPath == modelURL.path {
            let mlmodelcPath = modelURL.deletingPathExtension().path + "-encoder.mlmodelc"
            let siblingNowExists = FileManager.default.fileExists(atPath: mlmodelcPath)
            let alreadyOnCoreML = (self.coreMLStatus != .unavailable)
            if !(siblingNowExists && !alreadyOnCoreML) {
                return
            }
            whisperLog.notice("Reloading \(displayName, privacy: .public) — sibling .mlmodelc now available, was loaded without CoreML")
        }
        if let ctx {
            whisper_free(ctx)
            self.ctx = nil
            self.loadedPath = nil
        }
        self.coreMLStatus = .unavailable
        var params = whisper_context_default_params()
        #if canImport(Metal)
        params.use_gpu = true
        params.flash_attn = true
        #else
        params.use_gpu = false
        params.flash_attn = false
        #endif

        // Emit a preparation notification whenever a sibling
        // `-encoder.mlmodelc` exists. CoreML's compile cache is
        // managed by the OS — we can't reliably know whether THIS
        // particular load will be cold (~13s compile) or warm
        // (<1s). A previous version of this code persisted a
        // `coreml.compiled.<model>` UserDefaults flag after the first
        // successful load and used it to gate the banner. Cursor
        // (PRRT_kwDOSY2m-s6GOIkG) flagged the failure mode: if the
        // OS's compile cache is wiped (system update, user clears
        // caches) but our UserDefaults flag stays set, the next slow
        // recompile would skip the banner and the Record button
        // would stay enabled while the encoder is recompiling.
        //
        // The simplest correct behavior: always notify (true) before
        // the load and (false) after, whenever the sibling exists.
        // On a warm load the banner appears + disappears in <1s
        // (brief flicker on app launch); on a cold compile it stays
        // up for the full ~13s and the Record button is correctly
        // disabled. A brief flicker is better than a silently
        // unresponsive Record button.
        let mlmodelcPath = modelURL.deletingPathExtension().path + "-encoder.mlmodelc"
        let hasSiblingMLModel = FileManager.default.fileExists(atPath: mlmodelcPath)
        if hasSiblingMLModel {
            preparationObserver?(true, "Preparing Neural Engine…")
            whisperLog.notice("CoreML load starting for \(displayName, privacy: .public) (sibling .mlmodelc found)")
        }

        let started = Date()
        WhisperLogCapture.shared.startCapture()
        let newCtxOptional = modelURL.path.withCString { cPath in
            whisper_init_from_file_with_params(cPath, params)
        }
        let captured = WhisperLogCapture.shared.stopCapture()
        let elapsed = Date().timeIntervalSince(started)

        // Always notify "done" if we previously notified "starting", so
        // the UI never sticks in the preparing state on a failed load.
        if hasSiblingMLModel {
            preparationObserver?(false, nil)
        }

        guard let newCtx = newCtxOptional else {
            throw Error.modelLoadFailed(modelURL.path)
        }
        self.ctx = newCtx
        self.loadedPath = modelURL.path
        self.modelName = displayName
        self.coreMLStatus = Self.parseCoreMLStatus(from: captured)
        whisperLog.notice("Loaded \(displayName, privacy: .public) coreML=\(self.coreMLStatus.description, privacy: .public) elapsed=\(elapsed, privacy: .public)s")

        if case .loaded = self.coreMLStatus, elapsed > Self.coreMLCompileThresholdSeconds {
            whisperLog.notice("CoreML cold compile detected for \(displayName, privacy: .public) (elapsed=\(elapsed, privacy: .public)s > \(Self.coreMLCompileThresholdSeconds, privacy: .public)s)")
        }

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
    ///
    /// `audioCtx` controls the whisper encoder's mel-context truncation
    /// (see `TranscribingEngine.transcribe` for full semantics):
    ///   * `nil`  → use `computeAudioCtx(sampleCount:)` (the live-VAD-tuned
    ///     formula). Safe only for VAD-bounded short utterances.
    ///   * `0`    → pass through whisper's default 1500-token (= 30s) context.
    ///     Use for dictation and imported-file batch paths (no truncation).
    ///   * positive Int32 → explicit override.
    public func transcribe(samples rawSamples: [Float],
                    language: String,
                    audioCtx: Int32? = nil,
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
        // that fully covers our samples gives a ~3-4x speedup on short clips.
        // See `computeAudioCtx` for the formula.
        //
        // SCOPE: the formula was validated only against the labelled-fixture
        // sweep for VAD-bounded short utterances (the live transcription
        // path). Other callers — dictation (sub-second to ~few-second
        // hotkey clips) and imported-file batch transcription — pass
        // `audioCtx = 0` to opt out and use whisper's default 1500-token
        // context. The CI e2e sweep on ggml-tiny flagged short-clip WER
        // regressions on at least one fixture (en_numbers_and_dates 5.17s:
        // 0.29 → 0.36) under truncation, so we stay conservative and apply
        // the speed-up only where the live VAD characteristics match the
        // validated fixture distribution.
        //
        // KNOWN (live-VAD path): the existing labelled-fixture E2E
        // (`e2e-transcription` workflow) flagged repetition / hallucination
        // on the shortest clips (~1s, e.g. "this is quiet speech" →
        // "this is quiet speech, this is quiet speech."). The user
        // explicitly chose to keep this tradeoff for the perf win; we'll
        // iterate on the formula's safety margins or floor in a follow-up
        // rather than block the perf win on a perfect-quality fix.
        // CoreML's compiled encoder mlmodelc has a FIXED input shape of
        // `(1, mel_dim, 3000)` — the whole 30s mel window. Setting
        // `params.audio_ctx` to a smaller value tells the GGML encoder
        // to truncate the input, but the CoreML encoder path can't —
        // it ignores audio_ctx (because the mlmodelc's input shape is
        // baked in at compile time) and reads garbage / produces no
        // segments. Observed live (Hebrew + English) on 1 Jun 2026:
        // whisper returns segments=0 in ~0.2s when CoreML is loaded
        // and the live-VAD path's audioCtx=nil gets computed to 750.
        //
        // So: when CoreML is engaged, force the default (0 = 1500-token
        // context = full 30s). The encoder still runs on ANE; we just
        // don't ask it to truncate. The 4× speedup from audio_ctx=750
        // is irrelevant here because the ANE encoder is already fast.
        if case .loaded = self.coreMLStatus {
            params.audio_ctx = 0
        } else {
            params.audio_ctx = audioCtx ?? Self.computeAudioCtx(sampleCount: samples.count)
        }

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
    /// by the encoder = 50 ctx tokens, so naively `audio_ctx = ceil(seconds *
    /// 50) + safety`. THIS DOES NOT WORK — see the sweep run against the
    /// labelled fixtures (`Packages/TranscriptionCore/Fixtures`) with the
    /// `large-v3-turbo` model:
    ///
    ///   audio_ctx | pass | WER avg | elapsed
    ///   ------------------------------------
    ///   0 (=1500) | 9/9  | 0.06    | 13s   ← baseline (whisper default)
    ///   500       | 8/9  | fails on en_meeting_notes
    ///   600       | 0/9  | silent fail (whisper emits nothing)
    ///   700       | 8/9  | fails on he_toda_raba
    ///   750       | 9/9  | 0.06    | 3s    ⭐ 4× faster, identical quality
    ///   800       | 0/9  | silent fail
    ///   1000      | 8/9  | fails on he_toda_raba
    ///   1500      | 9/9  | 0.06    | 5s    ← explicit full ctx
    ///
    /// Only TWO values produce identical-quality output: 750 (half of the
    /// trained 1500) and 1500 itself. Other values either silently fail (0
    /// segments out) or degrade specific clips. The first audio_ctx
    /// implementation in this PR shipped the naive formula, hit silent
    /// fails on every short clip in CI, and got reverted — the user then
    /// pushed for a real fixture-driven sweep, which produced this table.
    ///
    /// Policy:
    ///   * For audio shorter than 15s: use audio_ctx=750 (= 15s capacity,
    ///     covers our VAD-bounded 1-10s utterances with margin; one of two
    ///     known-good values).
    ///   * For audio 15s-30s: return 0 (= whisper's default 1500). At 750
    ///     the encoder's capacity is only 15s of mel context, so a clip in
    ///     this range would be silently TRUNCATED — past callers all went
    ///     through the live-VAD path (max 10s) so this range was never
    ///     exercised in production, but a `nil` audioCtx passed by any
    ///     future caller in this range would lose audio. Falling back to
    ///     the default keeps the formula self-correct.
    ///   * For audio >= 30s: return 0 (whisper truncates to 30s anyway).
    static func computeAudioCtx(sampleCount: Int) -> Int32 {
        guard sampleCount > 0 else { return 0 }
        let sampleRate = WhisperAudioFormat.sampleRate
        // 750 mel ctx tokens = 15s of audio capacity (50 ctx tokens / sec
        // after the encoder's 2x downsample). Past this we'd truncate.
        let truncatedCapacitySamples = Int(sampleRate * 15.0)
        if sampleCount >= truncatedCapacitySamples { return 0 }
        // 750 — the "discrete safe subdivision of 1500" point that
        // whisper's encoder accepts (see fixture sweep above).
        return 750
    }

    /// Classify whisper.cpp's init-time log lines into a `CoreMLStatus`.
    ///
    /// whisper.cpp's published log strings during CoreML init are:
    ///   * `<func>: loading Core ML model from '<path>'` — attempts load
    ///   * `<func>: Core ML model loaded` — load succeeded
    ///   * `<func>: failed to load Core ML model from '<path>'` — load failed
    ///
    /// When no sibling `.mlmodelc` exists, whisper.cpp emits the "loading"
    /// line and then the "failed" line. To distinguish "intended but failed"
    /// from "never present", we only report `.failed` when the "loading"
    /// line referenced a path that actually exists on disk — otherwise we
    /// treat it as the benign "no .mlmodelc sibling" case (`.unavailable`).
    static func parseCoreMLStatus(from lines: [String]) -> CoreMLStatus {
        let joined = lines.joined(separator: "")
        let loaded = joined.contains("Core ML model loaded")
        let failed = joined.contains("failed to load Core ML model")

        if loaded {
            for line in lines {
                if let r = line.range(of: "loading Core ML model from '") {
                    let tail = line[r.upperBound...]
                    if let endQuote = tail.firstIndex(of: "'") {
                        return .loaded(path: String(tail[..<endQuote]))
                    }
                }
            }
            return .loaded(path: "")
        }
        if failed {
            for line in lines {
                if let r = line.range(of: "failed to load Core ML model from '") {
                    let tail = line[r.upperBound...]
                    if let endQuote = tail.firstIndex(of: "'") {
                        let path = String(tail[..<endQuote])
                        // If the .mlmodelc doesn't exist, the "failed" line is
                        // just whisper.cpp reporting "no sibling found" — the
                        // user simply hasn't installed CoreML weights, which
                        // isn't a failure.
                        if FileManager.default.fileExists(atPath: path) {
                            return .failed(reason: "init failed at \(path)")
                        }
                    }
                }
            }
            return .unavailable
        }
        return .unavailable
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
