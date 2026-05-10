import AppKit
import ApplicationServices

/// Wraps the macOS Accessibility (AX) trust check that gates the synthetic
/// Cmd+V we use to paste dictated text. Without AX trust, `CGEvent.post` to
/// `.cghidEventTap` is silently dropped — the user sees "I dictated, the
/// transcript is on the clipboard, nothing got pasted" and assumes the app
/// is broken.
@MainActor
enum AccessibilityPermission {

    /// True iff the process is currently listed AND enabled in
    /// System Settings → Privacy & Security → Accessibility.
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// First call: shows the macOS "<app> wants to control this computer
    /// using accessibility features" system prompt and adds us to the
    /// Accessibility list (disabled). Subsequent calls are silent.
    /// Note: macOS requires an app relaunch after the user toggles the
    /// permission on for trust to actually take effect.
    @discardableResult
    static func requestPromptIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static var didShowMissingAlert = false

    /// Surface the "we have your transcript but can't paste it" UX exactly
    /// once per app session so we don't nag the user on every dictation.
    /// The transcript is left on the clipboard so the user can paste it
    /// manually with ⌘V.
    static func notifyMissing() {
        guard !didShowMissingAlert else { return }
        didShowMissingAlert = true
        let alert = NSAlert()
        alert.messageText = "Accessibility permission required"
        alert.informativeText = """
        IslandWhisper needs Accessibility permission to paste dictated text into other apps.

        Your transcript is on the clipboard — paste it with ⌘V.

        Grant permission in System Settings → Privacy & Security → Accessibility, then enable IslandWhisper. macOS may require you to quit and reopen the app after granting access.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
