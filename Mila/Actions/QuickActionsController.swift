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

    /// True while `stopRecording` is running its inline drain and
    /// finalize. `MilaApp.wireLiveAIPipeline`'s `.idle` state handler
    /// reads this flag — when set, it skips the duplicate drain and
    /// the transcriber/diarizer `stop()` cleanup (stopRecording owns
    /// the lifecycle and will read final state + run cleanup itself).
    /// When clear, the `.idle` handler runs its own drain — covers
    /// the lock-screen / sleep / app-quit paths that don't reach
    /// `stopRecording`.
    @Published var isFinalizingRecording: Bool = false

    /// Late-bound by MilaApp. When the live-transcript path saves a
    /// recording directly (skipping `transcription.enqueue` because the
    /// VAD path already produced segments), TranscriptionService's
    /// `onTranscriptionCompleted` hook never fires — so the summary
    /// trigger has to run from here instead. The enqueue path leans on
    /// the hook in TranscriptionService and doesn't touch this.
    var summarizer: RecordingSummarizer?

    /// Active silence-watch task — cancelled when the recording stops so
    /// we never fire the warning for a recording that's already over.
    private var silenceWatchTask: Task<Void, Never>?

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

    private func startRecording(withSystemAudio: Bool) async {
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
            activeJob = .recording(withSystemAudio: withSystemAudio)
            sleepGuard.preventIdleSleep(reason: "Mila is recording")
            startSilenceWatch(watching: source)
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
            activeJob = .recordingApp(processID: app?.processID, includeMic: includeMic)
            sleepGuard.preventIdleSleep(reason: "Mila is recording")
            startSilenceWatch(watching: source)
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
        // Release the sleep assertion as soon as the engine is shutting
        // down — keeping it past `stop()` would block idle sleep while
        // the user is just looking at the rename sheet.
        sleepGuard.allowIdleSleep()
        guard let outputURL = await session.stop() else {
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

        // ---- INLINE DRAIN: finalize what was still in-flight, then
        // update the Recording in the store so the sheet re-renders
        // with final data.
        //
        // The drain runs INLINE (not in a background Task) for two
        // reasons:
        //
        //   1. Bugbot Finding #1: a background Task reads
        //      `liveTranscriber`, `liveDiarizer`, `liveAISession` —
        //      all singletons that get reset on the NEXT recording's
        //      `start()`. If the user pressed Record before the
        //      background Task finished, the Task would snapshot the
        //      new recording's state and apply it to the OLD
        //      recording's id.
        //
        //   2. Bugbot Finding #3: `wireLiveAIPipeline`'s `.idle`
        //      handler also drains the same pipelines. Without
        //      explicit coordination the two paths interleave —
        //      `.idle` can call `transcriber.stop()` while we're
        //      still reading state, wiping segments out from under
        //      the snapshot.
        //
        // The sheet still appears immediately: `postRecording.present`
        // above sets a `@Published` value, which SwiftUI schedules
        // for the next runloop tick. That tick happens during the
        // first `await` below (releasing the @MainActor), so the
        // sheet renders within ~16ms even though we don't return
        // from `stopRecording` for another few seconds.
        //
        // `isFinalizingRecording` tells the `.idle` handler to skip
        // its own drain + cleanup — we own the lifecycle in this
        // codepath.
        isFinalizingRecording = true
        defer { isFinalizingRecording = false }
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
                liveAISession?.feed(transcript: text)
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
        // Bugbot: chunk mode (useVAD=false) also accumulates real segments
        // in the live pane while recording. The old `&& vadActive` gate
        // wiped `fullText` to "" on save for chunk-mode recordings —
        // the rename sheet would briefly show text and then go blank
        // until batch transcription caught up. Treat any non-empty live
        // segment list as authoritative; both modes produce keepable
        // output.
        let useLiveTranscript = !finalLiveSegments.isEmpty
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
            return
        }
        updated.segments = finalTranscriptSegments
        updated.fullText = useLiveTranscript ? finalFullText : ""
        updated.summary = finalSummary.isEmpty ? nil : finalSummary
        updated.actionItems = finalItems.isEmpty ? nil : finalItems
        updated.status = useLiveTranscript ? .completed : .pending
        store.update(updated)

        if useLiveTranscript {
            // Mirror the enqueue path's post-success side effect:
            // write `.srt` sidecar so video / subtitle workflows
            // find it next to the WAV.
            TranscriptExporter.writeSRT(for: updated, in: store.recordingsDirectory)
            // The enqueue path runs the summary trigger via
            // TranscriptionService's onTranscriptionCompleted hook,
            // but this branch bypassed enqueue. Fire it here — the
            // summarizer's gate skips redundant work when a live
            // summary already exists.
            summarizer?.summarizeIfNeeded(updated)
        } else {
            transcription.enqueue(updated)
        }

        // Cleanup: `.idle` handler skipped these because of the flag.
        // Now that we've snapshotted everything we needed, it's safe
        // to tear down the live pipelines.
        liveTranscriber?.stop()
        liveDiarizer?.stop()
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
