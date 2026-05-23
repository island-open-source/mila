import Foundation
import AppKit
import Combine
import ScreenCaptureKit
import UniformTypeIdentifiers
import AVFoundation

/// Single entry point used by the Home tiles + sidebar buttons.
/// Hides recording/transcription orchestration from the UI layer.
@MainActor
final class QuickActionsController: ObservableObject {
    enum ActiveJob: Equatable {
        case none
        case recordingMic
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

    // MARK: - Voice memo (mic only)

    func toggleVoiceMemo() async {
        if case .recordingMic = activeJob {
            await stopRecording()
        } else if activeJob == .none {
            await startVoiceMemo()
        }
    }

    private func startVoiceMemo() async {
        // Pre-flight the mic auth check — if denied we want to point the
        // user at System Settings (like we do for screen recording),
        // not surface a vague "operation couldn't be completed" error
        // from deep inside AVAudioEngine.
        guard await ensureMicrophonePermission() else { return }
        let url = store.freshAudioURL(suggestedName: "Voice Memo")
        do {
            try await session.start(source: .microphone, outputURL: url)
            activeJob = .recordingMic
            startSilenceWatch(watching: .microphone)
        } catch {
            transcription.lastError = "Could not start voice memo: \(error.localizedDescription)"
        }
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
        // Always cancel the silence-watch BEFORE the engine teardown so a
        // late-arriving "no sound" warning doesn't fire on a recording the
        // user already stopped (especially common for sub-10s recordings).
        silenceWatchTask?.cancel()
        silenceWatchTask = nil
        guard let outputURL = await session.stop() else {
            activeJob = .none
            return
        }
        let duration = max(durationBeforeStop, audioDuration(at: outputURL))
        let (title, source, appName): (String, RecordingSource, String?) = {
            switch captured {
            case .recordingMic:
                return (defaultTitle(prefix: "Voice Memo"), .microphone, nil)
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

        let recording = Recording(
            title: title,
            duration: duration,
            source: source,
            audioFileName: outputURL.lastPathComponent,
            language: languageSettings.current.rawValue,
            appName: appName
        )
        store.add(recording)
        activeJob = .none
        // Open the rename sheet immediately, in parallel with transcription.
        // The sheet watches the store for the transcript to land and
        // enables LLM-suggest / Send-to-Claude once it's ready. Dictations
        // and imported files deliberately skip this — naming a 3-second
        // dictation would be more friction than the auto-title is worth.
        postRecording.present(recording)
        transcription.enqueue(recording)
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
        silenceWatchTask?.cancel()
        let totalSeconds = silenceWatchSeconds
        let threshold = silenceWatchLevelThreshold
        let sourceCopy = source
        silenceWatchTask = Task { @MainActor [weak self] in
            let silent = await Self.silenceWatch(
                totalSeconds: totalSeconds,
                threshold: threshold,
                levelProvider: { [weak self] in
                    guard let self else { return 0 }
                    switch sourceCopy {
                    case .microphone:  return self.session.micLevel
                    case .systemAudio: return self.session.systemLevel
                    case .meeting:     return max(self.session.micLevel, self.session.systemLevel)
                    }
                }
            )
            guard let self else { return }
            // Only warn if we're still actually recording — covers the case
            // where stop() was racing with the final poll iteration.
            guard silent, !Task.isCancelled, self.isRecording else { return }
            self.noSoundWarningShown = true
        }
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
        if case .recordingMic = activeJob { return true }
        if case .recordingApp = activeJob { return true }
        return false
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
