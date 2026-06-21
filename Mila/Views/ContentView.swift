import SwiftUI
import ScreenCaptureKit

struct ContentView: View {
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var transcription: TranscriptionService
    @EnvironmentObject private var actions: QuickActionsController
    @EnvironmentObject private var session: RecordingSession
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var languageSettings: RecordingLanguageSettings
    @EnvironmentObject private var postRecording: PostRecordingCoordinator
    @EnvironmentObject private var llmSettings: LLMSettings
    @EnvironmentObject private var liveAISettings: LiveAISettings
    @EnvironmentObject private var updater: UpdaterViewModel

    @State private var selection: SidebarSelection? = .home
    @State private var search: String = ""
    /// Tracked so we can ping the AppKit chrome hack whenever the user
    /// toggles the sidebar. Without this, the sidebar's
    /// NSVisualEffectView is freshly added with default `.behindWindow`
    /// blending and our "freeze to .withinWindow" hack — which only
    /// runs on `didBecomeKeyNotification` — doesn't fire, producing
    /// the brief flicker the user sees on sidebar reopen.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            ZStack(alignment: .top) {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let progress = activeDownloadProgress() {
                    ModelDownloadBanner(progress: progress)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // The floating RecordingChip used to be the only "you
                // are recording" indicator. With the new always-on live
                // recording view (which has its own header strip + a
                // running timer in the corner), the chip would just
                // double up the timer in the top-right corner AND hide
                // part of the toolbar pickers underneath. Show the
                // chip only when the user navigated away from the
                // recording view (sidebar selection ≠ home).
                if actions.isRecording, (selection ?? .home) != .home {
                    HStack {
                        Spacer()
                        RecordingChip()
                            .padding(.top, 12)
                            .padding(.trailing, 16)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    InputDevicePickerToolbarItem()
                }
                // The language picker affects which whisper model the
                // NEXT transcription uses. Changing it mid-recording
                // doesn't switch models live and silently confuses
                // users who think they can flip languages on the fly.
                // Hide it during a recording — the input device
                // picker stays because swapping mics mid-call is a
                // legitimate operation.
                if !actions.isRecording {
                    ToolbarItem(placement: .primaryAction) {
                        LanguagePickerToolbarItem()
                    }
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .alert(
            "Transcription error",
            isPresented: Binding(
                get: { transcription.lastError != nil },
                set: { if !$0 { transcription.lastError = nil } }
            ),
            actions: { Button("OK") { transcription.lastError = nil } },
            message: { Text(transcription.lastError ?? "") }
        )
        .alert(
            "Recording stopped because your Mac slept",
            isPresented: Binding(
                get: { actions.sleepInterruption != nil },
                set: { if !$0 { actions.sleepInterruption = nil } }
            ),
            actions: {
                if let info = actions.sleepInterruption {
                    Button("Open recording") {
                        selection = .recording(info.recordingID)
                        actions.sleepInterruption = nil
                    }
                }
                Button("OK", role: .cancel) {
                    actions.sleepInterruption = nil
                }
            },
            message: {
                if let info = actions.sleepInterruption {
                    Text(sleepInterruptionMessage(info))
                } else {
                    Text("")
                }
            }
        )
        .alert(
            "Microphone isn't picking up sound",
            // Live AI mode renders a live transcript pane — if no text is
            // appearing, the user can see that directly, so the modal
            // "no sound" alert becomes redundant noise on top of an
            // already-busy screen. Suppress it whenever the split-pane
            // recording view is showing.
            isPresented: Binding(
                get: { actions.noSoundWarningShown && !isInLiveAIRecording },
                set: { if !$0 { actions.noSoundWarningShown = false } }
            ),
            actions: {
                Button("Keep recording") {
                    actions.noSoundWarningShown = false
                }
                Button("Stop") {
                    actions.noSoundWarningShown = false
                    Task { await actions.stopRecording() }
                }
            },
            message: {
                Text("Mila hasn't heard any audio in the last 10 seconds. This is fine if you're recording a quiet section — otherwise check the input device in the toolbar or in Settings → Audio.")
            }
        )
        .alert(
            "Microphone access needed",
            isPresented: $actions.microphonePermissionMissing,
            actions: {
                Button("Open Privacy Settings") {
                    actions.openMicrophoneSettings()
                    actions.microphonePermissionMissing = false
                }
                Button("Cancel", role: .cancel) {
                    actions.microphonePermissionMissing = false
                }
            },
            message: {
                Text("Mila needs microphone access to record audio. In System Settings → Privacy & Security → Microphone, turn Mila on. If you don't see Mila listed, this is likely because the app was previously named IslandWhisper — quit and relaunch Mila after toggling the switch.")
            }
        )
        .alert(
            "Screen & System Audio Recording permission needed",
            isPresented: $actions.screenRecordingPermissionMissing,
            actions: {
                Button("Open Privacy Settings") {
                    actions.openScreenRecordingSettings()
                    actions.screenRecordingPermissionMissing = false
                }
                Button("Cancel", role: .cancel) {
                    actions.screenRecordingPermissionMissing = false
                }
            },
            message: {
                Text("macOS hasn't granted Mila access to system audio. In System Settings → Privacy & Security → Screen & System Audio Recording, remove any existing Mila entry, then check the box for this build. (Stale entries from previous builds can look granted but are no longer valid.)")
            }
        )
        .sheet(isPresented: $actions.isAppPickerShown) {
            AppPickerSheet()
        }
        .sheet(item: Binding(
            get: { postRecording.pending },
            set: { newValue in if newValue == nil { postRecording.pending = nil } }
        )) { recording in
            RenameRecordingSheet(initialRecording: recording)
        }
        // Pre-update enticement: when Sparkle's scheduled poll finds a newer
        // version, show the custom "What's New" popup instead of Sparkle's
        // stock window (the standard window still runs for an explicit
        // "Check for Updates…"). "Update Now" hands back to Sparkle's install
        // flow; "Later" / dismiss records the version as seen.
        .sheet(item: Binding(
            get: { updater.availableUpdate },
            set: { newValue in if newValue == nil { updater.dismissUpdate() } }
        )) { update in
            WhatsNewPopup(
                update: update,
                onUpdateNow: { updater.proceedWithUpdate() },
                onLater: { updater.dismissUpdate() }
            )
        }
        .overlay(alignment: .bottom) {
            if let msg = postRecording.activityStatus {
                LLMActivityBanner(message: msg, isError: postRecording.activityIsError)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(msg)
            }
        }
        .animation(.easeOut(duration: 0.2), value: postRecording.activityStatus)
        .onChange(of: columnVisibility) { _, _ in
            // Sidebar visibility changed — ping the AppDelegate so it
            // re-applies the withinWindow blending on the (possibly
            // freshly-recreated) NSVisualEffectViews inside the
            // sidebar pane. Without this, opening the sidebar shows
            // a frame or two of the default `behindWindow` material
            // before our chrome hack catches up, which reads as a
            // flicker.
            NotificationCenter.default.post(name: .milaSidebarVisibilityDidChange, object: nil)
        }
    }

    /// True iff the detail pane is currently rendering `LiveAIRecordingView`
    /// — used to suppress alerts/banners that don't make sense when the
    /// live transcript + action-items pane is doing its own UI.
    private var isInLiveAIRecording: Bool {
        (selection ?? .home) == .home
            && actions.isRecording
            && liveAISettings.enabled
            && llmSettings.isConfigured
            && liveAISettings.isLiveAIAvailable
    }

    /// Whether the home pane should swap to `LiveAIRecordingView`.
    /// The UI-test bypass for the hardware gate lives centrally in
    /// `MilaApp.init()` (it injects a non-Air `SystemCapabilities`
    /// into `LiveAISettings`), so checking `isLiveAIAvailable` here
    /// works in both production and UI-test launches. The
    /// `--ui-test-rtl-live-hebrew` route additionally forces the
    /// view even when no recording is in progress so the layout
    /// regression test can assert without driving real audio.
    private var shouldShowLiveAIRecordingView: Bool {
        let uiTestForcesLiveView =
            CommandLine.arguments.contains("--ui-test-rtl-live-hebrew")
        if uiTestForcesLiveView { return true }
        // Background mode keeps the user on HomeView during recording.
        // Transcription, diarizer, and Live AI session still run —
        // they're not tied to the LiveAIRecordingView's lifecycle —
        // so the saved Recording ends up identical. For lower-power
        // Macs (MacBook Air) where the live pane competes with
        // whisper for CPU, this trades off live visibility for
        // throughput.
        if liveAISettings.backgroundMode { return false }
        return actions.isRecording && liveAISettings.isLiveAIAvailable
    }

    /// Compose the wake-up alert body. Always shows the captured length so
    /// the user knows roughly how much audio is now waiting to transcribe.
    /// On battery, adds a one-line "macOS does this on battery" hint —
    /// the recording stopped because the OS forced sleep on lid close,
    /// which apps can't override.
    private func sleepInterruptionMessage(_ info: QuickActionsController.SleepInterruption) -> String {
        let length = formatRecordingLength(info.durationSeconds)
        var lines = ["Mila captured \(length) before your Mac went to sleep — the audio is saved and queued for transcription."]
        if info.wasOnBattery {
            lines.append("On battery, closing the lid forces sleep. macOS doesn't let apps override this; plug into power to keep recording with the lid closed.")
        }
        return lines.joined(separator: "\n\n")
    }

    private func formatRecordingLength(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60, s = total % 60
        if m == 0 { return "\(s)s" }
        return "\(m)m \(s)s"
    }

    private func activeDownloadProgress() -> Double? {
        guard let model = modelManager.selectedModel(),
              let value = modelManager.downloads[model.name] else { return nil }
        return value
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection ?? .home {
        case .home:
            if shouldShowLiveAIRecordingView {
                // Live transcription is always on during a recording —
                // the AI summarization layer (action items / final
                // summary) only activates when Live AI is enabled +
                // a CLI is configured. The view itself handles the
                // gating; we just route here based on "are we recording".
                //
                // The UI-test flags bypass both the recording AND
                // hardware gates so the live-transcript regression
                // tests can run on any CI machine regardless of how
                // its `hw.model` is reported.
                LiveAIRecordingView()
            } else {
                HomeView(selection: $selection, search: search)
            }
        case .queue:
            QueueView(selection: $selection)
        case .more:
            MoreView()
        case .category(let cat):
            HistoryListView(category: cat, search: search, selection: $selection)
        case .defaultFolder:
            DefaultFolderListView(search: search, selection: $selection)
        case .folder(let name):
            FolderListView(folderName: name, search: search, selection: $selection)
        case .recording(let id):
            if let rec = store.recordings.first(where: { $0.id == id }) {
                // .id(rec.id) forces SwiftUI to discard and rebuild the view
                // when the user navigates between recordings. Without it,
                // @State like isEditingTitle / titleDraft survives, and the
                // focus-loss commit on the next view would rename the new
                // recording with the previous one's draft.
                RecordingDetailView(recording: rec)
                    .id(rec.id)
                    .onAppear {
                        print("ContentView.detail: showing recording \(rec.id.uuidString.prefix(8)) status=\(rec.status) segs=\(rec.segments.count) summary=\(rec.summary?.isEmpty == false) items=\(rec.actionItems?.count ?? 0)")
                    }
            } else {
                ContentUnavailableView(
                    "Recording not found",
                    systemImage: "questionmark.folder",
                    description: Text("The recording may have been deleted.")
                )
            }
        }
    }
}

private struct ModelDownloadBanner: View {
    let progress: Double
    @EnvironmentObject private var modelManager: ModelManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading \(modelManager.selectedModel()?.displayName ?? "model")…")
                    .font(.callout.weight(.semibold))
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 280)
            }
            Text("\(Int(progress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

/// Compact toolbar dropdown that pins the input device used for the next
/// recording / dictation. Mirrors the Settings → Audio "Input source"
/// picker but lives next to the language picker so the user can swap to
/// a different mic without opening Settings. Label is just the mic icon
/// (plus the active device name when there's room) so the toolbar stays
/// narrow.
private struct InputDevicePickerToolbarItem: View {
    @EnvironmentObject private var settings: AudioInputSettings
    @State private var devices: [AudioDeviceManager.Device] = []

    /// Sentinel UID for "follow the system default".
    private static let autoTag = "__auto__"

    var body: some View {
        Menu {
            Picker("Input", selection: binding) {
                Text("Automatic (system default)").tag(Self.autoTag)
                ForEach(devices, id: \.uid) { device in
                    Text(label(for: device)).tag(device.uid)
                }
                if let pinned = settings.preferredUID,
                   devices.first(where: { $0.uid == pinned }) == nil {
                    Text("Saved device (unplugged)").tag(pinned)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Refresh device list") { refresh() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic")
                    .font(.system(size: 14, weight: .medium))
                Text(displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            // Breathing room so the icon/label aren't flush against the
            // borderless menu's rounded capsule edges.
            .padding(.horizontal, 8)
        }
        .menuStyle(.borderlessButton)
        .help("Microphone used for new recordings and dictation")
        .onAppear(perform: refresh)
    }

    private var binding: Binding<String> {
        Binding(
            get: { settings.preferredUID ?? Self.autoTag },
            set: { settings.preferredUID = ($0 == Self.autoTag) ? nil : $0 }
        )
    }

    /// Short label shown in the closed menu. Picks the pinned device's
    /// name if there is one, else "Auto" so users always see *something*
    /// (an empty-looking toolbar item is easy to miss).
    private var displayName: String {
        guard let uid = settings.preferredUID,
              let device = devices.first(where: { $0.uid == uid }) else {
            return "Auto"
        }
        return device.name
    }

    private func label(for device: AudioDeviceManager.Device) -> String {
        var parts: [String] = [device.name]
        if device.isBuiltIn { parts.append("built-in") }
        if device.isVirtual { parts.append("virtual") }
        return parts.joined(separator: " — ")
    }

    private func refresh() {
        devices = AudioDeviceManager.inputDevices()
    }
}

/// Toolbar dropdown that picks the language used for the next voice memo /
/// app-audio recording. Shows the flag of the active language as the menu
/// label so it stays scannable even when the toolbar is narrow.
private struct LanguagePickerToolbarItem: View {
    @EnvironmentObject private var languageSettings: RecordingLanguageSettings

    var body: some View {
        Menu {
            Picker("Recording language", selection: $languageSettings.current) {
                ForEach(RecordingLanguage.allCases) { lang in
                    Text("\(lang.flagEmoji)  \(lang.displayName)")
                        .tag(lang)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(languageSettings.current.flagEmoji)
                    .font(.system(size: 16))
                Text(languageSettings.current.displayName)
                    .font(.callout.weight(.medium))
            }
            // Breathing room so the flag/label aren't flush against the
            // borderless menu's rounded capsule edges (matches the input
            // device picker next to it).
            .padding(.horizontal, 8)
        }
        .menuStyle(.borderlessButton)
        .help("Language used for new voice memos and app-audio recordings")
    }
}

private struct RecordingChip: View {
    @EnvironmentObject private var actions: QuickActionsController
    @EnvironmentObject private var session: RecordingSession

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Text(formatDuration(session.elapsed))
                .font(.callout.monospacedDigit())
            Button {
                Task { await actions.stopRecording() }
            } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Stop recording")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.red.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
    }
}

private struct QueueView: View {
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var transcription: TranscriptionService
    @Binding var selection: SidebarSelection?

    /// Active job first (if any), then queued items in FIFO order, then any
    /// other pending recordings (e.g. queued before app launch).
    private var queue: [Recording] {
        var seen = Set<UUID>()
        var ordered: [Recording] = []
        if let activeID = transcription.activeRecordingID,
           let active = store.recordings.first(where: { $0.id == activeID }) {
            ordered.append(active)
            seen.insert(activeID)
        }
        for id in transcription.pendingIDs {
            if !seen.contains(id),
               let rec = store.recordings.first(where: { $0.id == id }) {
                ordered.append(rec)
                seen.insert(id)
            }
        }
        for rec in store.recordings where !rec.isTrashed
            && (rec.status == .running || rec.status == .pending)
            && !seen.contains(rec.id) {
            ordered.append(rec)
        }
        return ordered
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Queue")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                if queue.isEmpty {
                    HStack {
                        Spacer()
                        ContentUnavailableView(
                            "Queue is empty",
                            systemImage: "list.bullet.rectangle",
                            description: Text("Active and pending transcriptions will show up here.")
                        )
                        Spacer()
                    }
                    .padding(.top, 60)
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(queue.enumerated()), id: \.element.id) { index, rec in
                            QueueRow(recording: rec, position: index)
                                .contentShape(Rectangle())
                                .onTapGesture { selection = .recording(rec.id) }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
    }
}

private struct QueueRow: View {
    let recording: Recording
    /// 0 = currently transcribing, 1+ = number of jobs ahead in the queue
    let position: Int
    @EnvironmentObject private var transcription: TranscriptionService

    private var isActive: Bool {
        transcription.activeRecordingID == recording.id
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RecordingSourceBadge(recording: recording, size: 22)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(recording.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(statusLabel)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(statusColor)
                }

                if isActive {
                    ProgressView(value: transcription.progress)
                        .progressViewStyle(.linear)
                } else {
                    HStack(spacing: 6) {
                        ProgressView(value: 0)
                            .progressViewStyle(.linear)
                            .opacity(0.4)
                        if position > 0 {
                            Text("#\(position) in line")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusLabel: String {
        if isActive { return "Transcribing" }
        switch recording.status {
        case .running: return "Transcribing"
        case .pending: return position == 0 ? "Starting…" : "Queued"
        case .completed: return "Done"
        case .failed: return "Failed"
        }
    }

    private var statusColor: Color {
        if isActive { return .blue }
        switch recording.status {
        case .running: return .blue
        case .pending: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}

private struct AppPickerSheet: View {
    @EnvironmentObject private var actions: QuickActionsController

    @State private var pickedAppID: pid_t? = nil
    @State private var includeMic: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Record app audio")
                .font(.title3.weight(.semibold))
            Text("Pick an app to capture, or record everything playing on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("App", selection: $pickedAppID) {
                Text("Entire system").tag(pid_t?(nil))
                ForEach(actions.availableApps, id: \.processID) { app in
                    Text(app.applicationName).tag(pid_t?(app.processID))
                }
            }
            .pickerStyle(.menu)

            Toggle("Also record microphone", isOn: $includeMic)

            HStack {
                Spacer()
                Button("Cancel") {
                    actions.isAppPickerShown = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Start recording") {
                    let app = actions.availableApps.first { $0.processID == pickedAppID }
                    Task { await actions.startAppRecording(app: app, includeMic: includeMic) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Transient toast for background LLM activity ("Sending to Claude…",
/// "Claude failed: …"). Lives in `ContentView` so it can sit over whatever
/// the user navigated to while the action was running.
private struct LLMActivityBanner: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isError ? Color.red : Color.accentColor)
            Text(message)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}
