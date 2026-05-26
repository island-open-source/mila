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
    @StateObject private var updater = UpdaterViewModel()

    init() {
        let store = RecordingStore()
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
        let liveAI = LiveAISettings()
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
        // Late-bind the live-AI dependencies onto `actions` so it can
        // attach summary/items to the saved Recording and skip the
        // rename sheet when Live AI was running.
        actions.llmSettings = llm
        actions.liveAISettings = liveAI
        actions.liveAISession = liveSession
        let meetingSettings = MeetingDetectionSettings()
        let detector = MeetingDetector()
        let promptCoordinator = MeetingPromptCoordinator(
            detector: detector,
            settings: meetingSettings,
            actions: actions
        )
        _store = StateObject(wrappedValue: store)
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
        _dictation = StateObject(wrappedValue: DictationController(store: store,
                                                                    transcription: svc,
                                                                    hotkeySettings: hotkeys,
                                                                    liveTranscriber: dictationTrans))
    }

    var body: some Scene {
        WindowGroup("Mila") {
            ContentView()
                .environmentObject(store)
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
                .task { await diarizationSettings.runHealthCheck() }
                .task { await diarizationSettings.runStartupCheckDepsIfNeeded() }
                .task { await diarizationSettings.startAutoBootstrapIfNeeded() }
                .onAppear { wireDelegate() }
                .task { maybeRelocateBundle() }
                .task { enqueueRecoveredRecordings() }
                .task { startMeetingDetectionIfNeeded() }
                .task { await wireLiveAIPipeline() }
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

        var feedTask: Task<Void, Never>?
        var aiEnabledCancellable: AnyCancellable?

        for await state in sessionRef.$state.values {
            switch state {
            case .recording:
                // Live transcription runs on every recording — it's how
                // the recording UI shows the live transcript pane even
                // when AI mode is off. Apply the user's tick-interval
                // setting before start() so the running loop picks it
                // up (default 5s, settable in Settings → Live AI).
                transcriber.chunkSeconds = aiSettings.chunkSeconds
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
                        if aiActive, let diarizer {
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
                // flushes the mixer's pendingMic/pendingSystem tail
                // during `.stopping`, calling write() one or two more
                // times. We need `onLiveSamples` and the transcriber
                // to remain live so the last chunk lands in the live
                // pane and produces a final Live AI update. Cleanup
                // happens when state lands at `.idle`.
                break
            case .idle:
                feedTask?.cancel()
                feedTask = nil
                aiEnabledCancellable?.cancel()
                aiEnabledCancellable = nil
                // Force one last whisper pass on whatever's in the
                // buffer so the tail of the meeting (up to ~chunkSeconds
                // since the previous tick) makes it into the live pane
                // and the saved Live AI snapshot. The tick task's
                // sleep loop would otherwise let this audio sit
                // un-transcribed.
                await transcriber.transcribeNow()
                // Same idea for the LLM: if new segments just landed
                // and Live AI is on, push one final feed so the
                // recording's stored summary/items reflect the tail.
                if aiSettings.enabled && llmSettingsRef.isConfigured {
                    let text = transcriber.formattedTranscript
                    if !text.isEmpty {
                        aiSession.feed(transcript: text)
                    }
                }
                _ = transcriber.stop()
                diarizer.stop()
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
    ///      (the app died while whisper was mid-transcription) is
    ///      reset to `.failed`. Without this, the Queue view's
    ///      "still-pending fallback" keeps showing those rows forever
    ///      because the worker never publishes them.
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
        for recording in store.recordings where recording.status == .running {
            var fixed = recording
            fixed.status = .failed
            store.update(fixed)
            print("MilaApp: reset stale .running recording \(recording.audioFileName) to .failed")
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
        // Yield once so any pending dispatch blocks queued by ggml-metal
        // during the warmup pass have a chance to drain. 50ms is empirically
        // enough on Apple Silicon.
        try? await Task.sleep(nanoseconds: 50_000_000)
        HotkeyManager.shared.shutdown()
    }
}
