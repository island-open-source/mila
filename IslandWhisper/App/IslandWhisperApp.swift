import SwiftUI
import AppKit

@main
struct IslandWhisperApp: App {
    @NSApplicationDelegateAdaptor(IslandWhisperAppDelegate.self) private var appDelegate

    @StateObject private var store: RecordingStore
    @StateObject private var modelManager: ModelManager
    @StateObject private var transcription: TranscriptionService
    @StateObject private var dictation: DictationController
    @StateObject private var actions: QuickActionsController
    @StateObject private var session: RecordingSession
    @StateObject private var hotkeySettings: HotkeySettings
    @StateObject private var languageSettings: RecordingLanguageSettings

    init() {
        let store = RecordingStore()
        let mgr = ModelManager(modelsDirectory: store.modelsDirectory)
        let svc = TranscriptionService(store: store, modelManager: mgr)
        let session = RecordingSession()
        let langSettings = RecordingLanguageSettings()
        let actions = QuickActionsController(session: session,
                                             store: store,
                                             transcription: svc,
                                             languageSettings: langSettings)
        let hotkeys = HotkeySettings()
        _store = StateObject(wrappedValue: store)
        _modelManager = StateObject(wrappedValue: mgr)
        _transcription = StateObject(wrappedValue: svc)
        _session = StateObject(wrappedValue: session)
        _actions = StateObject(wrappedValue: actions)
        _hotkeySettings = StateObject(wrappedValue: hotkeys)
        _languageSettings = StateObject(wrappedValue: langSettings)
        _dictation = StateObject(wrappedValue: DictationController(store: store,
                                                                    transcription: svc,
                                                                    hotkeySettings: hotkeys))
    }

    var body: some Scene {
        WindowGroup("Island Whisper") {
            ContentView()
                .environmentObject(store)
                .environmentObject(modelManager)
                .environmentObject(transcription)
                .environmentObject(dictation)
                .environmentObject(actions)
                .environmentObject(session)
                .environmentObject(hotkeySettings)
                .environmentObject(languageSettings)
                .frame(minWidth: 1000, minHeight: 640)
                .task { ensureDefaultModelsInstalled() }
                .onAppear { wireDelegate() }
        }
        .commands {
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
        }

        Settings {
            SettingsView()
                .environmentObject(modelManager)
                .environmentObject(hotkeySettings)
                .environmentObject(transcription)
        }
    }

    private func wireDelegate() {
        appDelegate.transcription = transcription
        appDelegate.session = session
        appDelegate.dictation = dictation
        appDelegate.modelManager = modelManager
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
final class IslandWhisperAppDelegate: NSObject, NSApplicationDelegate {
    weak var transcription: TranscriptionService?
    weak var session: RecordingSession?
    weak var dictation: DictationController?
    weak var modelManager: ModelManager?

    private var didShutDown = false

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
