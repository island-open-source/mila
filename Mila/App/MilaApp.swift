import SwiftUI
import AppKit
import Combine
import OSLog
import Sparkle

/// Wraps Sparkle's `SPUStandardUpdaterController` so SwiftUI menu items can
/// observe `canCheckForUpdates` and disable themselves while a check is
/// already in flight. Created once at app launch — Sparkle starts its
/// scheduled background poll immediately (interval comes from
/// `SUScheduledCheckInterval` in Info.plist).
@MainActor
final class UpdaterViewModel: ObservableObject {
    let controller: SPUStandardUpdaterController
    @Published var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

extension Notification.Name {
    /// Posted from `ContentView` whenever NavigationSplitView's column
    /// visibility flips (the user toggled the sidebar). The
    /// `MilaAppDelegate` listens so it can re-run the
    /// "freeze sidebar to withinWindow blending" chrome hack on the
    /// freshly-added NSVisualEffectViews — without that, opening the
    /// sidebar shows a frame of the default behindWindow material
    /// (which looks like a flicker).
    static let milaSidebarVisibilityDidChange = Notification.Name("milaSidebarVisibilityDidChange")
}

@main
struct MilaApp: App {
    @NSApplicationDelegateAdaptor(MilaAppDelegate.self) private var appDelegate

    @StateObject private var store: RecordingStore
    @StateObject private var storageSettings: RecordingStorageSettings
    @StateObject private var modelManager: ModelManager
    @StateObject private var transcription: TranscriptionService
    @StateObject private var dictation: DictationController
    @StateObject private var actions: QuickActionsController
    @StateObject private var session: RecordingSession
    @StateObject private var hotkeySettings: HotkeySettings
    @StateObject private var languageSettings: RecordingLanguageSettings
    @StateObject private var audioInputSettings: AudioInputSettings
    @StateObject private var inputLevelMonitor: InputLevelMonitor
    @StateObject private var llmSettings: LLMSettings
    @StateObject private var postRecording: PostRecordingCoordinator
    @StateObject private var diarizationSettings: DiarizationSettings
    @StateObject private var meetingDetectionSettings: MeetingDetectionSettings
    @StateObject private var meetingDetector: MeetingDetector
    @StateObject private var meetingPrompt: MeetingPromptCoordinator
    @StateObject private var liveAISettings: LiveAISettings
    @StateObject private var liveTranscriber: LiveTranscriber
    @StateObject private var liveSpeakerDiarizer: LiveSpeakerDiarizer
    @StateObject private var liveAISession: LiveAISession
    /// Generates a one-shot LLM summary for every finished recording
    /// whenever the user's LLM CLI is configured (Live AI mode no
    /// longer gates this). Held as a `@StateObject` so it survives
    /// SwiftUI redraws and so its in-flight task table survives
    /// alongside everything else.
    @StateObject private var recordingSummarizer: RecordingSummarizer
    @StateObject private var updater = UpdaterViewModel()

    init() {
        // RecordingStore's no-arg init handles the legacy migration and
        // opens at the default Application Support location. The
        // storage-settings instance owns the security-scoped bookmark
        // resolution; we apply any user override by calling
        // `relocateRecordings(to:)` once both are constructed.
        let store = RecordingStore()
        let storage = RecordingStorageSettings()
        if let custom = storage.customDirectory {
            store.relocateRecordings(to: custom)
        }
        let mgr = ModelManager(modelsDirectory: store.modelsDirectory)
        // Diarization is on by default for fresh installs so the bundled
        // Python runtime auto-downloads its torch wheels on first launch
        // and speaker labels work without the user opening Settings. Users
        // who previously toggled the setting either way have an explicit
        // value persisted, which shadows this default. Passed as a ctor
        // argument rather than registered on `UserDefaults.standard` because
        // the unit-test process loads MilaApp as TEST_HOST — a global
        // registration would leak into tests and fire DiarizationSettings'
        // launch-time checkDeps subprocess, starving the cooperative thread
        // pool that timing-sensitive tests depend on.
        let diarSettings = DiarizationSettings(defaultEnabledIfUnset: true)
        let svc = TranscriptionService(store: store, modelManager: mgr, diarizationSettings: diarSettings)
        let session = RecordingSession()
        let langSettings = RecordingLanguageSettings()
        let audioSettings = AudioInputSettings()
        let inputMonitor = InputLevelMonitor()
        inputMonitor.preferredUID = audioSettings.preferredUID
        let llm = LLMSettings()
        let coordinator = PostRecordingCoordinator(store: store, transcription: svc)
        let actions = QuickActionsController(session: session,
                                             store: store,
                                             transcription: svc,
                                             languageSettings: langSettings,
                                             postRecording: coordinator)
        let hotkeys = HotkeySettings()
        // UI-test bypass for the hardware gate: hosted macos-26 runners
        // sometimes report as MacBook Air via `hw.model`, which trips
        // the Live AI gate and stops the live-transcript fixture/RTL
        // routes from rendering. When the UI-test flags are set, force
        // a non-Air capability so `isLiveAIAvailable` returns true for
        // every downstream check (ContentView routing,
        // wireLiveAIPipeline, etc.) — the production hardware gate is
        // untouched in real launches. Centralising the bypass here is
        // simpler and less error-prone than sprinkling
        // `CommandLine.arguments` checks at every gate.
        let uiTestForcesLiveAI =
            CommandLine.arguments.contains("--ui-test-rtl-live-hebrew")
            || CommandLine.arguments.contains(where: { $0.hasPrefix("--ui-test-inject-fixture-wav=") })
        let liveAICapabilities: SystemCapabilities = uiTestForcesLiveAI
            ? SystemCapabilities(
                modelIdentifier: SystemCapabilities.live.modelIdentifier,
                marketingName: "MacBook Pro",
                isMacBookAir: false,
                physicalRamGB: SystemCapabilities.live.physicalRamGB,
                performanceCoreCount: SystemCapabilities.live.performanceCoreCount
            )
            : .live
        let liveAI = LiveAISettings(capabilities: liveAICapabilities)
        let liveTrans = LiveTranscriber(transcription: svc)
        // Dictation gets its OWN LiveTranscriber instance so triggering
        // a dictation overlay while a meeting recording is in flight
        // (or vice versa) doesn't clobber the other's buffer / tick
        // task. They share the underlying TranscriptionService — the
        // engine itself serialises whisper calls per-actor — but the
        // streaming state stays independent.
        let dictationTrans = LiveTranscriber(transcription: svc)
        // UI-test seed for the Hebrew RTL alignment regression test
        // (see `DetailLayoutUITests.test_hebrew_live_segments_hug_right_edge_with_sidebar_open`).
        // We do this AFTER constructing the live transcriber rather
        // than inside its init so the seed doesn't depend on whatever
        // order Swift evaluates the @MainActor isolation of init vs
        // CommandLine population — putting it here makes it deterministic.
        os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
            .log("MilaApp.init args=\(CommandLine.arguments.joined(separator: " "), privacy: .public)")
        // UI-test launch args that override persisted settings so the
        // workflow can pick the recording language without depending on
        // whatever the host's UserDefaults happens to have.
        if CommandLine.arguments.contains("--ui-test-recording-lang-en") {
            langSettings.current = .english
        } else if CommandLine.arguments.contains("--ui-test-recording-lang-he") {
            langSettings.current = .hebrew
        }
        // CI E2E: point LLMSettings at a Claude CLI installed on the
        // runner. With ANTHROPIC_API_KEY set in the env, the CLI
        // authenticates non-interactively and Live AI's session loop
        // runs for real instead of being silently skipped because
        // `isConfigured == false`.
        if let arg = CommandLine.arguments.first(where: {
            $0.hasPrefix("--ui-test-llm-claude=")
        }) {
            let path = String(arg.dropFirst("--ui-test-llm-claude=".count))
            llm.tool = .claude
            llm.executablePath = path
        }
        // CI E2E: swap whichever language-best model the catalog would
        // normally pick out for a small `ggml-tiny.bin` so cold-load +
        // transcribe stays under ~10s instead of 60-200s.
        if let arg = CommandLine.arguments.first(where: {
            $0.hasPrefix("--ui-test-tiny-model-path=")
        }) {
            let path = String(arg.dropFirst("--ui-test-tiny-model-path=".count))
            mgr.setTestModelOverride(URL(fileURLWithPath: path))
        }
        if CommandLine.arguments.contains("--ui-test-rtl-live-hebrew") {
            liveTrans.seedForTesting([
                LiveSegment(id: UUID(), startSeconds: 0, endSeconds: 2,
                            text: "שלום לכולם וברוכים הבאים לפגישה",
                            speaker: nil, stable: true),
                LiveSegment(id: UUID(), startSeconds: 2, endSeconds: 5,
                            text: "היום נסקור את התוכנית לרבעון הבא",
                            speaker: nil, stable: true),
                LiveSegment(id: UUID(), startSeconds: 5, endSeconds: 8,
                            text: "ונחלק את העבודה בין החברים",
                            speaker: nil, stable: true)
            ])
            os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                .log("seeded \(liveTrans.segments.count, privacy: .public) Hebrew segments for UI test")
        }
        let liveDiar = LiveSpeakerDiarizer()
        let liveSession = LiveAISession(llmSettings: llm, liveAISettings: liveAI)
        let summarizer = RecordingSummarizer(store: store,
                                             llmSettings: llm,
                                             liveAISettings: liveAI)
        // Wire the post-transcription summary hook. Fires for every
        // recording that the queue successfully completes — the
        // summarizer's own `shouldSummarize` gate skips work if a
        // live summary already landed, if the LLM CLI isn't
        // configured, or if the transcript came up empty.
        //
        // When `wasRetranscription` is true the recording had an old
        // summary referring to the previous transcript; we force-
        // regenerate so the user doesn't end up with a stale summary
        // that disagrees with what the segments now say.
        svc.onTranscriptionCompleted = { [weak summarizer] rec, wasRetranscription in
            if wasRetranscription {
                summarizer?.regenerate(rec)
            } else {
                summarizer?.summarizeIfNeeded(rec)
            }
        }
        // Late-bind the live-AI dependencies onto `actions` so it can
        // attach summary/items to the saved Recording and skip the
        // rename sheet when Live AI was running.
        actions.llmSettings = llm
        actions.liveAISettings = liveAI
        actions.liveAISession = liveSession
        actions.liveTranscriber = liveTrans
        actions.liveDiarizer = liveDiar
        actions.summarizer = summarizer
        actions.storageSettings = storage
        let meetingSettings = MeetingDetectionSettings()
        let detector = MeetingDetector()
        let promptCoordinator = MeetingPromptCoordinator(
            detector: detector,
            settings: meetingSettings,
            actions: actions
        )
        _store = StateObject(wrappedValue: store)
        _storageSettings = StateObject(wrappedValue: storage)
        _modelManager = StateObject(wrappedValue: mgr)
        _transcription = StateObject(wrappedValue: svc)
        _diarizationSettings = StateObject(wrappedValue: diarSettings)
        _session = StateObject(wrappedValue: session)
        _actions = StateObject(wrappedValue: actions)
        _hotkeySettings = StateObject(wrappedValue: hotkeys)
        _languageSettings = StateObject(wrappedValue: langSettings)
        _audioInputSettings = StateObject(wrappedValue: audioSettings)
        _inputLevelMonitor = StateObject(wrappedValue: inputMonitor)
        _llmSettings = StateObject(wrappedValue: llm)
        _postRecording = StateObject(wrappedValue: coordinator)
        _meetingDetectionSettings = StateObject(wrappedValue: meetingSettings)
        _meetingDetector = StateObject(wrappedValue: detector)
        _meetingPrompt = StateObject(wrappedValue: promptCoordinator)
        _liveAISettings = StateObject(wrappedValue: liveAI)
        _liveTranscriber = StateObject(wrappedValue: liveTrans)
        _liveSpeakerDiarizer = StateObject(wrappedValue: liveDiar)
        _liveAISession = StateObject(wrappedValue: liveSession)
        _recordingSummarizer = StateObject(wrappedValue: summarizer)
        let dictationController = DictationController(store: store,
                                                      transcription: svc,
                                                      hotkeySettings: hotkeys,
                                                      liveTranscriber: dictationTrans)
        dictationController.storageSettings = storage
        _dictation = StateObject(wrappedValue: dictationController)
    }

    var body: some Scene {
        WindowGroup("Mila") {
            ContentView()
                .environmentObject(store)
                .environmentObject(storageSettings)
                .environmentObject(modelManager)
                .environmentObject(transcription)
                .environmentObject(dictation)
                .environmentObject(actions)
                .environmentObject(session)
                .environmentObject(hotkeySettings)
                .environmentObject(languageSettings)
                .environmentObject(audioInputSettings)
                .environmentObject(inputLevelMonitor)
                .environmentObject(llmSettings)
                .environmentObject(postRecording)
                .environmentObject(diarizationSettings)
                .environmentObject(liveAISettings)
                .environmentObject(liveTranscriber)
                .environmentObject(liveSpeakerDiarizer)
                .environmentObject(liveAISession)
                .frame(minWidth: 1000, minHeight: 640)
                .task { ensureDefaultModelsInstalled() }
                .task { prewarmDefaultModel() }
                .task { await diarizationSettings.runHealthCheck() }
                .task { await diarizationSettings.runStartupCheckDepsIfNeeded() }
                .task { await diarizationSettings.startAutoBootstrapIfNeeded() }
                .onAppear { wireDelegate() }
                .task { maybeRelocateBundle() }
                .task { enqueueRecoveredRecordings() }
                .task { startMeetingDetectionIfNeeded() }
                .task { await wireLiveAIPipeline() }
                .task { await injectFixtureWavIfRequested() }
                .task { await runFinalizeRegressionIfRequested() }
                .task { recordingSummarizer.backfillIfNeeded() }
                .environmentObject(recordingSummarizer)
                .environmentObject(meetingDetectionSettings)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Voice Memo") {
                    Task { await actions.toggleVoiceMemo() }
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Open Audio File…") {
                    Task { await actions.openFiles() }
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Dictation") {
                Button("English Dictation (\(hotkeySettings.binding(for: .dictateEnglish).displayName))") {
                    Task { await dictation.toggle(action: .dictateEnglish) }
                }
                Button("Hebrew Dictation (\(hotkeySettings.binding(for: .dictateHebrew).displayName))") {
                    Task { await dictation.toggle(action: .dictateHebrew) }
                }
            }
            // Surface the diagnostic-report action under Help so a user
            // with a bug to report can hand off a zip without us asking
            // for ad-hoc Console.app exports or screenshots.
            CommandGroup(after: .help) {
                Button("Save Diagnostic Report…") {
                    Task { await saveDiagnosticReport() }
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(storageSettings)
                .environmentObject(modelManager)
                .environmentObject(hotkeySettings)
                .environmentObject(transcription)
                .environmentObject(audioInputSettings)
                .environmentObject(inputLevelMonitor)
                .environmentObject(actions)
                .environmentObject(llmSettings)
                .environmentObject(diarizationSettings)
                .environmentObject(meetingDetectionSettings)
                .environmentObject(liveAISettings)
        }
    }

    /// Build a diagnostic zip and let the user pick where to save it.
    /// Errors surface through the standard transcription.lastError alert
    /// — there's already plumbing for showing a one-shot error toast,
    /// no need to invent a new error-presentation path for this menu
    /// item.
    private func saveDiagnosticReport() async {
        do {
            _ = try await DiagnosticReporter.saveReportInteractively(
                store: store,
                diarization: diarizationSettings
            )
        } catch {
            transcription.lastError = "Could not build diagnostic report: \(error.localizedDescription)"
        }
    }

    /// One-time per launch: if the bundle is installed at the legacy
    /// IslandWhisper.app path, offer the user a rename-and-relaunch.
    /// See `BundleRelocator` for the why + safety constraints (only
    /// runs against /Applications or ~/Applications, never overwrites
    /// an existing Mila.app at the destination, persists a skip flag
    /// if the user declines).
    private static var didCheckBundleRename = false
    private func maybeRelocateBundle() {
        guard !Self.didCheckBundleRename else { return }
        Self.didCheckBundleRename = true
        BundleRelocator.relocateIfNeeded()
    }

    private func wireDelegate() {
        appDelegate.transcription = transcription
        appDelegate.session = session
        appDelegate.dictation = dictation
        appDelegate.modelManager = modelManager
        appDelegate.actions = actions
        appDelegate.startScreenLockObserversIfNeeded()
    }

    /// Start the meeting-detection background poll + bind it to the
    /// user's enabled toggle. Called once from the main `WindowGroup`
    /// `.task` so the work is tied to the app's lifetime rather than
    /// to any single view.
    private func startMeetingDetectionIfNeeded() {
        meetingPrompt.start()
        meetingPrompt.bindEnabledChanges()
    }

    /// Wire the Live AI pipeline. Observes `RecordingSession.state` and
    /// starts/stops the live transcriber, diarizer, and LLM session
    /// when a recording is in flight + the feature is enabled +
    /// LLM is configured.
    ///
    /// CI E2E injection seam. If `--ui-test-inject-fixture-wav=PATH`
    /// is present, kicks off a fake recording (no AVAudioEngine) and
    /// pumps the WAV's samples through `session.onLiveSamples` at the
    /// real-time 16kHz rate. The rest of the pipeline (VAD →
    /// transcriber → diarizer → LiveAISession) runs exactly as in
    /// production because they all observe `session.state` / get
    /// wired by `wireLiveAIPipeline`'s `.recording` branch.
    ///
    /// Avoids depending on a real microphone or BlackHole (which
    /// doesn't reliably route audio on macos-26 CI runners).
    ///
    /// The injected samples are run through `AdaptiveGainController`
    /// before being handed to `onLiveSamples` so the E2E exercises the
    /// same gain stage that `MicrophoneRecorder` applies on a real
    /// mic. Without this the AGC e2e would be meaningless (the WAV
    /// would reach the live VAD un-boosted regardless of the toggle).
    /// `--ui-test-disable-agc` lets the test inject the raw, un-boosted
    /// signal to verify AGC is what's bridging the gap.
    @MainActor
    private func injectFixtureWavIfRequested() async {
        // The finalize-regression seam reuses `--ui-test-inject-fixture-wav=`
        // but drives its own start/pump/stop cycle through
        // `QuickActionsController`; if both ran they'd both flip
        // `session.state` and fight over the fake recording. Defer entirely
        // to `runFinalizeRegressionIfRequested` when that flag is present.
        guard !CommandLine.arguments.contains("--ui-test-finalize-regression") else { return }
        guard let arg = CommandLine.arguments.first(where: {
            $0.hasPrefix("--ui-test-inject-fixture-wav=")
        }) else { return }
        let wavPath = String(arg.dropFirst("--ui-test-inject-fixture-wav=".count))
        guard FileManager.default.fileExists(atPath: wavPath) else {
            os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                .log("inject-fixture: WAV missing at \(wavPath, privacy: .public)")
            return
        }
        let agcEnabled = !CommandLine.arguments.contains("--ui-test-disable-agc")
        // Hand wireLiveAIPipeline a moment to mount its $state observer
        // BEFORE we flip session.state — otherwise we'd transition to
        // .recording before there's a listener to react.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let sessionRef = session
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-fake-recording-\(UUID().uuidString).wav")
        // Start through QuickActionsController, NOT session directly. Routing
        // via `startFakeRecordingForTesting` sets `activeJob = .recording` so
        // `actions.isRecording` flips true — which is what
        // `ContentView.shouldShowLiveAIRecordingView` keys off to swap Home
        // for `LiveAIRecordingView`. Calling `session.startFakeForTesting`
        // alone only moves `session.state` to `.recording` (enough to wire the
        // live transcriber via `wireLiveAIPipeline`), but leaves `activeJob ==
        // .none`, so the app stays on Home and the `liveTranscript.*` a11y
        // elements never mount — the throughput/AGC E2Es then time out waiting
        // for a `liveTranscript.segment` that exists only in the (background)
        // pipeline, never in the view tree.
        await actions.startFakeRecordingForTesting(outputURL: outputURL)
        // Wait for wireLiveAIPipeline to install onLiveSamples (it
        // does so once the .recording case fires). Poll up to ~3s.
        for _ in 0..<60 {
            if sessionRef.onLiveSamples != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
            .log("inject-fixture: pumping \(wavPath, privacy: .public) agc=\(agcEnabled ? "on" : "off", privacy: .public)")
        await Self.pumpFixtureWAV(path: wavPath, to: sessionRef, agcEnabled: agcEnabled)
    }

    /// CI E2E seam for the "record while the previous recording finalizes"
    /// regression (PR `fix/record-while-finalizing`). Distinct from
    /// `injectFixtureWavIfRequested` — that one pumps a single recording
    /// forever for the throughput/AGC tests; this one is TEST-DRIVEN: the UI
    /// test taps the real Record button to start / stop each recording, and
    /// this seam supplies the audio so a recording produces real live
    /// segments without a mic. It lets the UI test assert that:
    ///
    ///   1. Stop #1 frees the Record button quickly (Phase A is bounded and
    ///      `isFinalizingRecording` clears the moment the live pipeline is
    ///      drained — it is NOT held across the heavy Phase B tail). In the
    ///      buggy pre-PR code the flag was held by a blanket `defer` across
    ///      the whole finalize, so a second Start was blocked until the tail
    ///      finished.
    ///   2. Recording #2 can start and finalize while #1's heavy tail
    ///      (rediarize / SRT / summarize / transcode, or batch enqueue) is
    ///      still settling in the background, and BOTH recordings end up in
    ///      the store with their live transcripts intact (neither clobbers
    ///      the other — the id-keyed `finalizeTasks` ownership model).
    ///
    /// Triggered by `--ui-test-finalize-regression`. The button tap is
    /// routed to `QuickActionsController.startFakeRecordingForTesting`
    /// (which skips AVAudioEngine) by the `toggleRecord` interception. This
    /// task just watches `session.$state`: each time a recording starts it
    /// kicks a ONE-SHOT finite fixture pump so the live transcriber produces
    /// real segments. (The post-record rename sheet is suppressed under the
    /// same flag in `PostRecordingCoordinator.present`, so Home and the
    /// Record button stay reachable for the next tap without any dismiss
    /// dance here.)
    ///
    /// Reuses the same `--ui-test-inject-fixture-wav=` /
    /// `--ui-test-tiny-model-path=` launch args as the throughput test so
    /// the workflow wiring is shared.
    @MainActor
    private func runFinalizeRegressionIfRequested() async {
        guard CommandLine.arguments.contains("--ui-test-finalize-regression") else { return }
        guard let arg = CommandLine.arguments.first(where: {
            $0.hasPrefix("--ui-test-inject-fixture-wav=")
        }) else { return }
        let wavPath = String(arg.dropFirst("--ui-test-inject-fixture-wav=".count))
        guard FileManager.default.fileExists(atPath: wavPath) else {
            os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                .log("finalize-regression: WAV missing at \(wavPath, privacy: .public)")
            return
        }
        let sessionRef = session
        var pumpTask: Task<Void, Never>?
        // Watch for the test tapping Record (→ .recording) and Stop
        // (→ .stopping → .idle). On each fresh .recording, pump the fixture
        // once so the live transcriber produces real segments.
        for await state in sessionRef.$state.values {
            switch state {
            case .recording:
                guard pumpTask == nil else { break }
                os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                    .log("finalize-regression: .recording — arming one-shot fixture pump")
                pumpTask = Task { @MainActor in
                    // Wait for wireLiveAIPipeline to install onLiveSamples
                    // on the .recording transition before pumping (≤ ~3s).
                    for _ in 0..<60 {
                        if sessionRef.onLiveSamples != nil { break }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    await Self.pumpFixtureWAVOnce(path: wavPath, to: sessionRef, agcEnabled: true)
                }
            case .stopping:
                break
            case .idle:
                pumpTask?.cancel()
                pumpTask = nil
            }
        }
    }

    /// Like `pumpFixtureWAV` but pumps the fixture exactly ONCE and returns
    /// (no infinite loop). Used by the finalize-regression seam, which needs
    /// each recording to have a finite tail it can stop on. The fixture is
    /// only ~5-10s so a recording's worth of segments lands quickly even on
    /// CI's slow first whisper cold-load.
    private static func pumpFixtureWAVOnce(path: String,
                                           to session: RecordingSession,
                                           agcEnabled: Bool) async {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let (samples, sampleRate) = Self.decodeWAV(data: data) else {
            os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                .log("finalize-regression: failed to decode WAV at \(path, privacy: .public)")
            return
        }
        let agc = AdaptiveGainController(sampleRate: sampleRate, enabled: agcEnabled)
        let chunkSamples = Int(sampleRate * 0.02)  // 20ms
        let startedAt = Date()
        var pumped = 0
        var offset = 0
        while offset < samples.count {
            if Task.isCancelled { return }
            let end = min(offset + chunkSamples, samples.count)
            var chunk = Array(samples[offset..<end])
            if agcEnabled {
                chunk = agc.process(chunk)
            }
            session.onLiveSamples?(ArraySlice(chunk))
            offset = end
            pumped += chunk.count
            let elapsedTarget = Double(pumped) / sampleRate
            let elapsedReal = Date().timeIntervalSince(startedAt)
            if elapsedTarget > elapsedReal {
                let napNs = UInt64((elapsedTarget - elapsedReal) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: napNs)
            }
        }
    }

    /// Read a 16kHz mono WAV from disk and feed it to
    /// `session.onLiveSamples` in 20ms chunks paced at real-time.
    /// Supports the two WAV variants the fixture generator emits:
    /// 16-bit PCM (afconvert / our concat path) and 32-bit float
    /// (RecordingSession's own output format).
    ///
    /// When `agcEnabled` is true, every chunk passes through a fresh
    /// `AdaptiveGainController` first — mirrors the path a real mic
    /// takes through `MicrophoneRecorder`, which is what makes the
    /// AGC-recovery E2E meaningful for a deliberately quiet fixture.
    private static func pumpFixtureWAV(path: String,
                                       to session: RecordingSession,
                                       agcEnabled: Bool) async {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        // Locate the "data" chunk — afconvert emits a standard
        // RIFF/WAVE so the data chunk starts at byte 44 in practice,
        // but parsing it lets us tolerate fmt chunks of different
        // sizes (e.g. with an `fact` chunk for float WAVs).
        guard let (samples, sampleRate) = Self.decodeWAV(data: data) else {
            os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                .log("inject-fixture: failed to decode WAV at \(path, privacy: .public)")
            return
        }
        // Match MicrophoneRecorder: one controller for the lifetime of
        // the (fake) recording, so attack/release smoothing accumulates
        // across chunks. `enabled=false` makes it a bit-for-bit
        // passthrough — exactly what the negative AGC test wants.
        let agc = AdaptiveGainController(sampleRate: sampleRate, enabled: agcEnabled)
        let chunkSamples = Int(sampleRate * 0.02)  // 20ms
        let startedAt = Date()
        var pumped = 0
        // Loop the fixture indefinitely — the test runs for ~2 min but
        // our generated fixture is only ~70s. Without looping, segments
        // plateau halfway through the test and the "no 30s stall"
        // assertion would trip on what's actually just "audio ran out".
        // Real conversations don't stop after 70s either.
        while !Task.isCancelled {
            var offset = 0
            while offset < samples.count {
                if Task.isCancelled { return }
                let end = min(offset + chunkSamples, samples.count)
                // Copy out the chunk so we can mutate it in place
                // through AGC without touching the source array.
                var chunk = Array(samples[offset..<end])
                if agcEnabled {
                    chunk = agc.process(chunk)
                }
                session.onLiveSamples?(ArraySlice(chunk))
                offset = end
                pumped += chunk.count
                // Pace ourselves: stay one chunk's worth ahead of wall
                // clock so VAD / whisper run at real-time speed.
                let elapsedTarget = Double(pumped) / sampleRate
                let elapsedReal = Date().timeIntervalSince(startedAt)
                if elapsedTarget > elapsedReal {
                    let napNs = UInt64((elapsedTarget - elapsedReal) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: napNs)
                }
            }
            os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                .log("inject-fixture: looping, pumped=\(pumped, privacy: .public) samples so far gain=\(agc.currentGain, privacy: .public)")
        }
    }

    /// Minimal RIFF/WAVE decoder. Returns mono Float32 samples in
    /// [-1, 1] + the sample rate, or nil on parse failure. Handles
    /// both 16-bit PCM and 32-bit float; collapses stereo to mono.
    private static func decodeWAV(data: Data) -> (samples: [Float], sampleRate: Double)? {
        guard data.count > 44 else { return nil }
        guard data.prefix(4) == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8) else { return nil }
        var idx = 12
        var fmtTag: UInt16 = 0
        var channels: UInt16 = 1
        var sampleRate: UInt32 = 16_000
        var bitsPerSample: UInt16 = 16
        var dataStart = -1
        var dataLen = 0
        while idx + 8 <= data.count {
            let id = String(data: data[idx..<idx+4], encoding: .ascii) ?? ""
            let size = Int(data[idx+4..<idx+8].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
            let payloadStart = idx + 8
            switch id {
            case "fmt ":
                fmtTag = data[payloadStart..<payloadStart+2].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
                channels = data[payloadStart+2..<payloadStart+4].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
                sampleRate = data[payloadStart+4..<payloadStart+8].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                bitsPerSample = data[payloadStart+14..<payloadStart+16].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
            case "data":
                dataStart = payloadStart
                dataLen = size
            default:
                break
            }
            idx = payloadStart + size
            if dataStart >= 0 { break }
        }
        guard dataStart >= 0, dataStart + dataLen <= data.count else { return nil }
        let payload = data[dataStart..<dataStart+dataLen]
        var samples: [Float] = []
        if fmtTag == 1 && bitsPerSample == 16 {
            // 16-bit PCM
            let count = dataLen / 2
            samples.reserveCapacity(count / Int(channels))
            payload.withUnsafeBytes { raw in
                let i16 = raw.bindMemory(to: Int16.self)
                if channels == 1 {
                    for i in 0..<count {
                        samples.append(Float(i16[i]) / 32768.0)
                    }
                } else {
                    let frames = count / Int(channels)
                    for f in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<Int(channels) {
                            sum += Float(i16[f * Int(channels) + c]) / 32768.0
                        }
                        samples.append(sum / Float(channels))
                    }
                }
            }
        } else if fmtTag == 3 && bitsPerSample == 32 {
            // 32-bit float
            let count = dataLen / 4
            samples.reserveCapacity(count / Int(channels))
            payload.withUnsafeBytes { raw in
                let f32 = raw.bindMemory(to: Float.self)
                if channels == 1 {
                    for i in 0..<count {
                        samples.append(f32[i])
                    }
                } else {
                    let frames = count / Int(channels)
                    for f in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<Int(channels) {
                            sum += f32[f * Int(channels) + c]
                        }
                        samples.append(sum / Float(channels))
                    }
                }
            }
        } else {
            return nil
        }
        return (samples, Double(sampleRate))
    }

    /// MilaApp is a struct so we can't `[weak self]` here — but every
    /// dependency is a `@StateObject` (reference type), which is what
    /// the closures actually need. Captured directly by reference.
    @MainActor
    private func wireLiveAIPipeline() async {
        let transcriber = liveTranscriber
        let diarizer = liveSpeakerDiarizer
        let aiSession = liveAISession
        let aiSettings = liveAISettings
        let llmSettingsRef = llmSettings
        let diarSettings = diarizationSettings
        let langSettings = languageSettings
        let sessionRef = session
        // `actions` captured weakly so the .idle handler can read
        // its `isFinalizingRecording` flag to decide whether the
        // drain belongs here (sleep/lock/quit path) or to
        // `stopRecording` (Stop-button path).
        let actionsRef: QuickActionsController? = actions

        var feedTask: Task<Void, Never>?
        var aiEnabledCancellable: AnyCancellable?

        // Hardware gate: re-checked PER-RECORDING (not at function
        // level) so the user can toggle `forceLiveAIOnLowEndHardware`
        // mid-session and have the next recording pick up the change.
        // The old function-level early-return meant flipping the
        // override required an app relaunch (flagged by Cursor on
        // baeeb8c: "wireLiveAIPipeline runs once at launch and returns
        // immediately when isLiveAIAvailable is false. Toggling
        // forceLiveAIOnLowEndHardware updates isLiveAIAvailable but
        // never starts the session observer").
        //
        // The state observer below runs forever now; the `.recording`
        // branch is where we gate on `aiSettings.isLiveAIAvailable`.

        for await state in sessionRef.$state.values {
            switch state {
            case .recording:
                guard aiSettings.isLiveAIAvailable else {
                    // Hardware below the Live AI bar AND no override
                    // flipped. Recording still runs via RecordingSession;
                    // QuickActionsController enqueues a post-record
                    // transcribe on stop. We just skip the live
                    // pipeline setup.
                    //
                    // BUT: clear the transcriber's `segments` /
                    // `useVAD` first. Without this, a stale live
                    // transcript from a previous recording (when the
                    // user had the override toggle on) would still be
                    // sitting in memory; `stopRecording` would
                    // snapshot it onto the new recording and could
                    // mark it `.completed` without ever running batch
                    // transcription. Cursor flagged on 62e1c3b.
                    _ = transcriber.stop()
                    sessionRef.onLiveSamples = nil
                    // Also clear LiveAISession so its rolling `summary`
                    // and `actionItems` from a previous override-enabled
                    // recording don't leak onto this gated capture.
                    // `stopRecording` reads aiSession.summary /
                    // actionItems unconditionally; without this reset,
                    // a previous Live AI session's output would attach
                    // to a recording that never ran the LLM loop.
                    // Cursor flagged on c95d2bb.
                    aiSession.cancel()
                    os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                        .log("wireLiveAIPipeline: .recording skipped — hardware below Live AI bar (model=\(aiSettings.capabilities.marketingName, privacy: .public))")
                    continue
                }
                // Live transcription runs on every recording — it's how
                // the recording UI shows the live transcript pane even
                // when AI mode is off. Apply the user's tick-interval
                // setting before start() so the running loop picks it
                // up (default 5s, settable in Settings → Live AI).
                transcriber.chunkSeconds = aiSettings.chunkSeconds
                transcriber.useVAD = aiSettings.useVAD
                // Wire each VAD-bounded utterance into the speaker
                // diarizer. Without this, diarizer.process is never
                // called, intervals stays empty, and segments never
                // get a speaker label.
                transcriber.onUtteranceCaptured = { [weak diarizer] samples, start, end in
                    // Use `submit` (chained, trackable) rather than a
                    // detached task — at end-of-recording we need to
                    // `awaitPending()` so the final utterance's
                    // speaker label is attached before the transcript
                    // is saved.
                    diarizer?.submit(samples: samples, startSeconds: start, endSeconds: end)
                }
                transcriber.start(language: langSettings.current.rawValue)
                print("wireLiveAIPipeline: .recording — installing onLiveSamples → liveTranscriber.ingest")
                sessionRef.onLiveSamples = { [weak transcriber] samples in
                    // The callback is invoked synchronously from
                    // RecordingSession.write (already @MainActor), so we
                    // can ingest directly without spawning a Task —
                    // hopping through a detached Task here was dropping
                    // the ArraySlice on some Swift-concurrency edge.
                    transcriber?.ingest(samples)
                }
                // Always reset Live AI session state at .recording —
                // this clears stale `summary` / `actionItems` from a
                // previous recording so the AI pane never shows
                // last meeting's content if the user toggles Live AI
                // on mid-recording. start() is cheap (no subprocess
                // until the first feed) and only allocates a session
                // UUID for Claude.
                aiSession.start()
                diarizer.reset()
                diarizer.similarityThreshold = aiSettings.speakerSimilarityThreshold
                // Detach the diarizer start so a quick stop-after-start
                // doesn't block the state observer on pyannote cold-init.
                Task.detached(priority: .userInitiated) { [diarizer, diarSettings] in
                    await diarizer.start(diarization: diarSettings)
                }
                // Watch for off→on transitions on the Live AI toggle.
                // The feed loop only kicks when new segments land, so
                // a user who toggles Live AI on mid-recording would
                // otherwise wait up to one chunk before the LLM sees
                // anything. Mirror the feed-loop's gate here so an
                // immediate feed runs the moment the toggle flips.
                aiEnabledCancellable?.cancel()
                aiEnabledCancellable = aiSettings.$enabled
                    .dropFirst()
                    .filter { $0 }
                    .sink { [weak transcriber, weak aiSession] _ in
                        guard llmSettingsRef.isConfigured else { return }
                        if let text = transcriber?.formattedTranscript, !text.isEmpty {
                            aiSession?.feed(transcript: text)
                        }
                    }

                feedTask?.cancel()
                feedTask = Task { @MainActor [weak transcriber, weak diarizer, weak aiSession, aiSettings, llmSettingsRef] in
                    var lastFed = ""
                    guard let transcriber else { return }
                    for await _ in transcriber.$segments.values {
                        if Task.isCancelled { break }
                        // Recompute each tick — Live AI is whatever
                        // the toggle currently says. Recording started
                        // with it off + flipped on → ticks fire from
                        // now on. Recording started with it on +
                        // flipped off → ticks stop; the LLM session
                        // preserves whatever it has produced so far.
                        let aiActive = aiSettings.enabled && llmSettingsRef.isConfigured
                        // Speaker labels are a transcription feature,
                        // not an LLM feature — apply them whenever the
                        // diarizer has produced intervals, regardless
                        // of whether the user has the LLM CLI
                        // configured.
                        if let diarizer {
                            transcriber.applySpeakerLabels(diarizer.intervals)
                        }
                        if aiActive {
                            let text = transcriber.formattedTranscript
                            if text != lastFed, !text.isEmpty {
                                lastFed = text
                                aiSession?.feed(transcript: text)
                            }
                        }
                    }
                }
            case .stopping:
                // Don't tear down yet — RecordingSession.stop() still
                // flushes the buffered system-audio tail during
                // `.stopping`, calling write() (and onLiveSamples) one or
                // two more times. We need `onLiveSamples` and the
                // transcriber to remain live so the last chunk lands in the
                // live pane and produces a final Live AI update. Cleanup
                // happens when state lands at `.idle`.
                break
            case .idle:
                feedTask?.cancel()
                feedTask = nil
                aiEnabledCancellable?.cancel()
                aiEnabledCancellable = nil
                // Coordination with QuickActionsController.stopRecording:
                // when the user hits the Stop button, stopRecording
                // sets `isFinalizingRecording = true` and runs an
                // inline drain (transcribeNow + LLM feed +
                // diarizer.awaitPending + applySpeakerLabels) so it
                // can snapshot final state, write the saved
                // Recording, and only THEN tear down the live
                // pipelines. If we ran the drain here too, the two
                // paths would race — `transcriber.stop()` could fire
                // before stopRecording reads `liveTranscriber?.
                // segments`, wiping the snapshot to empty.
                //
                // So: when stopRecording owns the lifecycle, this
                // handler does only session-level cleanup (clear
                // onLiveSamples). When stopRecording is NOT the
                // trigger — sleep / lock-screen / app-quit /
                // cancelAll — we run the full drain here so the
                // tail doesn't get lost.
                let stopRecordingOwnsFinalize = actionsRef?.isFinalizingRecording == true
                if !stopRecordingOwnsFinalize {
                    // Force one last whisper pass on whatever's in
                    // the buffer so the tail of the meeting (up to
                    // ~chunkSeconds since the previous tick) makes
                    // it into the live pane and the saved Live AI
                    // snapshot.
                    await transcriber.transcribeNow()
                    // Same idea for the LLM: if new segments just
                    // landed and Live AI is on, push one final feed.
                    if aiSettings.enabled && llmSettingsRef.isConfigured {
                        let text = transcriber.formattedTranscript
                        if !text.isEmpty {
                            aiSession.feed(transcript: text)
                        }
                    }
                    _ = transcriber.stop()
                    // Drain the diarizer's chained background work
                    // BEFORE killing the daemon. The daemon stays
                    // alive until every queued embed has landed; if
                    // we stop()'d first, pending continuations would
                    // resume with `error: "stopped"` and the final
                    // utterance would lose its speaker label.
                    await diarizer.awaitPending()
                    diarizer.stop()
                }
                // Note: don't cancel aiSession here — QuickActionsController
                // still needs to read .summary and .actionItems out of
                // it when assembling the saved Recording. The next
                // .recording transition's `aiSession.start()` clears
                // these.
                sessionRef.onLiveSamples = nil
            }
        }
    }

    /// Crash-recovery sweep + stale-status cleanup. Two things happen
    /// here at launch:
    ///   1. Any recording left in `.running` from a previous session
    ///      (the app died while whisper was mid-transcription OR while
    ///      the stop-time live-drain in `QuickActionsController` was
    ///      still in flight) is reset to `.pending` and re-enqueued for
    ///      transcription — provided its `.wav` is still on disk.
    ///      Without re-enqueue, the row would sit in `.running` forever
    ///      (the worker never publishes it on the new process) and the
    ///      Queue view's "still-pending fallback" keeps showing it.
    ///      If the WAV is gone we fall back to `.failed` so the row
    ///      doesn't loop forever trying to read a missing file.
    ///   2. Orphan .wav files re-attached by RecordingStore as
    ///      `.pending` are enqueued for transcription so the user
    ///      gets a usable transcript on the next launch without
    ///      having to do anything.
    /// The silent-/short-audio rejection inside TranscriptionService
    /// no longer pops a modal alert; the recording is just marked
    /// `.failed` in the list so empty orphans don't nag the user at
    /// launch.
    private func enqueueRecoveredRecordings() {
        // 1. Reset stale .running recordings. The current process
        //    hasn't started its worker loop yet — anything still
        //    flagged .running must be a leftover.
        let fm = FileManager.default
        for recording in store.recordings where recording.status == .running {
            let wavURL = store.audioURL(for: recording)
            var fixed = recording
            if fm.fileExists(atPath: wavURL.path) {
                // Stop-time drain or batch worker died mid-transcription;
                // the audio is still on disk, so re-queue for a fresh
                // batch run instead of stranding the row at `.failed`
                // (which has no recovery path the user can self-serve).
                fixed.status = .pending
                store.update(fixed)
                print("MilaApp: re-enqueuing stale .running recording \(recording.audioFileName)")
                transcription.enqueue(fixed)
            } else {
                fixed.status = .failed
                store.update(fixed)
                print("MilaApp: reset stale .running recording \(recording.audioFileName) to .failed (WAV missing)")
            }
        }

        // 2. Auto-enqueue recovered orphans.
        let ids = store.consumePendingRecoveryIDs()
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let recording = store.recordings.first(where: { $0.id == id }) else { continue }
            print("MilaApp: re-enqueuing recovered recording \(recording.audioFileName)")
            transcription.enqueue(recording)
        }
    }

    /// Kick the engine's `loadIfNeeded` on the user's default model
    /// once at launch. The first time whisper.cpp loads a model with
    /// a sibling `-encoder.mlmodelc` on a given device, CoreML
    /// compiles the mlmodelc for that hardware — ~13s peg on M-series
    /// the very first time, then fully cached. Doing this at launch
    /// (rather than on the user's first Record press) means the
    /// preparation banner shows BEFORE the user reaches for the
    /// button, and any too-eager Record press during the window finds
    /// the model already loaded.
    private func prewarmDefaultModel() {
        transcription.prewarm(language: languageSettings.current.rawValue)
    }

    /// Pre-download the two default models on first launch:
    ///   - ivrit.ai large-v3 (Hebrew dictation, ~3 GB)
    ///   - OpenAI turbo (English dictation, ~1.6 GB)
    /// We start them in parallel — `ModelManager` queues them through the
    /// same `URLSession` so they don't actually saturate the network, and
    /// the in-app banner shows whichever is currently selected.
    private func ensureDefaultModelsInstalled() {
        modelManager.setSelected(WhisperModel.ivritLarge)
        for model in [WhisperModel.ivritLarge, WhisperModel.openaiTurbo] {
            if !modelManager.isInstalled(model) && modelManager.downloads[model.name] == nil {
                modelManager.download(model)
            }
        }
        // Pick up any sibling `-encoder.mlmodelc` that's missing for an
        // already-installed `.bin`. New users get the CoreML zip via the
        // post-`.bin`-install hook in ModelManager; this catches the
        // upgrade case (existing 1.7 users who already have the .bin on
        // disk from a previous run).
        modelManager.ensureCoreMLInstalled()
    }
}

/// Owns the graceful shutdown sequence.
///
/// The on-disk crash reports (IvritWhisper-2026-05-08-*.ips) all show the
/// same backtrace: `[NSApp terminate:]` -> `exit()` -> `__cxa_finalize_ranges`
/// -> `~vector<unique_ptr<ggml_metal_device>>` -> `ggml_metal_rsets_free`
/// -> `ggml_abort` (because the rsets-init dispatch block hadn't completed
/// yet). The fix is to release the `whisper_full` context and tear down the
/// recording / dictation / network stacks while we're still in a normal
/// runtime state, BEFORE letting `terminate:` call `exit()`.
@MainActor
final class MilaAppDelegate: NSObject, NSApplicationDelegate {
    weak var transcription: TranscriptionService?
    weak var session: RecordingSession?
    weak var dictation: DictationController?
    weak var modelManager: ModelManager?
    weak var actions: QuickActionsController?

    private var didShutDown = false
    private var screenLockObserversInstalled = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if didShutDown { return .terminateNow }
        didShutDown = true
        Task { @MainActor [weak self] in
            await self?.gracefulShutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Backstop: if `applicationShouldTerminate` was bypassed (e.g. a force
        // quit through the dock), we still get a chance to free the metal
        // context here. A second call is a no-op via `didShutDown`.
        if !didShutDown {
            didShutDown = true
            Task { @MainActor [weak self] in await self?.gracefulShutdown() }
        }
    }

    /// Subscribe to the events that affect a live recording:
    ///   1. `willSleepNotification` — system about to sleep (lid close on
    ///      battery, sleep menu, low-battery). We have ~1–2 s to flush
    ///      the WAV and tag the recording so the wake-up alert can show
    ///      duration + "stopped because the Mac slept".
    ///   2. `didWakeNotification` — system woke. Surfaces the alert.
    ///   3. `com.apple.screenIsLocked` (distributed center) — explicit
    ///      Lock Screen / hot corner. Stops the recording for privacy
    ///      (no in-flight buffering past a deliberately-secured screen)
    ///      but does NOT fire the sleep alert: this is a user action,
    ///      not an interruption.
    ///
    /// We deliberately stopped observing `screensDidSleepNotification`:
    /// it fires for the display sleep timer too, and now that we hold an
    /// IOPMAssertion while recording, the user expects the recording to
    /// keep running when they walk away from the keyboard.
    ///
    /// `SleepGuard` also holds a `PreventUserIdleDisplaySleep` assertion
    /// while recording, which suppresses the idle screensaver/auto-lock.
    /// So `com.apple.screenIsLocked` now only fires for the *deliberate*
    /// locks above — the automatic "lock after X minutes" that used to
    /// cut meeting captures short no longer reaches this observer.
    ///
    /// We stop recording rather than discard it: the user's working
    /// assumption is "the conversation is over, I want the bit I captured
    /// saved + transcribed", not "throw it away". Dictation IS discarded
    /// because there is no recipient app to paste into once the screen is
    /// locked.
    ///
    /// Idempotent — `wireDelegate()` fires every time SwiftUI re-runs
    /// `.onAppear`, and we MUST NOT register two observers for the same
    /// event.
    func startScreenLockObserversIfNeeded() {
        guard !screenLockObserversInstalled else { return }
        screenLockObserversInstalled = true

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self,
            selector: #selector(handleWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(handleDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // Screen-lock from Control Center / hot corner posts here. macOS
        // does NOT publish this via NSWorkspace — it's only on the
        // distributed center, under a string name. Without this observer,
        // recordings would only stop on lid close, not on "Lock Screen".
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScreenLock(_:)),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )

        // Kill the inconsistent toolbar separator (a thin hairline that
        // appears under the toolbar in the detail pane but not in the
        // sidebar, looks broken). NavigationSplitView re-applies the
        // toolbar configuration on every layout pass, so a single set
        // via NSViewRepresentable doesn't stick — we have to reapply
        // whenever a window becomes key.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stripToolbarSeparator(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        // Apply once now in case the main window is already key by the
        // time observers are installed.
        for window in NSApp.windows {
            applyChrome(to: window)
        }

        // Re-apply on every sidebar visibility flip so the freshly-
        // added NSVisualEffectView in the reopened sidebar gets its
        // blending mode pinned to .withinWindow before the user sees
        // the default .behindWindow material flash through.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSidebarVisibilityChange(_:)),
            name: .milaSidebarVisibilityDidChange,
            object: nil
        )
    }

    @objc private func handleSidebarVisibilityChange(_ notification: Notification) {
        // SwiftUI hasn't necessarily finished re-creating the AppKit
        // hierarchy by the time the visibility flip fires — defer to
        // the next runloop spin so our walk catches the new view.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for window in NSApp.windows {
                self.applyChrome(to: window)
            }
        }
    }

    @objc private func stripToolbarSeparator(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        applyChrome(to: window)
    }

    /// Apply Mila's window chrome tweaks to a single NSWindow. Strips
    /// the hairline separator that renders below the toolbar in the
    /// detail pane but stops at the sidebar splitter — looks like a
    /// broken half-divider.
    ///
    /// Both `titlebarSeparatorStyle` (the modern, macOS 11+ property)
    /// and the deprecated `NSToolbar.showsBaselineSeparator` are zeroed
    /// out because they govern different layers — depending on the
    /// macOS version + SwiftUI version, either or both can produce the
    /// line. Setting both is harmless and covers everything.
    private func applyChrome(to window: NSWindow) {
        if let id = window.identifier?.rawValue,
           id.contains("settings") || id.contains("alert") {
            return
        }
        // Belt and suspenders: queue the property change behind any
        // SwiftUI layout passes that might be re-applying the default
        // separator style.
        DispatchQueue.main.async {
            window.titlebarSeparatorStyle = .none
            window.toolbar?.showsBaselineSeparator = false
            // (Tried `setAutorecalculatesContentBorderThickness` here
            // too — it only works on the deprecated "textured" window
            // style and throws NSInvalidArgumentException on regular
            // windows. Don't add it back.)

            // Freeze the sidebar's vibrant material so it stops
            // shifting color when the user drags the window across
            // other apps. Cross-app color sampling is what
            // NSVisualEffectView with `.behindWindow` blending mode
            // does — switching the sidebar's effect views to
            // `.withinWindow` makes them sample only Mila's own
            // content, which is uniform, so the card stays a stable
            // gray. The card's shape (rounded corners, floating
            // inset) is untouched.
            if let contentView = window.contentView {
                self.freezeSidebarMaterials(in: contentView)
            }
        }
    }

    /// Locate the NSSplitView under `view` and switch every
    /// NSVisualEffectView in its sidebar pane to `.withinWindow`
    /// blending. Restricting the walk to the sidebar pane (the first
    /// arranged subview of the split view) is what makes this safe to
    /// run repeatedly — we don't touch the detail pane's chrome.
    private func freezeSidebarMaterials(in view: NSView) {
        if let split = view as? NSSplitView,
           let sidebar = split.arrangedSubviews.first {
            applyWithinWindowBlending(to: sidebar)
            return
        }
        for sub in view.subviews {
            freezeSidebarMaterials(in: sub)
        }
    }

    private func applyWithinWindowBlending(to view: NSView) {
        if let effect = view as? NSVisualEffectView {
            // `.withinWindow` blends with content layered behind this
            // view inside the same window, not whatever's behind the
            // window itself. The visual on top of the material — text,
            // icons, selection highlights — is unaffected.
            effect.blendingMode = .withinWindow
        }
        for sub in view.subviews {
            applyWithinWindowBlending(to: sub)
        }
    }

    /// System is about to sleep (lid close on battery, low battery, sleep
    /// menu). We race the system sleep timer to flush the WAV — the
    /// `stopBecauseOfSleep` path stashes the metadata so the wake-up
    /// alert can show duration + "stopped by sleep".
    @objc private func handleWillSleep(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let actions = self.actions, actions.isRecording {
                print("Sleep guard: stopping recording before system sleeps")
                await actions.stopBecauseOfSleep()
            }
            if let dictation = self.dictation, case .recording = dictation.state {
                print("Sleep guard: cancelling dictation before system sleeps")
                await dictation.cancelInFlight()
            }
        }
    }

    /// System woke. Nudge the controller so its `sleepInterruption`
    /// publish-flag re-triggers any SwiftUI subscribers that were
    /// suspended over the sleep window.
    @objc private func handleDidWake(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.actions?.notifyDidWake()
        }
    }

    @objc private func handleScreenLock(_ notification: Notification) {
        Task { @MainActor [weak self] in await self?.pauseForScreenLock(reason: "screen locked") }
    }

    /// Stop whatever the user was doing because they're no longer at the
    /// machine. Active recording finalizes and goes to transcription as if
    /// the user had hit Stop. Active dictation is dropped (a synthesized
    /// ⌘V into a locked screen is at best useless, at worst leaks the
    /// transcript onto the lock-screen password field).
    ///
    /// This only runs for *deliberate* locks: while recording, `SleepGuard`
    /// holds a display-sleep assertion that prevents the idle auto-lock from
    /// firing, so reaching here means the user explicitly locked the screen.
    private func pauseForScreenLock(reason: String) async {
        guard let actions else { return }
        if actions.isRecording {
            print("Screen-lock guard: stopping active recording (\(reason))")
            await actions.stopRecording()
        }
        if let dictation, case .recording = dictation.state {
            print("Screen-lock guard: cancelling active dictation (\(reason))")
            await dictation.cancelInFlight()
        }
    }

    private func gracefulShutdown() async {
        // Stop any active recording / dictation cleanly so AVAudioEngine and
        // SCStream release the user's mic / screen-recording grant.
        await session?.cancelAll()
        await dictation?.cancelInFlight()
        // Tear down the URLSession <-> ModelManager retain cycle and cancel
        // in-flight downloads.
        modelManager?.shutdown()
        // Free whisper.cpp context (and via it, the ggml-metal devices) BEFORE
        // libc++ static destructors run. See class doc for the why.
        await transcription?.shutdown()
        // Yield so pending dispatch blocks queued by ggml-metal
        // (rsets-init, etc.) have a chance to drain before libc++
        // static destructors run. 50ms was enough for the
        // chunk-based path; with VAD's higher transcribe frequency
        // we observed SIGABRT in ggml_metal_rsets_free at exit on
        // macOS 26 — bumping to 500ms gives the init blocks more
        // breathing room. Cost: quit takes ~half a second longer.
        try? await Task.sleep(nanoseconds: 500_000_000)
        HotkeyManager.shared.shutdown()
    }
}
