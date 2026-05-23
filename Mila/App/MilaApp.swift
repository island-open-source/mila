import SwiftUI
import AppKit
import Combine
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
    @StateObject private var updater = UpdaterViewModel()

    init() {
        let store = RecordingStore()
        let mgr = ModelManager(modelsDirectory: store.modelsDirectory)
        let diarSettings = DiarizationSettings()
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
        _dictation = StateObject(wrappedValue: DictationController(store: store,
                                                                    transcription: svc,
                                                                    hotkeySettings: hotkeys))
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
                .frame(minWidth: 1000, minHeight: 640)
                .task { ensureDefaultModelsInstalled() }
                .task { await diarizationSettings.runHealthCheck() }
                .onAppear { wireDelegate() }
                .task { maybeRelocateBundle() }
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

    /// Subscribe to the two events that mean "the user just left the
    /// machine": lid close / display sleep (`NSWorkspace.screensDidSleep`)
    /// and explicit screen lock from Control Center / hot corner
    /// (`com.apple.screenIsLocked`, posted on the distributed center).
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
            selector: #selector(handleScreenSleep(_:)),
            name: NSWorkspace.screensDidSleepNotification,
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
            //
            // Also tried walking the contentView hierarchy and zeroing
            // cornerRadius on any layer-backed view to revert macOS
            // Tahoe's "floating sidebar card" look (rounded all four
            // corners, margin around the sidebar) to the classic
            // flush-with-window-edges sidebar. The walk was way too
            // broad — it also zeroed the search field, button shapes,
            // and the window's own corner mask, breaking the entire
            // layout. Reverting until we find a targeted enough way to
            // identify ONLY the sidebar's background container.
        }
    }

    @objc private func handleScreenSleep(_ notification: Notification) {
        Task { @MainActor [weak self] in await self?.pauseForScreenLock(reason: "screen sleep") }
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
