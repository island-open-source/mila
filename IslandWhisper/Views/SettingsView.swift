import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Standard `Settings` scene. Opened via `Cmd+,` from the menu bar.
struct SettingsView: View {
    var body: some View {
        TabView {
            HotkeysSettingsTab()
                .tabItem { Label("Hotkeys", systemImage: "command") }
            AudioSettingsTab()
                .tabItem { Label("Audio", systemImage: "mic") }
            ModelsSettingsTab()
                .tabItem { Label("Models", systemImage: "cube.box") }
            LLMSettingsTab()
                .tabItem { Label("LLM", systemImage: "sparkles") }
        }
        .frame(width: 560, height: 520)
        .padding(20)
    }
}

// MARK: - Audio

private struct AudioSettingsTab: View {
    @EnvironmentObject private var settings: AudioInputSettings
    @State private var devices: [AudioDeviceManager.Device] = []

    /// Sentinel UID that means "follow the system default input". Picker's
    /// SwiftUI tag has to be `String`, so we can't use Optional<String> as a
    /// tag value directly here without all the rawValue plumbing.
    private static let autoTag = "__auto__"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Input source")
                .font(.title3.weight(.semibold))
            Text("Choose which microphone Island Whisper reads from. Leave on Automatic to follow whatever macOS uses as its system default. Pin to a specific device if your default is a virtual mic (Krisp, BlackHole, Zoom Audio, etc.) and you'd rather record from the raw hardware.")
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
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: refresh)
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
                namePromptSection
                Divider()
                actionPromptSection
            }
            .padding(.vertical, 4)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LLM integration")
                .font(.title3.weight(.semibold))
            Text("After a recording finishes transcribing, Island Whisper can shell out to a local LLM CLI (Claude or Cursor) to suggest a name and/or run a custom action with the transcript. Both CLIs run on your machine with whatever auth you already configured for them; we only forward the transcript text — nothing else.")
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
