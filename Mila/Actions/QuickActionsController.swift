import Foundation
import AppKit
import Combine
import OSLog
import ScreenCaptureKit
import UniformTypeIdentifiers
import AVFoundation
import TranscriptionCore

private let quickActionsLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                     category: "QuickActionsController")

/// Single entry point used by the Home tiles + sidebar buttons.
/// Hides recording/transcription orchestration from the UI layer.
@MainActor
final class QuickActionsController: ObservableObject {
    enum ActiveJob: Equatable {
        case none
        case recordingMic
        /// Unified "Record" job — mic + optionally the entire system's
        /// audio. Replaces the old separation between Voice Memo and
        /// App Audio in the UI. `withSystemAudio` controls whether the
        /// system-audio mix is layered in (driven by the home-screen
        /// checkbox).
        case recording(withSystemAudio: Bool)
        case recordingApp(processID: pid_t?, includeMic: Bool)
        case importingFile(URL)
    }

    /// Upper bound on the number of distinct speakers the LIVE diarizer
    /// found below which we skip the offline re-diarize pass entirely.
    ///
    /// The offline re-diarize (`TranscriptionService.rediarizeSegments`)
    /// only exists to fix the online diarizer's tendency to OVER-segment —
    /// it labels each utterance as it streams in and can never revise, so a
    /// single narrator can end up split across 7 `SPEAKER_NN`. Global
    /// clustering on the finished WAV collapses those back down.
    ///
    /// But over-segmentation only matters when MANY speakers were minted.
    /// For a short conversation the live pass already pinned at ≤3 distinct
    /// speakers, the labels are almost certainly correct, so re-running the
    /// heavy pyannote subprocess is wasted work and delay — "when you're
    /// done, you're just done." We re-diarize only when the live count
    /// exceeds this threshold. See `shouldRediarize(liveSpeakerCount:)`.
    static let maxLiveSpeakersToSkipRediarize = 3

    @Published private(set) var activeJob: ActiveJob = .none
    @Published private(set) var availableApps: [SCRunningApplication] = []
    @Published var isAppPickerShown = false
    /// Set when system-audio capture fails because the user hasn't granted
    /// (or has a stale grant for) Screen & System Audio Recording. The
    /// ContentView observes this to show an actionable alert.
    @Published var screenRecordingPermissionMissing = false
    /// Tripped once when a recording has been running for the silence-watch
    /// window without any meaningful audio level — the most common "why is
    /// my transcript empty?" failure (muted mic, wrong device, etc.). The
    /// alert in ContentView shows once and resets when the user dismisses.
    @Published var noSoundWarningShown = false
    /// Set when microphone permission is missing — separately surfaced
    /// from `transcription.lastError` so we can show an actionable
    /// "Open Privacy Settings" alert (mirrors the screen-recording one).
    /// The most common time this trips: the bundle ID changed (e.g.
    /// IslandWhisper → Mila rename), so macOS treats this as a brand
    /// new app and the user has to re-grant access.
    @Published var microphonePermissionMissing = false

    /// Populated when a recording was force-stopped because the Mac went
    /// to sleep (lid close on battery, low-battery sleep, etc.). Surfaced
    /// to ContentView as an alert on the next wake so the user knows why
    /// the recording ended where it did. Cleared when the user dismisses.
    @Published var sleepInterruption: SleepInterruption?

    struct SleepInterruption: Equatable {
        let recordingID: UUID
        let title: String
        let durationSeconds: Double
        let wasOnBattery: Bool
    }

    /// Holds an IOPMAssertion while a recording is active so the Mac
    /// doesn't doze off mid-meeting. Released on stop / app teardown.
    private let sleepGuard = SleepGuard()

    /// Captured at the start of `stopRecording` when the stop was forced
    /// by an impending system sleep — read by the post-stop code so the
    /// finalized recording can be surfaced in the wake-up alert.
    private var pendingSleepStopReason: SleepStopReason?

    private enum SleepStopReason {
        case willSleep
    }

    /// Silence-watch tunables — exposed on the type so tests can override
    /// (we don't want the test suite to sleep for 10 seconds).
    var silenceWatchSeconds: TimeInterval = 10
    /// Threshold the RMS-normalised AudioMeter level must exceed at least
    /// once during the watch window to be considered "the mic is hearing
    /// something". 0.05 maps to roughly -57 dB after the meter's 60 dB
    /// normalisation — quiet enough that even a very soft "hello" trips it.
    var silenceWatchLevelThreshold: Float = 0.05

    let session: RecordingSession
    let store: RecordingStore
    let transcription: TranscriptionService
    let languageSettings: RecordingLanguageSettings
    let postRecording: PostRecordingCoordinator

    /// Late-bound by `MilaApp` after construction so the controller can
    /// decide at stop time whether Live AI was active for the current
    /// recording. Init-time injection would create a chicken-and-egg
    /// problem because `LiveAISession` itself depends on `LLMSettings`
    /// (already constructed before `actions`) but its own state lives
    /// downstream of the controller. Optionals keep tests + the legacy
    /// dictation-only setup working without these dependencies.
    var llmSettings: LLMSettings?
    var liveAISettings: LiveAISettings?
    var liveAISession: LiveAISession?
    /// Set after init by MilaApp. When non-nil and the recording
    /// produced live segments, `stopRecording` saves the live
    /// transcript directly and skips the post-stop whisper +
    /// diarization re-run.
    var liveTranscriber: LiveTranscriber?
    /// Set after init by MilaApp. `stopRecording` awaits any pending
    /// diarizer work so the final utterance's speaker label lands
    /// before the transcript is saved.
    var liveDiarizer: LiveSpeakerDiarizer?

    /// True only while `stopRecording` is running its inline LIVE-PIPELINE
    /// drain — the short, bounded window where it flushes the transcriber
    /// tail, drains the diarizer queue, runs the final Live AI tick,
    /// snapshots the live state onto the saved Recording, and tears down
    /// the live singletons. The record button is disabled (and shows
    /// "Finalizing…") for exactly this window.
    ///
    /// It is NOT held across the heavy post-snapshot tail (offline
    /// re-diarize / summarize / transcode / batch enqueue) — that runs in
    /// a detached `finalizeTasks` entry so the record button frees up the
    /// moment the live pipeline is safely drained. The user can start a
    /// new recording while the prior one finishes finalizing in the
    /// background.
    ///
    /// `MilaApp.wireLiveAIPipeline`'s `.idle` state handler reads this
    /// flag — when set, it skips the duplicate drain and the
    /// transcriber/diarizer `stop()` cleanup (stopRecording owns the
    /// lifecycle and will read final state + run cleanup itself). When
    /// clear, the `.idle` handler runs its own drain — covers the
    /// lock-screen / sleep / app-quit paths that don't reach
    /// `stopRecording`.
    @Published var isFinalizingRecording: Bool = false

    /// Late-bound by MilaApp. When the live-transcript path saves a
    /// recording directly (skipping `transcription.enqueue` because the
    /// VAD path already produced segments), TranscriptionService's
    /// `onTranscriptionCompleted` hook never fires — so the summary
    /// trigger has to run from here instead. The enqueue path leans on
    /// the hook in TranscriptionService and doesn't touch this.
    var summarizer: RecordingSummarizer?

    /// Late-bound by MilaApp. Enforces the storage cap at record start:
    /// new recordings are blocked once the library reaches `limitBytes`.
    /// Existing / in-progress recordings are never touched.
    var storageSettings: RecordingStorageSettings?

    /// Active silence-watch task — cancelled when the recording stops so
    /// we never fire the warning for a recording that's already over.
    private var silenceWatchTask: Task<Void, Never>?

    /// Active record-start remote-backend probe (see `startRecording`).
    /// Single-owner: superseded when a new recording starts and cancelled
    /// when one stops, so an older probe — whose `GET /models` is still in
    /// flight against the same unchanged config (which `testConnection()`
    /// can't detect as stale) — can't land an out-of-order failure into
    /// `lastError`/`testStatus` after the user already moved on.
    private var remoteProbeTask: Task<Void, Never>?

    /// Background finalize tasks, keyed by the recording id they're
    /// finalizing. After `stopRecording` drains the live pipeline and
    /// frees the record button, the HEAVY tail of finalization — the
    /// offline re-diarize subprocess, the summarizer LLM call, the m4a
    /// transcode (or, for chunk/empty recordings, the batch
    /// transcription enqueue) — runs here so a new recording can start
    /// immediately. None of this tail touches the live singletons
    /// (`liveTranscriber` / `liveDiarizer` / `liveAISession`); it only
    /// reads the on-disk WAV + writes back to the store by id, so it's
    /// safe to overlap a fresh live recording. Mirrors
    /// `RecordingSummarizer`'s id-keyed background-task ownership model.
    private var finalizeTasks: [UUID: Task<Void, Never>] = [:]

    /// Returns true — and sets a user-facing `lastError` — when starting
    /// a new recording would exceed the configured storage cap. Called at
    /// the top of every record-start path.
    private func storageCapReached() -> Bool {
        guard let storageSettings else { return false }
        let used = store.currentUsageBytes()
        guard used >= storageSettings.limitBytes else { return false }
        let usedGB = Double(used) / 1_073_741_824.0
        transcription.lastError = String(
            format: "Storage limit reached (%.1f of %.0f GB used). Free up space or raise the limit in Settings ▸ Storage.",
            usedGB, storageSettings.limitGigabytes)
        quickActionsLog.error("recording blocked — storage cap reached (used=\(used, privacy: .public) limit=\(storageSettings.limitBytes, privacy: .public))")
        return true
    }

    init(session: RecordingSession,
         store: RecordingStore,
         transcription: TranscriptionService,
         languageSettings: RecordingLanguageSettings,
         postRecording: PostRecordingCoordinator) {
        self.session = session
        self.store = store
        self.transcription = transcription
        self.languageSettings = languageSettings
        self.postRecording = postRecording
    }

    // MARK: - Unified Record

    /// One entry point for the big "Record" button on Home. Captures
    /// the mic, and optionally layers the entire system's audio on top
    /// when `withSystemAudio` is true. Tapping a second time stops the
    /// in-progress recording. The "include app audio" preference is
    /// held by the caller (HomeView's @AppStorage toggle) so we can
    /// stay stateless about it here.
    func toggleRecord(withSystemAudio: Bool) async {
        // Block re-entry while `stopRecording`'s inline drain is in
        // flight. The drain awaits whisper / diarizer / LLM finalize
        // and each `await` releases the @MainActor — if the user taps
        // Record during that window, the .recording branch of
        // `wireLiveAIPipeline` would fire and wipe the live segments
        // out from under the snapshot we're about to read, applying
        // an empty transcript to the OLD recording's id.
        //
        // The Record button is also `.disabled(actions.isFinalizingRecording)`
        // for visual feedback, but a keyboard shortcut or AppleScript
        // can still drive this method directly — keep the guard.
        if isFinalizingRecording {
            quickActionsLog.log("toggleRecord ignored — finalize in progress")
            return
        }
        if case .recording = activeJob {
            await stopRecording()
        } else if case .recordingMic = activeJob {
            // Legacy state — shouldn't happen now that Home only routes
            // through this method, but covers a stale ActiveJob from an
            // in-flight session that started under an older code path.
            await stopRecording()
        } else if activeJob == .none {
            await startRecording(withSystemAudio: withSystemAudio)
        }
    }

    /// Unified Home entry point: the main window has independent
    /// Microphone and App-audio toggles, and the (mic, app) combination
    /// selects the source:
    ///   - mic + app  → `.meeting` (mic clocked, system audio mixed in)
    ///   - mic only   → `.microphone`
    ///   - app only   → `.systemAudio` (all system audio, no mic — the
    ///     live feed is driven straight off the system-audio stream, so
    ///     there's no mic master-clock to stall on)
    ///   - neither    → no-op (the Record button is disabled in this case)
    ///
    /// App-only routes through `startAppRecording(app: nil, ...)` — the
    /// same path the old More ▸ App Audio picker used, minus the
    /// per-app selection (Home captures the whole system mix).
    func toggleRecord(microphone: Bool, appAudio: Bool) async {
        if isFinalizingRecording {
            quickActionsLog.log("toggleRecord ignored — finalize in progress")
            return
        }
        if isRecording {
            await stopRecording()
            return
        }
        guard activeJob == .none else { return }
        guard microphone || appAudio else {
            quickActionsLog.log("toggleRecord ignored — both Microphone and App audio are off")
            return
        }
        // UI-TEST routing: when the finalize-regression E2E is driving the
        // app, the Record button tap must NOT spin up AVAudioEngine (no mic
        // on CI). Route to the fake-start seam instead; MilaApp's
        // `runFinalizeRegressionIfRequested` observes the resulting
        // `.recording` state transition and pumps the fixture WAV. Every
        // other code path (the real Stop above, the whole `stopRecording`
        // Phase A/Phase B split under test) is unchanged — only the START
        // is faked, exactly the part CI can't do for real.
        if CommandLine.arguments.contains("--ui-test-finalize-regression") {
            let url = store.freshAudioURL(suggestedName: "Recording")
            await startFakeRecordingForTesting(outputURL: url)
            return
        }
        if microphone {
            await startRecording(withSystemAudio: appAudio)
        } else {
            await startAppRecording(app: nil, includeMic: false)
        }
    }

    /// UI-TEST SEAM. Starts a recording without AVAudioEngine / the mic
    /// permission gate, so the audio-loopback E2E can drive the REAL
    /// `stopRecording` (Phase A / Phase B split) without a physical mic.
    /// Mirrors `startRecording(withSystemAudio:)`'s post-start bookkeeping
    /// — it sets `activeJob` (so `isRecording` is true and `stopRecording`
    /// builds the right title) and flips `RecordingSession.state` to
    /// `.recording` via `startFakeForTesting`, which is what
    /// `wireLiveAIPipeline` observes to wire up the live transcriber /
    /// diarizer / LLM session. The caller is responsible for pumping
    /// fixture samples into `session.onLiveSamples` and then calling
    /// `stopRecording()`.
    ///
    /// `withSystemAudio: false` so the saved recording's source is
    /// `.microphone` — the simplest path through `stopRecording`'s title /
    /// source switch and the post-stop empty-mic warning (which is a
    /// `lastError` toast, not a blocking modal, so it doesn't interfere).
    ///
    /// Guarded behind the re-entry flag like the production start paths so
    /// a second start during the prior recording's bounded Phase A drain is
    /// a no-op (the whole point of the regression: Phase A is short, so by
    /// the time the test issues recording #2 the flag is already clear).
    func startFakeRecordingForTesting(outputURL: URL) async {
        if isFinalizingRecording {
            quickActionsLog.log("startFakeRecordingForTesting ignored — finalize in progress")
            return
        }
        guard activeJob == .none else { return }
        await session.startFakeForTesting(outputURL: outputURL)
        activeJob = .recording(withSystemAudio: false)
    }

    private func startRecording(withSystemAudio: Bool) async {
        // Controller-side counterpart to HomeView's
        // `.disabled(... transcription.isPreparingModel)`. The button
        // greys out during the first-time Neural Engine compile, but
        // keyboard shortcuts / menu commands / AppleScript drive this
        // method directly and would otherwise start a recording the
        // encoder can't yet transcribe — the user would speak for a
        // minute and get `segments=0` while the model finishes compiling.
        // Mirror the `isFinalizingRecording` guard in `toggleRecord`.
        guard !transcription.isPreparingModel else {
            quickActionsLog.log("startRecording ignored — model still preparing (Neural Engine compile)")
            return
        }
        // Storage cap: refuse to start if the library is already full.
        if storageCapReached() { return }
        // Pre-flight the mic auth check — if denied we want to point the
        // user at System Settings (like we do for screen recording),
        // not surface a vague "operation couldn't be completed" error
        // from deep inside AVAudioEngine.
        guard await ensureMicrophonePermission() else { return }
        let prefix = withSystemAudio ? "Recording" : "Voice Memo"
        let url = store.freshAudioURL(suggestedName: prefix)
        // `.meeting` mixes mic + system audio; `.microphone` is mic only.
        // The pure system-audio case (`.systemAudio`) is now reachable
        // only via the More page's "App Audio" entry — Home's Record
        // button always captures the mic so the user can talk on top
        // of whatever's playing.
        let source: RecordingSource = withSystemAudio ? .meeting : .microphone
        // For system-audio-inclusive captures, the SystemAudioRecorder
        // also needs to know we want "everything" (no specific app).
        if withSystemAudio {
            session.selectApp(nil)
        }
        do {
            try await session.start(source: source, outputURL: url)
            // Guarantee a fresh, isolated Live AI session for THIS recording
            // (new Claude session UUID + cleared summary/action items) before
            // any transcript can be fed. This is the single deterministic
            // reset point — relying on the async `.recording` state observer
            // (wireLiveAIPipeline) instead risked the transition being
            // coalesced under load, leaving the previous recording's session
            // live so its first tick `--resume`d the prior meeting →
            // cross-recording summary/action-item bleed. See LiveAISession.start().
            liveAISession?.start()
            activeJob = .recording(withSystemAudio: withSystemAudio)
            sleepGuard.preventIdleSleep(reason: "Mila is recording")
            startSilenceWatch(watching: source)
            armRemoteProbe()
        } catch SystemAudioRecorder.CaptureError.permissionDenied {
            screenRecordingPermissionMissing = true
        } catch {
            if withSystemAudio, SystemAudioRecorder.isPermissionError(error) {
                screenRecordingPermissionMissing = true
            } else {
                transcription.lastError = "Could not start recording: \(error.localizedDescription)"
            }
        }
    }

    // Back-compat shim so existing call sites + tests that toggle a
    // microphone-only recording keep working. The new Home routes
    // through toggleRecord(withSystemAudio:) instead; this thin wrapper
    // exists for the menu command + UI tests.
    func toggleVoiceMemo() async {
        await toggleRecord(withSystemAudio: false)
    }

    /// Returns true iff microphone access is granted (or was just granted
    /// by the user via the system prompt). Returns false and trips
    /// `microphonePermissionMissing` if denied / restricted — caller
    /// should bail. Idempotent: calling this when already authorized is
    /// a cheap no-op.
    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            // First launch (or first launch on this bundle ID after a
            // rename). Trigger the OS prompt; the result determines
            // whether the recording proceeds.
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { microphonePermissionMissing = true }
            return granted
        case .denied, .restricted:
            microphonePermissionMissing = true
            return false
        @unknown default:
            microphonePermissionMissing = true
            return false
        }
    }

    /// Open System Settings → Privacy & Security → Microphone. Used by
    /// the in-app permission alert so the user can grant access in one
    /// click instead of hunting through Settings.
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - App audio (system + optional mic)

    func presentAppPicker() async {
        await session.refreshSystemAudioApps()
        availableApps = session.system.availableApps
        isAppPickerShown = true
    }

    func startAppRecording(app: SCRunningApplication?, includeMic: Bool) async {
        isAppPickerShown = false
        // Same Neural-Engine-preparing guard as `startRecording` — the
        // app-audio entry point isn't behind the gated Home button.
        guard !transcription.isPreparingModel else {
            quickActionsLog.log("startAppRecording ignored — model still preparing (Neural Engine compile)")
            return
        }
        // Storage cap: refuse to start if the library is already full.
        if storageCapReached() { return }
        // When the user opted into capturing their mic alongside system
        // audio, pre-flight the mic auth check too — otherwise the same
        // vague-error-after-rename trap as Voice Memo.
        if includeMic, !(await ensureMicrophonePermission()) {
            return
        }
        session.selectApp(app)
        let titleBase = app?.applicationName ?? "System Audio"
        let url = store.freshAudioURL(suggestedName: titleBase)
        do {
            let source: RecordingSource = includeMic ? .meeting : .systemAudio
            try await session.start(source: source, outputURL: url)
            // Fresh, isolated per-recording Live AI session — see the matching
            // call in startRecording() for the full rationale.
            liveAISession?.start()
            activeJob = .recordingApp(processID: app?.processID, includeMic: includeMic)
            sleepGuard.preventIdleSleep(reason: "Mila is recording")
            startSilenceWatch(watching: source)
            armRemoteProbe()
        } catch SystemAudioRecorder.CaptureError.permissionDenied {
            screenRecordingPermissionMissing = true
        } catch {
            if SystemAudioRecorder.isPermissionError(error) {
                screenRecordingPermissionMissing = true
            } else {
                transcription.lastError = "Could not start app recording: \(error.localizedDescription)"
            }
        }
    }

    /// Proactively verify a remote transcription backend now that capture is
    /// live. A bad key / unreachable endpoint otherwise stays invisible: the
    /// live path silently drops every utterance and the error only appears on
    /// the Stop batch pass (the user recorded a whole meeting before learning
    /// it failed). Non-blocking — recording already started and audio is being
    /// saved; this just races an error banner to the user. No-op for the local
    /// backend. Single-owner: cancel any prior probe so its (possibly stale)
    /// result can't overwrite UI state for this newer recording. Called from
    /// every record-start entry point (mic/meeting and app-audio) so no live
    /// path can fail silently. Cancelled in `stopRecording()`.
    private func armRemoteProbe() {
        remoteProbeTask?.cancel()
        remoteProbeTask = Task { [transcription] in
            // `cancel()` above is cooperative, so a just-superseded probe can
            // still get scheduled. Bail before touching `transcription` —
            // `probeRemoteBackendIfActive()`'s active-but-unconfigured branch
            // writes `lastError` synchronously, before any await/cancellation
            // check, so without this guard a stale probe could surface an
            // error for a recording the user has already moved past.
            guard !Task.isCancelled else { return }
            await transcription.probeRemoteBackendIfActive()
        }
    }

    /// Open the Screen & System Audio Recording pane in System Settings.
    /// Used by the in-app permission alert.
    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Stop & finalize any active recording

    func stopRecording() async {
        let captured = activeJob
        let durationBeforeStop = session.elapsed
        let sleepReason = pendingSleepStopReason
        pendingSleepStopReason = nil
        // Always cancel the silence-watch BEFORE the engine teardown so a
        // late-arriving "no sound" warning doesn't fire on a recording the
        // user already stopped (especially common for sub-10s recordings).
        silenceWatchTask?.cancel()
        silenceWatchTask = nil
        // Cancel any in-flight record-start remote probe for the same reason:
        // its failure result must not land after the recording is over.
        remoteProbeTask?.cancel()
        remoteProbeTask = nil
        // Release the sleep assertion as soon as the engine is shutting
        // down — keeping it past `stop()` would block idle sleep while
        // the user is just looking at the rename sheet.
        sleepGuard.allowIdleSleep()
        // Set `isFinalizingRecording = true` BEFORE `session.stop()` so
        // wireLiveAIPipeline's `.idle` handler (which fires during
        // session.stop()'s state transition) sees the flag and skips
        // its own drain + `transcriber.stop()`. Cursor flagged this in
        // PR review of 0c7ce08: setting the flag AFTER `await
        // session.stop()` left a window where `.idle` could call
        // `transcriber.stop()` mid-flight, wiping `liveTranscriber.
        // segments` before this function's inline drain reads them.
        // NOTE: `isFinalizingRecording` is deliberately NOT cleared by a
        // blanket `defer` here. It must stay `true` only for the bounded
        // live-pipeline drain below, and be cleared the instant that drain
        // + live-singleton teardown completes — so the record button frees
        // up before the heavy offline tail (re-diarize / summarize /
        // transcode) runs. Each early-return path clears it explicitly.
        isFinalizingRecording = true
        guard let outputURL = await session.stop() else {
            // Failed stop: still tear down the live pipelines since
            // wireLiveAIPipeline's `.idle` handler skipped its
            // teardown because of the flag. Without this, the
            // transcriber/diarizer keep stale state until the next
            // recording. Cursor (PRRT_kwDOSY2m-s6GOIj-) flagged it.
            liveTranscriber?.stop()
            liveDiarizer?.stop()
            isFinalizingRecording = false
            activeJob = .none
            return
        }
        let duration = max(durationBeforeStop, audioDuration(at: outputURL))
        let (title, source, appName): (String, RecordingSource, String?) = {
            switch captured {
            case .recordingMic:
                return (defaultTitle(prefix: "Voice Memo"), .microphone, nil)
            case .recording(let withSystemAudio):
                // Unified Record: mic only when checkbox is off, or
                // mic + system mix when on. The title stays generic —
                // every recording is just "a recording" in the new UI.
                let prefix = "Recording"
                return (defaultTitle(prefix: prefix),
                        withSystemAudio ? .meeting : .microphone,
                        nil)
            case .recordingApp(let pid, let includeMic):
                let app = availableApps.first(where: { $0.processID == pid })?.applicationName
                let prefix = app ?? "System Audio"
                return (defaultTitle(prefix: prefix),
                        includeMic ? .meeting : .systemAudio,
                        app)
            default:
                return (defaultTitle(prefix: "Recording"), .microphone, nil)
            }
        }()

        // A mic-only recording that captured zero frames produces an empty
        // WAV → empty transcript → silent ".failed". Tell the user why
        // (the recording itself is still saved, so the rename sheet appears
        // as usual — this just explains the empty result). Meeting captures
        // can still succeed on the system-audio leg, so don't warn there.
        if source == .microphone, session.lastMicFrameCount == 0 {
            transcription.lastError = "Microphone captured no audio. Check System Settings ▸ Privacy & Security ▸ Microphone, and that the input selected in Settings ▸ Audio Input isn't muted, disconnected, or in use by another app."
            quickActionsLog.error("mic-only recording captured 0 frames — surfaced audio-input guidance to the user")
        }

        // ---- IMMEDIATE: build a tentative Recording from whatever
        // live state is available RIGHT NOW (no awaits), add it to
        // the store, and present the rename sheet. Previously we
        // awaited transcribeNow + diarizer drain + LLM final tick
        // BEFORE presenting — that pushed the dialog appearance
        // anywhere from a few seconds to 30+ seconds after the user
        // tapped Stop, while their data was already visible in the
        // live pane. Now the dialog pops up instantly; the
        // background drain below updates the Recording (and thus
        // the sheet, which observes the store) as more data lands.
        let initialSegments = liveTranscriber?.segments ?? []
        let initialTranscriptSegments: [TranscriptSegment] = initialSegments.map { ls in
            TranscriptSegment(start: ls.startSeconds, end: ls.endSeconds,
                              text: ls.text, speaker: ls.speaker)
        }
        let initialSummary = (liveAISession?.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let initialItems = liveAISession?.actionItems ?? []
        // Use `.running` so the sheet shows the "transcribing in
        // progress" status icon while the background drain finishes
        // up. The flip to `.completed` (or `.pending` → `.enqueue`
        // path for the empty-segments fallback) happens at the end of
        // the drain task. Mirrors `useLiveTranscript` below: both VAD
        // and chunk modes produce live segments we want to preserve,
        // so the initial-status gate is segment-presence, not mode.
        let initialStatus: TranscriptionStatus = initialSegments.isEmpty ? .pending : .running
        let recording = Recording(
            title: title,
            duration: duration,
            source: source,
            audioFileName: outputURL.lastPathComponent,
            status: initialStatus,
            language: languageSettings.current.rawValue,
            segments: initialTranscriptSegments,
            fullText: initialTranscriptSegments.map(\.text).joined(separator: " "),
            appName: appName,
            summary: initialSummary.isEmpty ? nil : initialSummary,
            actionItems: initialItems.isEmpty ? nil : initialItems
        )
        store.add(recording)
        activeJob = .none
        if sleepReason != nil {
            sleepInterruption = SleepInterruption(
                recordingID: recording.id,
                title: recording.title,
                durationSeconds: duration,
                wasOnBattery: !SleepGuard.isOnACPower()
            )
        }
        if sleepReason == nil {
            postRecording.present(recording)
        }

        // ---- INLINE LIVE-PIPELINE DRAIN: finalize whatever was still
        // in-flight in the live singletons, then update the Recording in
        // the store so the sheet re-renders with final data.
        //
        // This drain — and ONLY this drain — runs INLINE (not in a
        // background Task), and `isFinalizingRecording` stays `true` for
        // exactly this window. Everything here reads or mutates the live
        // singletons (`liveTranscriber` / `liveDiarizer` / `liveAISession`),
        // which must NOT be touched by a background task, for two reasons:
        //
        //   1. Bugbot Finding #1: those singletons get reset on the NEXT
        //      recording's `start()` (epoch bump, `aiSession.start()`,
        //      `diarizer.reset()`). A background task reading them after a
        //      new recording started would snapshot the NEW recording's
        //      state and apply it to the OLD recording's id. The
        //      `isFinalizingRecording` re-entry guard in `toggleRecord` /
        //      `startRecording` is what holds a new recording off until
        //      this drain + the live-singleton teardown below complete.
        //
        //   2. Bugbot Finding #3: `wireLiveAIPipeline`'s `.idle`
        //      handler also drains the same pipelines. Without
        //      explicit coordination the two paths interleave —
        //      `.idle` can call `transcriber.stop()` while we're
        //      still reading state, wiping segments out from under
        //      the snapshot.
        //
        // The HEAVY tail that follows the snapshot (offline re-diarize /
        // summarize / transcode / batch enqueue) touches none of those
        // singletons, so it's split off into a background `finalizeTasks`
        // entry (`finalizeTail`) and the record button frees up before it
        // runs — letting the user start a new recording immediately.
        //
        // The sheet still appears immediately: `postRecording.present`
        // above sets a `@Published` value, which SwiftUI schedules
        // for the next runloop tick. That tick happens during the
        // first `await` below (releasing the @MainActor), so the
        // sheet renders within ~16ms even though we don't return
        // from `stopRecording` for another few seconds.
        //
        // `isFinalizingRecording` was set above (before `session.stop()`)
        // so the `.idle` handler skips its own drain + cleanup. We own
        // the lifecycle in this codepath.
        await liveTranscriber?.transcribeNow()
        await liveDiarizer?.awaitPending()
        if let diar = liveDiarizer {
            liveTranscriber?.applySpeakerLabels(diar.intervals)
        }
        // Push one final feed with the post-drain transcript so the
        // LLM tail covers up to stop. Mirrors `.idle` handler's
        // behavior; we skip the .idle drain here so we have to do
        // the feed ourselves. `awaitFinalTick` then drains both the
        // tick this feed kicks off AND any in-flight tick.
        if liveAISettings?.enabled == true,
           llmSettings?.isConfigured == true,
           let transcriber = liveTranscriber {
            let text = transcriber.formattedTranscript
            if !text.isEmpty {
                // Stop-time flush — bypass the min-interval floor so the
                // final tick covers up to stop (awaitFinalTick drains it).
                liveAISession?.feed(transcript: text, immediate: true)
            }
        }
        await liveAISession?.awaitFinalTick()

        // Snapshot final state. Safe to read now because `.idle`
        // handler is skipping its `transcriber.stop()` /
        // `diarizer.stop()` while `isFinalizingRecording` is true.
        let finalLiveSegments = liveTranscriber?.segments ?? []
        let finalSummary = (liveAISession?.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let finalItems = liveAISession?.actionItems ?? []
        // Whether the live pipeline ran in VAD mode (utterance-bounded
        // + speaker-diarized). Chunk mode produces segments too but
        // they lack speakers, so the batch pass still needs to run.
        // VAD runs independently of Live AI being on (the diarizer
        // sits at the recording-session level, not the LiveAISession
        // level), so the gate is `useVAD` only — not && enabled.
        // Cursor (PRRT_kwDOSY2m-s6GOIj4) caught this: gating on
        // `enabled` made VAD-with-LiveAI-off recordings unnecessarily
        // re-batch-transcribed.
        let vadActive = (liveAISettings?.useVAD == true)
        // Meeting mode now feeds the mic+system MIX to the live
        // transcriber (RecordingSession.consumeMic clocks off the mic and
        // mixes in buffered system audio), so the live transcript is
        // COMPLETE — app-/system-side speech is in it, not just the mic.
        // That means meeting recordings can be authoritative on the same
        // terms as any other source and no longer need a forced batch
        // re-transcribe of the WAV (which was also re-summarizing on top of
        // the live AI summary). The remaining gate is `vadActive` below:
        // chunk mode still needs the batch pass for speaker labels.
        //
        // Earlier this forced batch transcription for `.meeting` because the
        // live feed was mic-only and the saved transcript would otherwise
        // drop system-side speech (Cursor PRRT_kwDOSY2m-s6GOIjm). The live
        // feed now carries the full mix, so that no longer applies.
        // Two questions, two gates:
        //
        //   1. `hasLiveSegments`: do we have something to SHOW the user
        //      in the rename sheet right now? Both VAD and chunk-mode
        //      produce segments worth displaying immediately — wiping
        //      them on save (the old `&& vadActive` gate) made the
        //      sheet briefly show text and then go blank.
        //
        //   2. `liveTranscriptIsAuthoritative`: are the saved segments
        //      the FINAL truth, or do we still need a batch pass to
        //      add speaker labels? Only the VAD path runs the
        //      diarizer (via `transcriber.onUtteranceCaptured`) —
        //      chunk mode segments lack speaker info, so we keep
        //      them visible but enqueue for batch diarization, which
        //      overwrites them when done.
        //
        // `vadActive` here is whatever was passed in by the caller —
        // typically `liveAISettings.useVAD && liveAISettings.enabled`.
        let hasLiveSegments = !finalLiveSegments.isEmpty
        let liveTranscriptIsAuthoritative = hasLiveSegments && vadActive
        let finalTranscriptSegments: [TranscriptSegment] = finalLiveSegments.map { ls in
            TranscriptSegment(start: ls.startSeconds, end: ls.endSeconds,
                              text: ls.text, speaker: ls.speaker)
        }
        let finalFullText = finalTranscriptSegments.map(\.text).joined(separator: " ")

        guard var updated = store.recordings.first(where: { $0.id == recording.id }) else {
            // Recording was removed from the store between `add` and
            // here (e.g. user hit Cancel on the rename sheet). Nothing
            // more to update, but we still need to clean up the live
            // pipelines below before returning.
            liveTranscriber?.stop()
            liveDiarizer?.stop()
            isFinalizingRecording = false
            return
        }
        updated.segments = finalTranscriptSegments
        // Always preserve fullText when we have live segments — the
        // sheet should show what the user just saw on screen, even
        // for chunk mode while the batch diarization pass is still
        // pending. Batch will overwrite segments + fullText when done.
        updated.fullText = hasLiveSegments ? finalFullText : ""
        updated.summary = finalSummary.isEmpty ? nil : finalSummary
        updated.actionItems = finalItems.isEmpty ? nil : finalItems
        updated.status = liveTranscriptIsAuthoritative ? .completed : .pending
        store.update(updated)

        // ---- END OF THE LIVE-PIPELINE-OWNING PHASE.
        //
        // Everything above read or mutated the live singletons
        // (`liveTranscriber` / `liveDiarizer` / `liveAISession`). We've now
        // snapshotted their final state onto `updated` and written it to
        // the store, so it's safe to tear them down — and once they're
        // torn down, a NEW recording can grab them via `start()`.
        //
        // Cleanup: `.idle` handler skipped these because the flag was set.
        liveTranscriber?.stop()
        liveDiarizer?.stop()
        // Free the record button NOW. The heavy tail below (offline
        // re-diarize subprocess / summarizer LLM call / m4a transcode, or
        // the batch-transcription enqueue) touches only the on-disk WAV,
        // the store, and the already-serialized background services — never
        // the live singletons — so it's safe to run it concurrently with a
        // fresh live recording. Clearing the flag here is what lets the
        // user hit Record again immediately instead of waiting on that tail.
        isFinalizingRecording = false

        finalizeTail(for: updated, liveTranscriptIsAuthoritative: liveTranscriptIsAuthoritative)
    }

    /// Whether the offline re-diarize pass is worth running given how many
    /// distinct speakers the LIVE diarizer already found. Re-diarization
    /// only corrects OVER-segmentation, which only happens when many
    /// speakers were minted; at or below `maxLiveSpeakersToSkipRediarize`
    /// the live labels are almost certainly already right, so we skip the
    /// heavy pyannote subprocess. `liveSpeakerCount == 0` (no labels at
    /// all) also skips — there's nothing for the offline pass to clean up.
    ///
    /// Pure + `static` so the gate is unit-testable without a real
    /// diarization subprocess (which CI can't spin up).
    static func shouldRediarize(liveSpeakerCount: Int) -> Bool {
        liveSpeakerCount > maxLiveSpeakersToSkipRediarize
    }

    /// The HEAVY, live-singleton-free tail of finalization, run as a
    /// detached, id-keyed background task so the record button (freed in
    /// `stopRecording` once the live pipeline is drained) stays usable
    /// while the prior recording finishes processing.
    ///
    /// Safe to overlap a fresh live recording because it reads only the
    /// on-disk WAV and writes back to the store by recording id — it does
    /// NOT touch `liveTranscriber` / `liveDiarizer` / `liveAISession`,
    /// which the new recording owns. Whisper contention is a non-issue:
    /// the engine actor in `TranscriptionService` serializes every call
    /// (live + batch) internally, and the offline diarizer / summarizer
    /// run as their own subprocesses.
    ///
    /// `internal` (not `private`) so tests can drive the tail directly —
    /// the live-pipeline drain that precedes it in `stopRecording` needs a
    /// real audio session that CI can't spin up, but the tail itself is
    /// pure store + service work and is the part this PR decoupled.
    func finalizeTail(for recording: Recording, liveTranscriptIsAuthoritative: Bool) {
        let id = recording.id
        // Replace (and cancel) any previous tail for the same id —
        // defensive; ids are unique per recording so this shouldn't
        // collide in practice.
        finalizeTasks[id]?.cancel()
        finalizeTasks[id] = Task { @MainActor [weak self] in
            defer { self?.finalizeTasks[id] = nil }
            guard let self else { return }
            var updated = recording
            if liveTranscriptIsAuthoritative {
                // VAD path: keep the live transcript TEXT (no re-transcription),
                // but the ONLINE diarizer over-segments speakers — it labels
                // each utterance as it streams in and can never revise, so early
                // borderline embeddings spawn extra SPEAKER_NN that never merge.
                // Re-run the OFFLINE diarizer on the finished WAV (global
                // clustering → far cleaner speaker counts) and swap in its
                // labels. Skips gracefully — keeping the live speakers — if
                // diarization isn't configured or the pass fails.
                //
                // Only re-diarize when the live pass minted MORE than
                // `maxLiveSpeakersToSkipRediarize` distinct speakers —
                // that's the over-segmentation the offline pass fixes. A
                // short conversation the live diarizer already pinned at
                // ≤3 speakers is almost certainly correct, so we finalize
                // with the live labels as-is and skip the heavy pyannote
                // subprocess (saves seconds of post-record delay).
                let liveSpeakerCount = Set(updated.segments.compactMap(\.speaker)).count
                if Self.shouldRediarize(liveSpeakerCount: liveSpeakerCount) {
                    // Re-fetch before writing: the user may have renamed the
                    // recording (rename sheet) while this tail was running, so
                    // we update only the segments rather than clobbering the row.
                    if let rediarized = await self.transcription.rediarizeSegments(
                        wavURL: self.store.audioURL(for: updated),
                        segments: updated.segments,
                        recordingID: id) {
                        updated.segments = rediarized
                        if var current = self.store.recordings.first(where: { $0.id == id }) {
                            current.segments = rediarized
                            self.store.update(current)
                            updated = current
                        }
                    }
                }
                // Write the SRT sidecar + trigger the summarizer ourselves (the
                // enqueue path normally runs both via its onTranscriptionCompleted
                // hook).
                TranscriptExporter.writeSRT(for: updated, in: self.store.recordingsDirectory)
                self.summarizer?.summarizeIfNeeded(updated)
                // Shrink storage: the live transcript is authoritative and the
                // rediarize above is done reading the WAV, so transcode it to
                // m4a in the background. (The batch path does this via its own
                // completion hook in TranscriptionService.)
                await self.store.compressRecordingAudio(id: id)
            } else {
                // Chunk mode or no live segments: enqueue for batch
                // transcription. For chunk mode the batch pass overwrites
                // segments + fullText with diarized output; for the
                // empty-segments case it's the first transcription pass.
                self.transcription.enqueue(updated)
            }
        }
    }

    /// Await every in-flight background finalize tail. Test seam so a test
    /// can drive `finalizeTail` and then deterministically assert on the
    /// resulting store / queue state.
    func awaitFinalizeTails() async {
        for task in finalizeTasks.values {
            await task.value
        }
    }

    // MARK: - Sleep interruption

    /// Called by `MilaAppDelegate` when macOS posts `willSleepNotification`
    /// while a recording is active. We have a small budget (~1–2 s) before
    /// the system actually sleeps, so we mark the stop reason and await
    /// the normal stop pipeline. The wake-up alert is populated by
    /// `stopRecording` once the recording lands in the store.
    func stopBecauseOfSleep() async {
        guard isRecording else { return }
        pendingSleepStopReason = .willSleep
        await stopRecording()
    }

    /// Called by `MilaAppDelegate` on `didWakeNotification`. No-op when
    /// `sleepInterruption` is nil (the recording wasn't ours to stop, or
    /// the user already dismissed the previous wake alert).
    func notifyDidWake() {
        // The published `sleepInterruption` is what drives the ContentView
        // alert — we just need to trigger SwiftUI to observe it. Re-assign
        // to the same value so any view binding wakes up if it was
        // already nil-checked at app suspension time.
        if let info = sleepInterruption {
            sleepInterruption = info
        }
    }

    // MARK: - Open files

    func openFiles() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose audio or video files to transcribe"
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = FileTranscriber.allowedExtensions.compactMap {
                UTType(filenameExtension: $0)
            }
        }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            await transcribeFile(url)
        }
    }

    /// Video → SRT entry point exposed on the Home screen. Restricts the
    /// picker to common video container types so the workflow is obvious;
    /// after import the recording is enqueued for transcription as usual.
    /// Once it completes the user gets a banner with the path to the
    /// auto-saved .srt sidecar (or can use Export Subtitles… to save it
    /// somewhere else).
    func subtitleVideo() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose a video to generate subtitles for"
        if #available(macOS 11.0, *) {
            let exts = ["mp4", "mov", "m4v", "mkv", "webm"]
            panel.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
        }
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        await transcribeFile(url)
        postRecording.postStatus("Transcribing \(url.lastPathComponent) — Export Subtitles will be available when it finishes.")
    }

    func transcribeFile(_ url: URL) async {
        // Storage cap applies to imports too — they copy a new audio file
        // into the library, same as a recording.
        if storageCapReached() { return }
        activeJob = .importingFile(url)
        do {
            let recording = try await FileTranscriber.importFile(
                at: url,
                into: store,
                language: languageSettings.current
            )
            activeJob = .none
            transcription.enqueue(recording)
        } catch {
            activeJob = .none
            transcription.lastError = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Silence watch

    /// Spin up a one-shot watcher that polls the session's level for the
    /// first `silenceWatchSeconds` seconds of a recording. If the peak
    /// level we ever see stays under `silenceWatchLevelThreshold`, trip
    /// `noSoundWarningShown` so ContentView can pop an alert.
    ///
    /// We poll the published `micLevel` / `systemLevel` directly rather
    /// than tapping into the audio stream because the RecordingSession
    /// already does the heavy lifting (RMS via AudioMeter) — adding a
    /// second tap would mean duplicating that work for the watcher.
    ///
    /// "Just do it once" means once per recording session: we cancel the
    /// task as soon as the recording stops, and the warning latches
    /// `noSoundWarningShown = true` exactly once. ContentView resets the
    /// flag when the user dismisses the alert so the next recording can
    /// warn again if it's also silent.
    ///
    /// `source` tells us which channel to watch: a microphone-only memo
    /// watches `session.micLevel`; a system-audio capture watches
    /// `session.systemLevel`; a meeting watches whichever is louder so
    /// one quiet side doesn't false-positive the whole recording.
    private func startSilenceWatch(watching source: RecordingSource) {
        // The live-transcript pane is now the always-on visual
        // indicator that the mic is working — empty pane = nothing
        // being heard. The modal "microphone too quiet" alert that
        // used to compensate for the lack of feedback is fully
        // redundant and would just nag users who are listening more
        // than they're speaking (e.g. a meeting where the other side
        // is talking).
        //
        // Kept as a no-op (rather than deleted) so the call sites in
        // `startRecording` / `startAppRecording` don't need to change
        // and the static `silenceWatch(...)` helper remains available
        // for unit tests.
        _ = source
        silenceWatchTask?.cancel()
        silenceWatchTask = nil
    }

    /// Standalone watch loop. Returns true if the entire `totalSeconds`
    /// window elapsed without `levelProvider()` ever returning a value at
    /// or above `threshold`. Returns false if a level reading crossed the
    /// threshold or the task was cancelled mid-watch. Pulled out as a
    /// static helper so unit tests can drive it with a known level
    /// sequence without spinning up an audio engine.
    static func silenceWatch(totalSeconds: TimeInterval,
                             threshold: Float,
                             pollIntervalSeconds: TimeInterval = 0.05,
                             levelProvider: @escaping @Sendable @MainActor () -> Float) async -> Bool {
        let pollNs = UInt64(max(0.001, pollIntervalSeconds) * 1_000_000_000)
        let steps = max(1, Int(ceil(totalSeconds / max(0.001, pollIntervalSeconds))))
        for _ in 0..<steps {
            if Task.isCancelled { return false }
            let level = await MainActor.run(body: levelProvider)
            if level >= threshold { return false }
            try? await Task.sleep(nanoseconds: pollNs)
        }
        return !Task.isCancelled
    }

    // MARK: - Helpers

    var isRecording: Bool {
        switch activeJob {
        case .recordingMic, .recording, .recordingApp:
            return true
        default:
            return false
        }
    }

    var elapsed: TimeInterval { session.elapsed }
    var micLevel: Float { session.micLevel }
    var systemLevel: Float { session.systemLevel }

    private func defaultTitle(prefix: String) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "\(prefix) · \(f.string(from: Date()))"
    }

    private func audioDuration(at url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
