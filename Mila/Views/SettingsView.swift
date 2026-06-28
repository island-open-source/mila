import SwiftUI
import AppKit
import Carbon.HIToolbox

enum SettingsTab: Int, Hashable {
    case hotkeys, audio, models, llm, speakers, meetings, liveAI, storage
}

@Observable
final class SettingsNavigation {
    @MainActor static let shared = SettingsNavigation()
    var pendingTab: SettingsTab?
}

/// Standard `Settings` scene. Opened via `Cmd+,` from the menu bar.
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .hotkeys

    var body: some View {
        TabView(selection: $selectedTab) {
            HotkeysSettingsTab()
                .tabItem { Label("Hotkeys", systemImage: "command") }
                .tag(SettingsTab.hotkeys)
            AudioSettingsTab()
                .tabItem { Label("Audio", systemImage: "mic") }
                .tag(SettingsTab.audio)
            ModelsSettingsTab()
                .tabItem { Label("Models", systemImage: "cube.box") }
                .tag(SettingsTab.models)
            LLMSettingsTab()
                .tabItem { Label("LLM", systemImage: "sparkles") }
                .tag(SettingsTab.llm)
            DiarizationSettingsTab()
                .tabItem { Label("Speakers", systemImage: "person.2") }
                .tag(SettingsTab.speakers)
            MeetingsSettingsTab()
                .tabItem { Label("Meetings", systemImage: "video.fill") }
                .tag(SettingsTab.meetings)
            LiveAISettingsTab()
                .tabItem { Label("Live AI", systemImage: "sparkles.tv") }
                .tag(SettingsTab.liveAI)
            StorageSettingsTab()
                .tabItem { Label("Storage", systemImage: "externaldrive") }
                .tag(SettingsTab.storage)
        }
        .frame(width: 560, height: 560)
        .padding(20)
        .onChange(of: SettingsNavigation.shared.pendingTab, initial: true) { _, newTab in
            if let tab = newTab {
                selectedTab = tab
                SettingsNavigation.shared.pendingTab = nil
            }
        }
    }
}

// MARK: - Audio

private struct AudioSettingsTab: View {
    @EnvironmentObject private var settings: AudioInputSettings
    @EnvironmentObject private var monitor: InputLevelMonitor
    @EnvironmentObject private var actions: QuickActionsController
    @State private var devices: [AudioDeviceManager.Device] = []

    /// Sentinel UID that means "follow the system default input". Picker's
    /// SwiftUI tag has to be `String`, so we can't use Optional<String> as a
    /// tag value directly here without all the rawValue plumbing.
    private static let autoTag = "__auto__"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Input source")
                .font(.title3.weight(.semibold))
            Text("Choose which microphone Mila reads from. Leave on Automatic to follow whatever macOS uses as its system default. Pin to a specific device if your default is a virtual mic (Krisp, BlackHole, Zoom Audio, etc.) and you'd rather record from the raw hardware.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Input", selection: binding) {
                Text("Automatic (system default)")
                    .tag(Self.autoTag)
                ForEach(devices, id: \.uid) { device in
                    Text(label(for: device))
                        .tag(device.uid)
                }
                if let pinned = settings.preferredUID,
                   devices.first(where: { $0.uid == pinned }) == nil {
                    Text("Saved device (unplugged) — \(pinned)")
                        .tag(pinned)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 360)

            Button("Refresh device list") { refresh() }
                .buttonStyle(.borderless)

            Divider().padding(.vertical, 4)

            // Live VU meter for the currently-selected input. Lets users
            // confirm the chosen device is actually hearing them before
            // they record — the most common "why is my transcript empty"
            // failure mode comes from picking the wrong (or muted) input.
            // Paused during active recording so we don't fight the real
            // MicrophoneRecorder for the device.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.tint)
                    Text("Input level")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(meterStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LevelMeterView(level: monitor.level,
                               isLive: monitor.isRunning && !actions.isRecording)
                    .frame(maxWidth: 360)
            }

            Divider().padding(.vertical, 4)

            // Adaptive digital gain. Default ON — most users with a built-in
            // MacBook mic have their system input volume well below
            // unity, which puts speech below the live VAD cutoff (0.012)
            // and starves the live transcript pane. The gain controller
            // boosts low-volume capture to a target observed RMS uniformly
            // across the saved WAV and the live feed.
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Automatic mic gain adjustment",
                       isOn: $settings.adaptiveGainEnabled)
                    .toggleStyle(.switch)
                Text("Boosts low-volume microphone input automatically when speech is captured. Disable if you prefer manual control of input levels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: refresh)
        .task {
            // Bring up (or refresh) the monitor when the user opens this tab.
            // Settings is a separate window so we can't rely on Home's
            // lifecycle — each window manages its own start/stop.
            await refreshMonitor()
        }
        .onDisappear {
            Task { await monitor.stop() }
        }
        .onChange(of: settings.preferredUID) { _, newValue in
            monitor.preferredUID = newValue
            Task { await monitor.restart() }
        }
        .onChange(of: actions.isRecording) { _, _ in
            Task { await refreshMonitor() }
        }
    }

    private func refreshMonitor() async {
        if actions.isRecording {
            await monitor.stop()
        } else {
            await monitor.start()
        }
    }

    private var meterStatusText: String {
        if actions.isRecording {
            return "Paused — recording in progress"
        }
        return monitor.isRunning ? "Live" : "Starting…"
    }

    private var binding: Binding<String> {
        Binding(
            get: { settings.preferredUID ?? Self.autoTag },
            set: { settings.preferredUID = ($0 == Self.autoTag) ? nil : $0 }
        )
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

// MARK: - Hotkeys

private struct HotkeysSettingsTab: View {
    @EnvironmentObject private var hotkeys: HotkeySettings

    /// The action whose hotkey the user is currently re-recording. Nil when
    /// no row is in capture mode.
    @State private var recordingAction: HotkeyAction?
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dictation hotkeys")
                .font(.title3.weight(.semibold))
            Text("Press the hotkey anywhere in macOS to start dictating. Press it again to stop, transcribe, and paste at the cursor. Click a binding to record a new one; press Esc to cancel.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(HotkeyAction.allCases) { action in
                    HotkeyRow(action: action,
                              isRecording: recordingAction == action,
                              onStartRecording: { recordingAction = action },
                              onCaptured: { applyCapture($0, for: action) },
                              onCancel: { recordingAction = nil },
                              onReset: { resetToDefault(action) })
                }
            }

            if let lastError {
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func applyCapture(_ binding: HotkeyBinding, for action: HotkeyAction) {
        recordingAction = nil

        // Reject empty / modifier-only combos: Carbon will accept them but
        // Apple shortcut conventions require at least one of ⌘ ⌃ ⌥.
        let needsModifier = UInt32(cmdKey | controlKey | optionKey)
        guard binding.modifiers & needsModifier != 0 else {
            lastError = "Please include at least one modifier (⌘, ⌃, or ⌥)."
            return
        }

        // Reject collisions with the *other* action so the user doesn't
        // shoot themselves in the foot.
        for other in HotkeyAction.allCases where other != action {
            let existing = hotkeys.binding(for: other)
            if existing == binding {
                lastError = "\(binding.displayName) is already used for \(other.displayLabel)."
                return
            }
        }

        lastError = nil
        hotkeys.setBinding(binding, for: action)
    }

    private func resetToDefault(_ action: HotkeyAction) {
        hotkeys.resetToDefault(action)
        lastError = nil
    }
}

private struct HotkeyRow: View {
    @EnvironmentObject private var hotkeys: HotkeySettings

    let action: HotkeyAction
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onCaptured: (HotkeyBinding) -> Void
    let onCancel: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack {
            Text(action.displayLabel)
                .font(.body)
                .frame(width: 160, alignment: .leading)

            Spacer()

            HotkeyCaptureField(currentDisplay: hotkeys.binding(for: action).displayName,
                               isRecording: isRecording,
                               onStartRecording: onStartRecording,
                               onCaptured: onCaptured,
                               onCancel: onCancel)
                .frame(width: 160)

            Button("Reset") { onReset() }
                .buttonStyle(.borderless)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A click-to-record hotkey field. When activated it becomes first responder
/// and captures the next non-modifier keyDown event into a `HotkeyBinding`.
/// Hosted via `NSViewRepresentable` because SwiftUI's focus / key event APIs
/// don't expose the raw virtual key code we need to register through Carbon.
private struct HotkeyCaptureField: NSViewRepresentable {
    let currentDisplay: String
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onCaptured: (HotkeyBinding) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> HotkeyCaptureNSView {
        let view = HotkeyCaptureNSView()
        view.onStartRecording = onStartRecording
        view.onCaptured = onCaptured
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: HotkeyCaptureNSView, context: Context) {
        nsView.label = isRecording ? "Press a hotkey…" : currentDisplay
        nsView.recording = isRecording
        nsView.onStartRecording = onStartRecording
        nsView.onCaptured = onCaptured
        nsView.onCancel = onCancel
        if isRecording {
            nsView.window?.makeFirstResponder(nsView)
        } else if nsView.window?.firstResponder === nsView {
            nsView.window?.makeFirstResponder(nil)
        }
    }
}

final class HotkeyCaptureNSView: NSView {
    var label: String = "" { didSet { needsDisplay = true } }
    var recording: Bool = false { didSet { needsDisplay = true } }
    var onStartRecording: (() -> Void)?
    var onCaptured: ((HotkeyBinding) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard !recording else { return }
        onStartRecording?()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }

        // Esc cancels the capture without saving.
        if event.keyCode == kVK_Escape {
            onCancel?()
            return
        }

        // Carbon expects its own modifier flags, not NSEvent's. Translate.
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command)  { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift)    { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option)   { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control)  { modifiers |= UInt32(controlKey) }

        let binding = HotkeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        onCaptured?(binding)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if recording {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.controlBackgroundColor.setFill()
            NSColor.separatorColor.setStroke()
        }
        path.lineWidth = 1
        path.fill()
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: recording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let string = NSAttributedString(string: label, attributes: attrs)
        let size = string.size()
        let origin = NSPoint(x: rect.midX - size.width / 2,
                             y: rect.midY - size.height / 2)
        string.draw(at: origin)
    }
}

// MARK: - Models

private struct ModelsSettingsTab: View {
    @EnvironmentObject private var manager: ModelManager
    @EnvironmentObject private var transcription: TranscriptionService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Whisper models")
                .font(.title3.weight(.semibold))
            Text("English dictation uses the OpenAI turbo model; Hebrew uses ivrit.ai. Both download automatically on first launch (~1.6 GB each). The optional ivrit.ai large model is higher accuracy but ~2× slower.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(WhisperModel.all) { model in
                    ModelRow(model: model)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ModelRow: View {
    @EnvironmentObject private var manager: ModelManager
    let model: WhisperModel

    var body: some View {
        let progress = manager.downloads[model.name]
        let installed = manager.isInstalled(model)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.body)
                Text(byteCountString(model.sizeBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let progress {
                ProgressView(value: progress).frame(width: 80)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.iconOnly)
                Button("Delete", role: .destructive) {
                    try? manager.delete(model)
                }
                .buttonStyle(.borderless)
            } else {
                Button("Download") { manager.download(model) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func byteCountString(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useGB, .useMB]
        return f.string(fromByteCount: bytes)
    }
}

// MARK: - LLM

private struct LLMSettingsTab: View {
    @EnvironmentObject private var settings: LLMSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                toolPicker
                Divider()
                summarySection
                Divider()
                timeoutSection
                Divider()
                namePromptSection
                Divider()
                actionPromptSection
                Divider()
                testSection
            }
            .padding(.vertical, 4)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LLM integration")
                .font(.title3.weight(.semibold))
            Text("After a recording finishes transcribing, Mila can shell out to a local LLM CLI (Claude or Cursor) to suggest a name and/or run a custom action with the transcript. Both CLIs run on your machine with whatever auth you already configured for them; we only forward the transcript text — nothing else.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var toolPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Tool", selection: $settings.tool) {
                ForEach(LLMTool.allCases) { tool in
                    Text(tool.displayName).tag(tool)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Executable path").frame(width: 130, alignment: .leading)
                TextField("(use $PATH)", text: $settings.executablePath)
                    .textFieldStyle(.roundedBorder)
            }
            .font(.callout)
            Text("Leave blank to look up the binary on $PATH. Set this if `claude` / `cursor-agent` lives somewhere a GUI app won't see by default (e.g. ~/.local/bin, an asdf shim).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Extra CLI args").frame(width: 130, alignment: .leading)
                TextField("(none) e.g. --model claude-sonnet-4-6", text: $settings.extraArgs)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
            }
            .font(.callout)
            Text("Appended to every run (name suggestion, auto-summary, Send action, and the test below). Shell-style quoting is supported; for most CLIs a flag here overrides an earlier one. Live AI manages its own model and is unaffected.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Automatically summarize recordings", isOn: $settings.summaryEnabled)
                .toggleStyle(.switch)
                .accessibilityIdentifier("llm.summary.enabled.toggle")
            Text("When on, Mila runs a one-shot LLM pass after every recording finishes and stores the result as the recording's AI Overview. Turn this off to keep Mila transcript-only. Existing summaries are kept, and any recording that still has one can be refreshed from its right-click \u{201C}Regenerate summary\u{201D} action.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var timeoutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("CLI timeout").frame(width: 100, alignment: .leading)
                Stepper(value: $settings.cliTimeout, in: 30...900, step: 30) {
                    EmptyView()
                }
                Text("\(Int(settings.cliTimeout))s")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                Button("Reset") { settings.cliTimeout = 300 }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .font(.callout)
            Text("Maximum time Mila waits for a CLI response before giving up. Applies to title generation, auto-summary, and the Send-action button. Raise this if your prompt uses agentic tools (e.g. calendar lookup) that need extra time to complete.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var namePromptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Suggest a name from the LLM", isOn: $settings.nameGenerationEnabled)
                .toggleStyle(.switch)
            Text("Prompt sent alongside the transcript when you click Suggest in the rename sheet:")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $settings.namePrompt)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 70, maxHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .disabled(!settings.nameGenerationEnabled)
            ExamplesView(title: "Examples", items: LLMSettings.nameExamples) {
                settings.namePrompt = $0
            }
        }
    }

    private var actionPromptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Run an action with the transcript", isOn: $settings.postActionEnabled)
                .toggleStyle(.switch)
            Text("Prompt the rename sheet's Run-action button sends together with the transcript:")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $settings.postActionPrompt)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 70, maxHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .disabled(!settings.postActionEnabled)
            ExamplesView(title: "Examples", items: LLMSettings.actionExamples) {
                settings.postActionPrompt = $0
            }
        }
    }

    // MARK: Test panel

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Test")
                .font(.title3.weight(.semibold))
            Text("Run the configured prompt against a sample transcript to see exactly what Mila sends and what your CLI returns. Use this to debug a tool that isn't working — the command shown below is the literal one Mila runs, so you can copy it into a terminal yourself.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Prompt to test", selection: $settings.testPromptKind) {
                ForEach(LLMSettings.TestPromptKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Text("Sample transcript")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: $settings.testTranscript)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 90, maxHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))

            Text("The test uses your configured Extra CLI args (above), so it reproduces exactly what a real run does.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    Task { await settings.runTest() }
                } label: {
                    if settings.isTesting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Running…")
                        }
                    } else {
                        Text("Run test")
                    }
                }
                .disabled(settings.tool == .none || settings.isTesting)

                if settings.tool == .none {
                    Text("Select a tool above first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let result = settings.lastTestResult {
                LLMTestResultView(result: result)
            }
        }
    }
}

/// Renders the outcome of a Settings → LLM test run: the exact command (with a
/// Copy button), a status line, and the captured stdout/stderr. Designed so a
/// user who can't get their CLI working can read or copy everything they need
/// to self-diagnose.
private struct LLMTestResultView: View {
    let result: LLMTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine

            if !result.command.isEmpty {
                labeledBlock("Command", text: result.command, copyable: true)
            }
            if let error = result.setupError {
                labeledBlock("Problem", text: error, copyable: false)
            }
            if result.didLaunch {
                if !result.stdout.isEmpty {
                    labeledBlock("Output (stdout)", text: result.stdout, copyable: true)
                }
                if !trimmed(result.stderr).isEmpty {
                    labeledBlock("Diagnostics (stderr)", text: result.stderr, copyable: true)
                }
                if result.stdout.isEmpty && trimmed(result.stderr).isEmpty {
                    Text("The CLI produced no output.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            icon
            Text(statusText)
                .font(.callout.weight(.medium))
            Spacer()
            if result.durationSeconds > 0 {
                Text(String(format: "%.1fs", result.durationSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if result.succeeded {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var statusText: String {
        if result.succeeded { return "Success" }
        if result.timedOut { return "Timed out — the CLI didn't respond in time" }
        if let error = result.setupError, !result.didLaunch { return error }
        if let code = result.exitCode { return "CLI exited with status \(code)" }
        return "Failed"
    }

    private func labeledBlock(_ label: String, text: String, copyable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if copyable {
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy to clipboard")
                }
            }
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 160)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Compact "click an example to fill the prompt field above" helper.
private struct ExamplesView: View {
    let title: String
    let items: [String]
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(items, id: \.self) { item in
                Button {
                    onPick(item)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "arrow.up.left")
                            .font(.caption)
                            .foregroundStyle(.tint)
                        Text(item)
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
    }
}

// MARK: - Speakers

/// Slim Speakers tab. Surface area is: enable/disable checkbox, a single
/// health-status pill, and a "Run health check" button. When the bundled
/// PythonRuntime is shipping but torch hasn't been runtime-downloaded yet,
/// a bootstrap progress card takes priority over the health pill.
private struct DiarizationSettingsTab: View {
    @EnvironmentObject private var diarization: DiarizationSettings

    var body: some View {
        // Indirect through a content view so we can attach an ObservedObject
        // to the bootstrap instance — @EnvironmentObject isn't visible in
        // init() so we can't bind the ObservedObject there.
        DiarizationSettingsTabContent(
            diarization: diarization,
            bootstrap: diarization.bootstrap
        )
    }
}

private struct DiarizationSettingsTabContent: View {
    @ObservedObject var diarization: DiarizationSettings
    @ObservedObject var bootstrap: DiarizationBootstrap

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Speaker diarization")
                .font(.title3.weight(.semibold))

            Text("Identify who's speaking in your recordings. Required components install automatically on first enable; the check below confirms the local pipeline is ready.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Enable speaker diarization", isOn: $diarization.isEnabled)
                .accessibilityIdentifier("speakers.enable.toggle")

            if showingBootstrapCard {
                bootstrapCard
                    .accessibilityIdentifier("speakers.bootstrap.card")
            } else {
                healthCard
                    .accessibilityIdentifier("speakers.health.card")
            }

            if let error = diarization.healthCheckResult?.error,
               diarization.healthCheckResult?.ok == false,
               !showingBootstrapCard {
                ScrollView {
                    Text(error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
                .padding(8)
                .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }

            // Stable accessibility probe for XCUITest — reads "ok" iff
            // the health-check result is ok. Zero-size, not visible to
            // humans. Lets the automated GUI test wait deterministically
            // for "Speakers self-heals to green" without scraping labels.
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityIdentifier("speakers.health.ok.probe")
                .accessibilityLabel(diarization.healthCheckResult?.ok == true ? "ok" : "not_ok")

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Show the bootstrap progress card whenever a bundled runtime exists
    /// AND it's still in flight or has failed. Once ready (or if no
    /// bundle is present at all), we go back to the regular health pill.
    private var showingBootstrapCard: Bool {
        guard diarization.hasBundledRuntime else { return false }
        switch bootstrap.stage {
        case .ready, .notStarted:
            return false
        default:
            return true
        }
    }

    private var bootstrapCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                bootstrapIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(bootstrapTitle)
                        .font(.callout.weight(.medium))
                    Text(bootstrapSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if case .downloadingTorch(let progress) = bootstrap.stage {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }
            if case .failed = bootstrap.stage {
                Button("Retry") {
                    Task { await bootstrap.bootstrapIfNeeded() }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var healthCard: some View {
        HStack(spacing: 10) {
            healthIcon
            Text(healthLabel)
                .font(.callout)
            Spacer()
            Button {
                Task { await diarization.runHealthCheck() }
            } label: {
                if diarization.isHealthChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Run health check")
                }
            }
            .disabled(diarization.isHealthChecking)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var bootstrapIcon: some View {
        switch bootstrap.stage {
        case .downloadingTorch, .installingTorch, .signing, .checking:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
        }
    }

    private var bootstrapTitle: String {
        switch bootstrap.stage {
        case .notStarted:          return "Preparing speaker detection…"
        case .checking:            return "Checking…"
        case .downloadingTorch:    return "Downloading torch runtime"
        case .installingTorch:     return "Installing torch"
        case .signing:             return "Finalizing install"
        case .ready:               return "Ready"
        case .failed(let msg):     return "Setup failed: \(msg)"
        }
    }

    private var bootstrapSubtitle: String {
        switch bootstrap.stage {
        case .downloadingTorch(let p):
            return "\(Int(p * 100))% — torch is one-time, ~60 MB"
        case .installingTorch, .signing:
            return "Almost done — installing into the speaker runtime"
        case .failed:
            return "Retry to try the download again"
        default:
            return "First-time setup runs once; subsequent launches skip it"
        }
    }

    @ViewBuilder
    private var healthIcon: some View {
        if diarization.isHealthChecking {
            ProgressView().controlSize(.small)
        } else if let result = diarization.healthCheckResult {
            if result.ok {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } else {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

    private var healthLabel: String {
        if diarization.isHealthChecking { return "Checking…" }
        guard let result = diarization.healthCheckResult else { return "Not checked yet" }
        return result.ok ? "Speaker detection is working" : "Speaker detection unavailable"
    }
}

// MARK: - Meetings

/// Settings → Meetings. Toggles the floating "Zoom meeting detected" prompt
/// and surfaces the per-app silence list so a user who clicked
/// "Don't show this for Zoom" inside the prompt can undo that without
/// hunting through UserDefaults.
private struct MeetingsSettingsTab: View {
    @EnvironmentObject private var settings: MeetingDetectionSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Toggle(isOn: $settings.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prompt when a meeting starts or ends")
                            .font(.body)
                        Text("Mila shows a small prompt in the top-right when it sees you join a meeting in a supported app — and, while it's recording, when that meeting ends, it offers to stop.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.regular)

                Divider()

                supportedAppsBlock
                silencedAppsBlock

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Meetings")
                .font(.title3.weight(.semibold))
            Text("Auto-prompt when Mila notices you're in a call so you don't have to remember to start recording.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var supportedAppsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Supported apps")
                .font(.callout.weight(.semibold))
            ForEach(MeetingDetector.supportedApps, id: \.bundleID) { app in
                HStack {
                    Image(systemName: "video.fill")
                        .foregroundStyle(.tint)
                    Text(app.displayName)
                    Spacer()
                    if settings.isDisabled(forBundleID: app.bundleID) {
                        Text("Silenced")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !settings.enabled {
                        Text("Off")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("On")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var silencedAppsBlock: some View {
        let silenced = MeetingDetector.supportedApps.filter {
            settings.isDisabled(forBundleID: $0.bundleID)
        }
        if !silenced.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Silenced from inside the prompt")
                    .font(.callout.weight(.semibold))
                Text("You clicked \"Don't show this for X\" on one of these. Re-enable the prompt for them here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(silenced, id: \.bundleID) { app in
                    HStack {
                        Text(app.displayName)
                        Spacer()
                        Button("Re-enable") {
                            settings.reenable(bundleID: app.bundleID)
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - Live AI

/// Settings → Live AI. Hosts the master toggle, the cheap-model override,
/// the system prompt editor (with reset-to-default), and the two cost
/// dials that most users will never touch.
private struct LiveAISettingsTab: View {
    @EnvironmentObject private var settings: LiveAISettings
    @EnvironmentObject private var llm: LLMSettings
    @State private var showAdvanced: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !settings.isLiveAIAvailable {
                    hardwareDisabledNotice
                }
                masterToggle
                if !llm.isConfigured && settings.isLiveAIAvailable {
                    notConfiguredHint
                }
                Divider()
                promptEditor
                advancedDisclosure
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Banner shown when this Mac is below the hardware bar for Live
    /// AI (currently: any MacBook Air). The toggle stays visible but
    /// is greyed out — the persisted preference still round-trips,
    /// so taking the user's settings back to a fast Mac restores the
    /// previous state without surprises.
    private var hardwareDisabledNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Disabled on this Mac")
                        .font(.callout.weight(.semibold))
                    Text("MacBook Air — Live AI was too slow on Air-class chips when this gate was added. With Apple Neural Engine encoder offload it may now keep up. Recordings still transcribe in the background regardless.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: $settings.forceLiveAIOnLowEndHardware) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Try Live AI anyway")
                        .font(.callout)
                    Text("Override the hardware gate. If transcription lags behind, disable this and use background mode instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Live AI mode")
                .font(.title3.weight(.semibold))
            Text("During a recording, Mila streams the transcript to your LLM every few seconds and surfaces action items in real time. Requires Claude or Cursor CLI set up under LLM.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var masterToggle: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $settings.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Live AI mode")
                    Text("Off by default. When on, the home screen swaps to a split-pane recording view as soon as you press Record.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            // Hardware gate: keep the toggle visible (so the user
            // knows the feature exists) but block interaction on Macs
            // where Live AI is too slow to be useful. The persisted
            // value still round-trips.
            .disabled(!settings.isLiveAIAvailable)

            HStack {
                Text("Output language")
                    .font(.callout)
                Spacer()
                Picker("Output language", selection: $settings.outputLanguage) {
                    ForEach(LiveAISettings.OutputLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            .disabled(!settings.isLiveAIAvailable)
        }
    }

    private var notConfiguredHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("No LLM CLI is configured under Settings → LLM. The toggle above is a no-op until you pick Claude or Cursor there.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("System prompt")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button("Reset to default") {
                    settings.prompt = LiveAISettings.defaultPrompt
                }
                .controlSize(.small)
            }
            TextEditor(text: $settings.prompt)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 160)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
            Text("Tip: the default prompt asks for a strict JSON array so Mila can parse the response. Free-form prose will be ignored.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advancedDisclosure: some View {
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model").font(.callout.weight(.semibold))
                    TextField(LiveAISettings.defaultModel, text: $settings.model)
                        .textFieldStyle(.roundedBorder)
                    Text("Passed to the CLI as `--model`. Default is the cheapest current Claude. Leave blank to let your CLI pick.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Auto-segment by silence (beta)", isOn: $settings.useVAD)
                        .font(.callout.weight(.semibold))
                    Text("Detect natural pauses (≥400ms silence) and run whisper once per utterance instead of on a fixed timer. Lower latency, cleaner word boundaries. Force-cut at 25s for monologue speakers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Background mode (hide live pane)", isOn: $settings.backgroundMode)
                        .font(.callout.weight(.semibold))
                    Text("Stay on the Home screen during recording. Transcription, speaker labels, and Live AI summary still run in the background and are saved when you stop. Useful on lower-power Macs where rendering the live pane competes with whisper for CPU.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Update every").font(.callout.weight(.semibold))
                        Spacer()
                        Text("\(Int(settings.chunkSeconds))s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.chunkSeconds, in: 15...60, step: 5)
                        .disabled(settings.useVAD)
                    Text("How often Mila re-transcribes and re-prompts when auto-segment is off. 30s is the default — matches the whisper window so words don't get cut mid-utterance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("AI update interval").font(.callout.weight(.semibold))
                        Spacer()
                        Text("\(Int(settings.llmMinIntervalSeconds))s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.llmMinIntervalSeconds, in: 5...60, step: 5)
                    Text("Minimum time between AI summary updates. The transcript is sent to the LLM at most once per interval, so longer values use less CPU and fewer API calls on long recordings. 20s is the default; the final update when you stop always runs regardless.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Speaker similarity threshold").font(.callout.weight(.semibold))
                        Spacer()
                        Text(String(format: "%.2f", settings.speakerSimilarityThreshold))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.speakerSimilarityThreshold, in: 0.5...0.95, step: 0.01)
                    Text("Higher values make the live diarizer more conservative about merging similar voices into one speaker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        }
    }
}
