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

    let session: RecordingSession
    let store: RecordingStore
    let transcription: TranscriptionService
    let languageSettings: RecordingLanguageSettings
    let postRecording: PostRecordingCoordinator

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
        let url = store.freshAudioURL(suggestedName: "Voice Memo")
        do {
            try await session.start(source: .microphone, outputURL: url)
            activeJob = .recordingMic
        } catch {
            transcription.lastError = "Could not start voice memo: \(error.localizedDescription)"
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
        session.selectApp(app)
        let titleBase = app?.applicationName ?? "System Audio"
        let url = store.freshAudioURL(suggestedName: titleBase)
        do {
            let source: RecordingSource = includeMic ? .meeting : .systemAudio
            try await session.start(source: source, outputURL: url)
            activeJob = .recordingApp(processID: app?.processID, includeMic: includeMic)
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
        guard let outputURL = await session.stop() else {
            activeJob = .none
            return
        }
        let duration = max(durationBeforeStop, audioDuration(at: outputURL))
        let (title, source): (String, RecordingSource) = {
            switch captured {
            case .recordingMic:
                return (defaultTitle(prefix: "Voice Memo"), .microphone)
            case .recordingApp(let pid, let includeMic):
                let appName = availableApps.first(where: { $0.processID == pid })?.applicationName
                let prefix = appName ?? "System Audio"
                return (defaultTitle(prefix: prefix),
                        includeMic ? .meeting : .systemAudio)
            default:
                return (defaultTitle(prefix: "Recording"), .microphone)
            }
        }()

        let recording = Recording(
            title: title,
            duration: duration,
            source: source,
            audioFileName: outputURL.lastPathComponent,
            language: languageSettings.current.rawValue
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
