import Foundation
import Combine
import OSLog
import TranscriptionCore

private let serviceLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "TranscriptionService")

/// Coordinates batch transcription of recordings + one-shot transcription
/// for dictation.
///
/// Recording transcriptions go through a strict FIFO queue: only one runs at
/// a time, with `activeRecordingID` and `progress` tied to whichever job is
/// actually executing. Concurrent enqueues land in `pendingIDs` until their
/// turn, instead of fighting for the same UI state slot.
@MainActor
final class TranscriptionService: ObservableObject {
    @Published private(set) var activeRecordingID: UUID?
    @Published private(set) var pendingIDs: [UUID] = []

    /// Set to a recording's id while the OFFLINE speaker re-diarize pass is
    /// running for it (`rediarizeSegments`). This is NOT transcription —
    /// the transcript text is already final by this point; the pyannote
    /// subprocess is only re-clustering speaker labels. The UI uses this to
    /// show an accurate "Identifying speakers…" status instead of falsely
    /// implying the transcript is still being produced. `nil` when no
    /// re-diarize is in flight.
    @Published private(set) var diarizingRecordingID: UUID?
    @Published private(set) var progress: Double = 0
    @Published var lastError: String?

    /// True while the underlying whisper engine is doing a "noticeable"
    /// first-time load — currently means a sibling `-encoder.mlmodelc`
    /// is being compiled by CoreML for this device (~13s on M-series
    /// the very first time). The engine notifies us via a callback;
    /// we bridge to `@MainActor` so SwiftUI views can gate the Record
    /// button on this state. See `HomeView`'s preparation banner.
    @Published private(set) var isPreparingModel: Bool = false

    /// Human-readable status string the engine wants the UI to show
    /// alongside the spinner ("Preparing Neural Engine…"). `nil` when
    /// not preparing or when the engine didn't supply one.
    @Published private(set) var preparationStatus: String?

    /// Audio shorter than this is treated as "no recording" — Whisper happily
    /// hallucinates confident transcripts from sub-100ms noise.
    static let minimumAudioDurationSeconds: Double = 0.3
    /// Audio whose peak sample is below this is treated as silence. The
    /// auto-gain in WhisperEngine.normalize() would otherwise amplify it
    /// to clipping levels and produce ghost transcripts.
    static let minimumAudioPeak: Float = 0.005

    private let engine: any TranscribingEngine
    private let store: RecordingStore
    private let modelManager: ModelManager
    private let diarizationSettings: DiarizationSettings

    /// User's transcription backend choice (on-device vs remote API). When the
    /// remote backend is active + configured, transcription is routed through
    /// `remoteEngine` instead of the local whisper.cpp `engine`, and the
    /// local-model install gate is skipped (a remote user may have no `.bin`
    /// downloaded at all).
    private let remoteSettings: RemoteTranscriptionSettings

    /// OpenAI-compatible remote engine. Constructed unconditionally but only
    /// exercised when `remoteSettings.isActive` — cheap to hold idle (no
    /// weights, just a URLSession). Injectable so tests can substitute an
    /// engine that fails deterministically (see `RemoteTranscribing`).
    private let remoteEngine: any RemoteTranscribing

    /// Hook fired once per recording that finished transcription
    /// successfully (status == .completed, non-empty text). MilaApp
    /// wires this to `RecordingSummarizer.summarizeIfNeeded` so every
    /// completed recording auto-generates a summary when the LLM CLI
    /// is configured — independent of whether Live AI mode was on
    /// during the recording. The hook lives here (rather than inside
    /// the summarizer subscribing to store changes) so it fires
    /// exactly once per transcription, NOT on every subsequent
    /// `store.update` that touches the same recording.
    ///
    /// The second argument is `true` when the recording already had a
    /// non-empty `summary` at the moment the transcription started —
    /// i.e. the user explicitly re-transcribed an already-finished
    /// recording. Callers use that signal to force-regenerate the
    /// summary (the old one now refers to a transcript that no longer
    /// exists). For first-time transcription it's `false`.
    var onTranscriptionCompleted: ((Recording, _ wasRetranscription: Bool) -> Void)?

    private var queue: [Recording] = []
    private var worker: Task<Void, Never>?

    /// Recordings the user asked to abandon mid-run. Held in a thread-safe
    /// box because whisper.cpp's `abort_callback` polls this from a
    /// background compute thread, while writes (`cancel(_:)`) come from
    /// `@MainActor`. Without the lock, the cross-actor read would be a
    /// data race under strict concurrency.
    private let cancellation = CancellationFlag()

    /// Tracks the in-flight observer registration. Held so the prewarm
    /// path can `await` it before kicking off the first `loadIfNeeded`
    /// — without that gate, an early prewarm could begin compiling the
    /// CoreML encoder before the observer is installed on the engine
    /// actor, and `isPreparingModel` would never flip to `true`. The
    /// Record button would stay enabled and the user could start a
    /// recording while the encoder was still cold (PR #32 / Bugbot #3).
    ///
    /// Lazily assigned at the end of `init` — implicitly-unwrapped so
    /// we don't need a pre-init placeholder Task.
    private var observerSetupTask: Task<Void, Never>!

    init(store: RecordingStore,
         modelManager: ModelManager,
         diarizationSettings: DiarizationSettings,
         remoteSettings: RemoteTranscriptionSettings? = nil,
         engine: any TranscribingEngine = WhisperEngine(),
         remoteEngine: (any RemoteTranscribing)? = nil) {
        self.store = store
        self.modelManager = modelManager
        self.diarizationSettings = diarizationSettings
        // Default constructed inside this @MainActor init (a default argument
        // can't, since those evaluate in a nonisolated context). Tests that
        // don't exercise the remote path simply omit it.
        self.remoteSettings = remoteSettings ?? RemoteTranscriptionSettings()
        self.engine = engine
        self.remoteEngine = remoteEngine ?? RemoteWhisperEngine()
        // Bridge the engine's preparation callback onto the main
        // actor so SwiftUI subscribers see flips through `@Published`
        // (which is itself MainActor-isolated). The closure is
        // `@Sendable` because the engine actor invokes it from its
        // own context.
        //
        // Capture the registration Task so `prewarm` (and any other
        // entry point that calls `loadIfNeeded`) can await it before
        // touching the engine. The engine actor would serialize calls
        // FIFO anyway, but Task scheduling order between this Task
        // and the prewarm Task is undefined — without the explicit
        // await in those call sites, the first CoreML compile could
        // fire before this observer landed.
        let serviceRef = self
        self.observerSetupTask = Task { [engine] in
            await engine.setPreparationObserver { [weak serviceRef] preparing, status in
                Task { @MainActor in
                    guard let serviceRef else { return }
                    serviceRef.isPreparingModel = preparing
                    serviceRef.preparationStatus = preparing ? status : nil
                }
            }
        }
    }

    // MARK: - Prewarm

    /// Pre-load the user's default model in a detached task. Called
    /// once at app launch so the first-ever CoreML compile (~13s on
    /// M-series) happens BEFORE the user taps Record. Without this,
    /// pressing Record during the compile window produces a recording
    /// that yields `segments=0` because the encoder isn't ready yet.
    ///
    /// Failures are silent — the actual transcription path will retry
    /// `loadIfNeeded` and surface any real error there. Best-effort.
    ///
    /// `language` defaults to the user's persisted recording language;
    /// callers pass in their `RecordingLanguageSettings.current` so we
    /// pick the model the next recording is most likely to want.
    func prewarm(language: String) {
        guard let model = modelManager.model(for: language),
              modelManager.isInstalled(model) else {
            print("TranscriptionService.prewarm: skipping — no installed model for lang=\(language)")
            return
        }
        let modelURL = modelManager.url(for: model)
        let displayName = model.displayName
        // Capture as non-optional — `observerSetupTask` is implicitly
        // unwrapped on the property but force-imports here would
        // re-promote it to Optional inside the closure.
        let observerTask: Task<Void, Never> = observerSetupTask
        print("TranscriptionService.prewarm: kicking off load for \(displayName)")
        Task.detached(priority: .userInitiated) { [engine] in
            // Bugbot #3: ensure the preparation observer is registered
            // BEFORE the first CoreML compile starts — otherwise the
            // engine fires the "preparing" callback into a nil
            // observer, `isPreparingModel` never flips to true, and the
            // Record button stays enabled while the encoder is still
            // cold. The Task in `init` serializes through the same
            // engine actor, but await ordering between two independent
            // Tasks is undefined, so we make it explicit here.
            await observerTask.value
            do {
                try await engine.loadIfNeeded(modelURL: modelURL, displayName: displayName)
                print("TranscriptionService.prewarm: completed for \(displayName)")
            } catch {
                // Silent — the real transcription call will retry and
                // can surface any error through its own path.
                print("TranscriptionService.prewarm: failed for \(displayName) (will retry on first use): \(error)")
            }
        }
    }

    // MARK: - Public API

    /// Enqueue a recording for transcription. Returns immediately.
    /// Calls don't overlap — the queue drains FIFO on a single background task.
    /// Idempotent: re-enqueuing the active or already-queued recording is a no-op.
    func enqueue(_ recording: Recording) {
        if activeRecordingID == recording.id { return }
        if queue.contains(where: { $0.id == recording.id }) { return }
        queue.append(recording)
        publishPending()
        startWorkerIfNeeded()
        print("Transcribe queue: enqueued \(recording.title) [\(recording.id.uuidString.prefix(8))], queue depth: \(queue.count)")
    }

    /// Wait until the worker has fully drained the queue and gone idle.
    /// Used by tests to assert post-conditions deterministically.
    ///
    /// The loop exits the instant the queue drains, so a healthy run
    /// returns in milliseconds; `timeout` only caps a stuck run. It was
    /// 30s, which under the heavy `build-and-test` runner's load was too
    /// short — the background transcribe Task could be starved past 30s,
    /// so `waitForIdle` returned WHILE STILL BUSY and the caller asserted
    /// on stale state (flaked
    /// `test_changing_recording_language_routes_to_other_model_on_reenqueue`
    /// et al.). 90s gives the scheduler ample slack without affecting the
    /// common case; genuine deadlocks are still bounded by the CI
    /// per-test execution-time allowance.
    func waitForIdle(timeout: TimeInterval = 90) async {
        let deadline = Date().addingTimeInterval(timeout)
        while (activeRecordingID != nil || !queue.isEmpty) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Number of recordings ahead of `recording` in the queue.
    /// `nil` if the recording is not pending.
    func queuePosition(of recording: Recording) -> Int? {
        queue.firstIndex(where: { $0.id == recording.id })
    }

    /// One-shot transcription of an array of mono Float32 samples (16kHz).
    /// Used by dictation. Bypasses the queue — the engine actor still
    /// serializes work internally so this just waits its turn.
    ///
    /// The model is chosen based on `language`: Hebrew goes to ivrit.ai,
    /// English (and anything else) goes to the OpenAI turbo. If the
    /// language-best model isn't installed yet (download still in flight),
    /// we fall back to whatever's selected so the user gets *some* transcript.
    ///
    /// `audioCtx` is forwarded to the engine — see
    /// `TranscribingEngine.transcribe` for semantics. Defaults to `0`
    /// (= whisper default 1500 ctx) because the dictation path is the
    /// historical caller of this method and dictation has NOT been
    /// validated against audio_ctx truncation. Callers that want the
    /// VAD-tuned formula must pass `nil` explicitly.
    func transcribeOnce(samples: [Float], language: String, audioCtx: Int32? = 0) async -> String {
        let segs = await transcribeOnceSegments(samples: samples, language: language, audioCtx: audioCtx)
        return segs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Same as `transcribeOnce`, but returns whisper's timed segments
    /// instead of a concatenated string. Used by `LiveTranscriber` so it
    /// can keep per-segment timing through the live loop (required for
    /// rendering one line per utterance and for matching speakers to
    /// segments by time).
    ///
    /// `audioCtx` is forwarded to the engine — see
    /// `TranscribingEngine.transcribe` for semantics. Callers MUST be
    /// explicit:
    ///   * `LiveTranscriber` (VAD-bounded short utterances) → `nil`.
    ///   * Dictation (full-press audio) → `0`.
    ///   * Batch worker → never goes through here (calls `engine.transcribe`
    ///     directly with `0`).
    /// There is no default — the wrong choice silently degrades transcription
    /// quality on one path or the other, so make every call site declare its
    /// intent.
    /// Proactively verify a remote transcription backend at recording start so
    /// a bad API key or unreachable endpoint surfaces IMMEDIATELY — as the
    /// global "Transcription error" alert — instead of silently emptying the
    /// live transcript for the whole recording and only erroring on the Stop
    /// batch pass. No-op for the on-device backend.
    ///
    /// Reuses `RemoteTranscriptionSettings.testConnection()` (a cheap
    /// `GET /models`), which also refreshes the Settings status pill, then
    /// mirrors a failure into `lastError`. Non-fatal: recording proceeds and
    /// audio is saved regardless — this only gets the user a fast, actionable
    /// error rather than a mystery blank pane.
    func probeRemoteBackendIfActive() async {
        guard remoteSettings.isActive else { return }
        guard remoteSettings.isConfigured else {
            lastError = "Remote transcription is selected but not configured. Open Settings → Models to set the endpoint and API key."
            return
        }
        await remoteSettings.testConnection()
        // Drop a superseded/cancelled probe: the caller cancels this task when
        // the recording stops or a newer recording starts, so a late, out-of-
        // order failure can't overwrite UI state for a recording the user has
        // already moved past.
        if Task.isCancelled { return }
        if case .failed(let message) = remoteSettings.testStatus {
            lastError = "Remote transcription server check failed: \(message) Your audio is still being recorded — fix the endpoint or API key in Settings → Models, then re-transcribe."
        }
    }

    func transcribeOnceSegments(samples: [Float], language: String, audioCtx: Int32?) async -> [TranscriptSegment] {
        // Remote backend: route dictation/live utterances to the configured
        // endpoint too, so the user's "global backend" choice holds for every
        // path. Misconfiguration degrades to an empty result (same contract as
        // a missing local model) rather than throwing into the live loop.
        if remoteSettings.isActive {
            guard remoteSettings.isConfigured, let config = remoteSettings.currentConfig() else {
                serviceLog.log("transcribeOnceSegments: SKIP — remote backend active but not configured")
                return []
            }
            await remoteEngine.configure(config)
            do {
                let segs = try await remoteEngine.transcribe(samples: samples,
                                                             language: language,
                                                             audioCtx: audioCtx,
                                                             progress: nil,
                                                             isCancelled: nil)
                return segs
            } catch {
                // Log at .error: a remote failure (401/transport/server) repeats
                // on every utterance for the whole recording and silently empties
                // the live pane. Error level so it's visible in `log show`
                // WITHOUT --debug and stands out from the debug firehose.
                serviceLog.error("transcribeOnceSegments(remote): FAILED error=\(error.localizedDescription, privacy: .public)")
                // Surface the failure instead of returning a silently-empty
                // result that's indistinguishable from "no speech". Set once
                // (only when nothing is already showing) so a per-utterance
                // failure loop doesn't churn the alert every few seconds — the
                // record-start probe (`probeRemoteBackendIfActive`) is the
                // primary, up-front surfacing; this is the mid-recording backstop.
                if lastError == nil {
                    lastError = "Live transcription failed: \(error.localizedDescription)"
                }
                return []
            }
        }
        let candidate = modelManager.model(for: language)
        guard let model = candidate,
              modelManager.isInstalled(model) else {
            serviceLog.log("transcribeOnceSegments: SKIP — model not installed for lang=\(language, privacy: .public) candidate=\(candidate?.name ?? "nil", privacy: .public) installed=\(self.modelManager.installed, privacy: .public)")
            return []
        }
        let modelURL = modelManager.url(for: model)
        let startedAt = Date()
        serviceLog.log("transcribeOnceSegments: loading model=\(model.name, privacy: .public) at \(modelURL.path, privacy: .public)")
        // Bugbot #3: make sure the preparation observer is installed
        // before `loadIfNeeded` — see `init` for the race.
        await observerSetupTask.value
        do {
            try await engine.loadIfNeeded(modelURL: modelURL,
                                          displayName: model.displayName)
            let segs = try await engine.transcribe(samples: samples,
                                                   language: language,
                                                   audioCtx: audioCtx,
                                                   progress: nil,
                                                   isCancelled: nil)
            serviceLog.log("transcribeOnceSegments: model=\(model.name, privacy: .public) lang=\(language, privacy: .public) samples=\(samples.count, privacy: .public) elapsed=\(Date().timeIntervalSince(startedAt), privacy: .public)s segs=\(segs.count, privacy: .public)")
            return segs
        } catch {
            serviceLog.error("transcribeOnceSegments: FAILED model=\(model.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Re-run the OFFLINE speaker diarizer on an already-transcribed
    /// recording's WAV and return its segments with refreshed speaker
    /// labels — WITHOUT re-running whisper. Used by the live/authoritative
    /// stop path (meeting mode) to replace the online diarizer's
    /// over-segmented labels with the offline pipeline's global clustering,
    /// which produces far cleaner speaker counts.
    ///
    /// Returns nil (so the caller keeps the existing live speakers) when
    /// diarization isn't configured, there are no segments, the offline pass
    /// yields no turns, or it throws. The whole pass runs off-main inside
    /// `SpeakerDiarizer.diarize`.
    ///
    /// Pass `recordingID` so the UI can show an accurate "Identifying
    /// speakers…" status (via `diarizingRecordingID`) for exactly the
    /// recording being re-diarized — the transcript text is already final
    /// here, so calling this "Transcribing" would mislead.
    func rediarizeSegments(wavURL: URL, segments: [TranscriptSegment], recordingID: UUID? = nil) async -> [TranscriptSegment]? {
        guard diarizationSettings.isConfigured, !segments.isEmpty else { return nil }
        diarizingRecordingID = recordingID
        defer { diarizingRecordingID = nil }
        do {
            let turns = try await SpeakerDiarizer.diarize(wavURL: wavURL,
                                                          pythonPath: diarizationSettings.pythonPath)
            guard !turns.isEmpty else { return nil }
            var enriched = segments
            for i in enriched.indices {
                enriched[i].speaker = SpeakerDiarizer.assignSpeaker(
                    segmentStart: enriched[i].start,
                    segmentEnd: enriched[i].end,
                    turns: turns)
            }
            let normalized = Self.normalizeSpeakerLabels(in: enriched)
            let distinct = Set(normalized.compactMap(\.speaker)).count
            serviceLog.log("rediarizeSegments: offline pass labeled \(normalized.count, privacy: .public) segments with \(distinct, privacy: .public) speakers (was \(Set(segments.compactMap(\.speaker)).count, privacy: .public) live)")
            return normalized
        } catch {
            serviceLog.log("rediarizeSegments: failed (keeping live speakers): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Free engine resources synchronously. Called from the AppDelegate at
    /// shutdown so the ggml-metal device tear-down happens before libc++
    /// global destructors run (which is what triggered SIGABRT on quit).
    func shutdown() async {
        await engine.shutdown()
        await remoteEngine.shutdown()
    }

    /// Abandon the transcription of `recordingID`. If it's still in the queue
    /// it's dropped; if it's the active job, the engine's abort_callback
    /// trips on the next poll and `whisper_full` unwinds in ~100ms instead
    /// of running to the end. Idempotent — repeated calls are a no-op.
    ///
    /// We do NOT delete the recording from the store here. The caller (the
    /// rename-sheet's Cancel button) is the one that decides whether to
    /// discard the audio or keep it — keeping that policy out of the service
    /// means the service stays composable for other potential cancel paths.
    func cancel(recordingID: UUID) {
        cancellation.insert(recordingID)
        queue.removeAll { $0.id == recordingID }
        publishPending()
    }

    // MARK: - Worker

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        while let next = popNext() {
            await process(next)
        }
        worker = nil
    }

    private func popNext() -> Recording? {
        guard !queue.isEmpty else { return nil }
        let next = queue.removeFirst()
        publishPending()
        return next
    }

    private func publishPending() {
        pendingIDs = queue.map(\.id)
    }

    private func process(_ recording: Recording) async {
        // The user may have hit Cancel between enqueue and now. Don't spin up
        // the model just to throw the result away.
        if cancellation.contains(recording.id) {
            print("Transcribe skipped: \(recording.title) was cancelled before processing")
            cancellation.remove(recording.id)
            return
        }

        // Re-fetch from the store BEFORE resolving backend/model/audio so every
        // downstream choice uses the same live recording snapshot. The enqueued
        // `recording` can be stale: a re-transcribe-in-other-language switches
        // the store's `language` (via `prepareForRetranscription`) after the
        // snapshot was captured, and the previous pass's compression may have
        // renamed the audio. Picking the model from the stale `recording.language`
        // while transcribing with `working.language` (below) could load/persist
        // the wrong model for the language actually transcribed.
        // (The recording may also have been edited or soft-deleted in the gap.)
        var working = store.recordings.first(where: { $0.id == recording.id }) ?? recording
        if working.isTrashed {
            print("Transcribe skipped: \(working.title) was deleted before processing")
            return
        }

        // Resolve the backend up front. Remote skips the local-model gate
        // entirely (a remote-only user may never have downloaded a `.bin`);
        // local keeps the existing "is the model installed yet?" guards.
        let useRemote = remoteSettings.isActive
        let localModel: WhisperModel?
        let modelDisplayName: String
        if useRemote {
            guard remoteSettings.isConfigured, let config = remoteSettings.currentConfig() else {
                lastError = "Remote transcription is selected but not configured. Open Settings → Models to set the endpoint and API key."
                markFailed(recording)
                return
            }
            await remoteEngine.configure(config)
            localModel = nil
            // Label from the captured config, not remoteSettings — a Settings
            // edit mid-run must not change what's persisted to this
            // recording's modelName.
            modelDisplayName = "Remote · \(config.model)"
        } else {
            guard let model = modelManager.model(for: working.language) else {
                lastError = "No model selected."
                markFailed(recording)
                return
            }
            guard modelManager.isInstalled(model) else {
                lastError = "Whisper model is still downloading. Try again once it's ready."
                print("Transcribe skipped: model \(model.name) not installed yet")
                markFailed(recording)
                return
            }
            localModel = model
            modelDisplayName = model.displayName
        }
        let activeEngine: any TranscribingEngine = useRemote ? remoteEngine : engine

        // Snapshot pre-run summary state so the completion hook can tell
        // the summarizer "this was a re-transcription, force-regenerate."
        // We intentionally do NOT clear `summary` here — leaving the old
        // value visible during the re-run is less jarring than blanking
        // it for the ~30-60s the model takes; the post-completion
        // regenerate path replaces it atomically when the new transcript
        // is in hand. See PR body for the UX rationale.
        let hadSummaryBeforeRun = !(working.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        working.status = .running
        working.modelName = modelDisplayName
        store.update(working)

        let recordingID = recording.id
        activeRecordingID = recordingID
        progress = 0

        defer {
            // Only clear UI state if it still belongs to *us*. Defensive — with
            // a serial queue there's no overlap, but we want to be safe in
            // case a future change reintroduces it.
            if activeRecordingID == recordingID {
                activeRecordingID = nil
                progress = 0
            }
        }

        print("Transcribe begin: \(working.title) [\(recordingID.uuidString.prefix(8))]")

        // Bugbot #3: make sure the preparation observer is installed
        // before `loadIfNeeded` — see `init` for the race.
        await observerSetupTask.value

        do {
            // Local backend needs the whisper weights loaded (and the CoreML
            // encoder compiled) before transcribing. The remote engine has no
            // weights — `configure` already ran above.
            if let localModel {
                try await engine.loadIfNeeded(modelURL: modelManager.url(for: localModel),
                                              displayName: localModel.displayName)
            }
            // Resolve the audio URL from the freshly re-fetched `working`
            // record, NOT the stale `recording` snapshot captured at enqueue
            // time. A re-transcribe (right-click "Re-transcribe in …") enqueues
            // a snapshot still pointing at the original `.wav`, but the previous
            // pass's background compression may have since renamed that file to
            // `.m4a` and deleted the `.wav`. Reading the stale `.wav` path would
            // then throw "file not found", failing the re-transcribe and leaving
            // the old transcript in place. `working` always reflects the current
            // on-disk name. (Paired with the compress/re-transcribe guard in
            // `RecordingStore.compressRecordingAudio`.)
            let audioURL = store.audioURL(for: working)
            let samples = try AudioConvert.loadAsWhisperSamples(url: audioURL)
            let durationSeconds = Double(samples.count) / Double(WhisperAudioFormat.sampleRate)
            let peak = samples.map { abs($0) }.max() ?? 0
            print(String(format: "Transcribe: loaded %d samples (%.2fs, peak=%.4f) from %@",
                         samples.count, durationSeconds, peak, audioURL.lastPathComponent))

            // Reject essentially-silent / extremely-short audio BEFORE handing
            // it to Whisper. Otherwise the auto-gain step would amplify mic
            // noise to clipping levels and Whisper would hallucinate a
            // confident-looking transcript — that's the "every empty
            // recording got the same Hebrew test phrase" bug.
            if durationSeconds < Self.minimumAudioDurationSeconds || peak < Self.minimumAudioPeak {
                // Silently mark the recording failed instead of popping a
                // modal alert. Queue-driven transcription runs in the
                // background (post-record, crash recovery on launch,
                // re-transcribe button) — at none of those moments does
                // the user want a popup interrupting them. The .failed
                // status in the list is enough self-serve signal; the
                // detail view shows "No transcript yet" + a Transcribe
                // button if the user wants to retry on a noisier mic.
                print("Transcribe: rejecting \(working.title) — too short or too quiet to be real speech")
                working.status = .failed
                working.fullText = ""
                working.segments = []
                store.update(working)
                return
            }

            // Run diarization (Python subprocess) concurrently with whisper
            // transcription (in-process via ggml). They use independent
            // compute paths (Python/MPS vs whisper.cpp/Metal) and both read
            // from the same WAV file, so parallelism is safe and saves time.
            let shouldDiarize = diarizationSettings.isConfigured
            let diarPythonPath = diarizationSettings.pythonPath

            async let diarizeTask: [SpeakerTurn] = {
                guard shouldDiarize else { return [] }
                print("Transcribe: running speaker diarization...")
                do {
                    let turns = try await SpeakerDiarizer.diarize(
                        wavURL: audioURL,
                        pythonPath: diarPythonPath
                    )
                    let speakerCount = Set(turns.map(\.speaker)).count
                    print("Transcribe: diarization found \(speakerCount) speakers across \(turns.count) turns")
                    return turns
                } catch {
                    print("Transcribe: diarization failed (continuing without speakers): \(error)")
                    return []
                }
            }()

            async let transcribeTask = activeEngine.transcribe(
                samples: samples,
                language: working.language,
                // Batch path: imported files / post-record full-WAV
                // transcription. We don't have a labelled fixture set
                // for this distribution (variable length, mic, noise
                // profile), so opt out of the live-VAD-tuned audio_ctx
                // truncation and use whisper's default 1500-token
                // context. This is a deliberate fix from PR #32 review:
                // applying the formula here regressed WER on the CI
                // e2e short-clip case (en_numbers_and_dates 5.17s,
                // 0.29 → 0.36 on ggml-tiny).
                audioCtx: 0,
                progress: { [weak self] p in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard self.activeRecordingID == recordingID else { return }
                        self.progress = Double(p)
                    }
                },
                // Polled by whisper.cpp's abort_callback between every
                // compute step. Reads against the lock-protected flag set so
                // the cross-thread access is sound.
                isCancelled: { [cancellation] in
                    cancellation.contains(recordingID)
                }
            )

            let (speakerTurns, segments) = try await (diarizeTask, transcribeTask)

            // Cover the narrow window where transcription completed BEFORE the
            // user hit Cancel (so the abort_callback never tripped) but the
            // coordinator is about to delete the recording. Don't write a
            // `.completed` row to a recording that's already gone.
            if cancellation.contains(recordingID) {
                print("Transcribe cancelled post-run: \(working.title)")
                cancellation.remove(recordingID)
                return
            }

            var enrichedSegments = segments
            if !speakerTurns.isEmpty {
                for i in enrichedSegments.indices {
                    enrichedSegments[i].speaker = SpeakerDiarizer.assignSpeaker(
                        segmentStart: enrichedSegments[i].start,
                        segmentEnd: enrichedSegments[i].end,
                        turns: speakerTurns
                    )
                }
                // Normalize speaker labels to be sequential by first
                // appearance. Pyannote's clustering can yield gaps
                // (SPEAKER_00 then SPEAKER_02) when intermediate
                // clusters are merged away — which then shows up as
                // "Speaker A" + "Speaker C" with no B. Friendlier to
                // re-key everything as 00, 01, 02… in transcript order.
                enrichedSegments = Self.normalizeSpeakerLabels(in: enrichedSegments)
                let labeled = enrichedSegments.compactMap(\.speaker).count
                let distinct = Set(enrichedSegments.compactMap(\.speaker)).count
                print("Transcribe: applied speaker labels — \(labeled)/\(enrichedSegments.count) segments labeled, \(distinct) distinct speakers")
            } else {
                print("Transcribe: NO speaker labels — shouldDiarize=\(shouldDiarize), speakerTurns.count=0. Either diarization is not configured, returned no turns, or the pyannote subprocess failed (check stderr above).")
            }

            let text = enrichedSegments.map(\.text)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print("Transcribe done: \(working.title) -> \(enrichedSegments.count) segments, \(text.count) chars")

            working.segments = enrichedSegments
            working.fullText = text
            if let lastEnd = enrichedSegments.last?.end, lastEnd > 0 {
                working.duration = lastEnd
            }
            working.status = text.isEmpty ? .failed : .completed
            store.update(working)

            if working.status == .completed {
                TranscriptExporter.writeSRT(for: working, in: store.recordingsDirectory)
                onTranscriptionCompleted?(working, hadSummaryBeforeRun)
                // Shrink storage: transcode the WAV to m4a now that
                // transcription + diarization are done reading it. Runs in
                // the background so it doesn't hold up the queue; playback
                // and re-transcribe read m4a natively, re-diarize decodes
                // it. No-op on already-compressed (imported) audio.
                let compressID = working.id
                Task { await store.compressRecordingAudio(id: compressID) }
            }
        } catch is CancellationError {
            // The user hit Cancel mid-run. The rename sheet's coordinator is
            // also going to hard-delete the recording from the store — don't
            // race with that by writing a `.failed` status, and don't surface
            // a scary error banner for what was a user-initiated action.
            print("Transcribe cancelled mid-run: \(working.title)")
            cancellation.remove(recording.id)
        } catch {
            print("Transcribe error for \(working.title): \(error)")
            working.status = .failed
            store.update(working)
            lastError = "Transcription failed: \(error.localizedDescription)"
        }
    }

    /// Re-key speaker labels in transcript order so the SET of labels
    /// is contiguous `SPEAKER_00`, `SPEAKER_01`, … with no gaps. The
    /// diarizer can return `{SPEAKER_00, SPEAKER_02}` when an
    /// intermediate cluster got merged by the clustering pipeline —
    /// without this the UI would show "Speaker A, Speaker C" with no
    /// B in between, which is confusing.
    ///
    /// First-appearance order is preferred over alphabetical so the
    /// person who spoke first is always `SPEAKER_00`.
    static func normalizeSpeakerLabels(in segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var mapping: [String: String] = [:]
        var nextIndex = 0
        var output = segments
        for i in output.indices {
            guard let original = output[i].speaker, !original.isEmpty else { continue }
            if let remapped = mapping[original] {
                output[i].speaker = remapped
            } else {
                let remapped = String(format: "SPEAKER_%02d", nextIndex)
                mapping[original] = remapped
                output[i].speaker = remapped
                nextIndex += 1
            }
        }
        return output
    }

    private func markFailed(_ recording: Recording) {
        if var working = store.recordings.first(where: { $0.id == recording.id }) {
            working.status = .failed
            store.update(working)
        }
    }
}

/// Thread-safe Set<UUID> for cancelled recording IDs.
///
/// Writes happen on `@MainActor` (`TranscriptionService.cancel(_:)`); reads
/// happen synchronously on whisper.cpp's compute thread (the `abort_callback`
/// it polls every step). The lock is the simplest shape that lets both sides
/// share state without strict-concurrency violations.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<UUID> = []

    func insert(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        ids.insert(id)
    }

    func remove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        ids.remove(id)
    }

    func contains(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }
}
