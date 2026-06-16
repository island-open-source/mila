import AppKit
import Combine
import CoreAudio
import CoreGraphics
import OSLog

/// Detects when the user joined a meeting in a supported app, so the
/// app-level prompt coordinator can offer to start transcribing.
///
/// **Primary signal — microphone capture (macOS 14.4+).** During *any*
/// Zoom meeting the Zoom process is actively capturing the mic. The Core
/// Audio per-process API (`kAudioProcessPropertyIsRunningInput`) reports
/// that per bundle ID, with **no permission prompt** and crucially
/// **independent of the window title** — so it fires for instant,
/// scheduled, and join-by-link meetings alike, and it re-arms naturally
/// (capture stops the moment you leave). This replaced a brittle window-
/// title match (`title contains "zoom meeting"`) that silently failed for
/// named/scheduled meetings and needed Screen Recording permission.
///
/// **Fallback — window title (older macOS / API unavailable).** Where the
/// per-process audio API isn't present we fall back to scanning Zoom's
/// on-screen window titles via `CGWindowListCopyWindowInfo` (needs Screen
/// Recording permission for titles; silently skipped without it).
///
/// Detection is a low-frequency poll (every 3 s), not an event
/// subscription — neither the audio nor the window signal posts a "user
/// joined a meeting" notification.
@MainActor
final class MeetingDetector: ObservableObject {
    private static let log = Logger(
        subsystem: "io.island.whisper.IslandWhisper", category: "MeetingDetector")

    /// One supported app. `bundleID` is the canonical ID used for the
    /// prompt's snooze / silence keys and display; `captureBundlePrefixes`
    /// are matched (by prefix) against the bundle IDs of processes that are
    /// actively capturing the mic; `meetingTitleHints` is the window-title
    /// fallback used only when the audio API is unavailable.
    struct App: Hashable {
        let bundleID: String
        let displayName: String
        /// Any running audio process whose bundle ID has one of these
        /// prefixes AND is capturing mic input ⇒ this app is in a meeting.
        /// A prefix (not exact) because Zoom may capture under a helper
        /// bundle ID (`us.zoom.*`) rather than `us.zoom.xos`.
        let captureBundlePrefixes: [String]
        /// Lowercased window-title substrings, fallback path only.
        let meetingTitleHints: [String]
    }

    /// Supported meeting apps. Zoom is the only one implemented now;
    /// adding Google Meet / Teams later is an entry here (they'd use the
    /// same mic-capture signal, keyed on their own bundle IDs).
    static let supportedApps: [App] = [
        App(
            bundleID: "us.zoom.xos",
            displayName: "Zoom",
            captureBundlePrefixes: ["us.zoom"],
            meetingTitleHints: ["zoom meeting"]
        )
    ]

    /// Fired exactly once per meeting — the first poll that sees a
    /// supported app in a meeting. Re-armed when that app stops being in a
    /// meeting, so leaving and rejoining a call surfaces a fresh prompt.
    let meetingStarted = PassthroughSubject<App, Never>()

    private var pollTask: Task<Void, Never>?
    /// Canonical bundle IDs we've already prompted for in the current run
    /// of a meeting. Cleared (re-armed) when the meeting ends.
    private var firedFor: Set<String> = []
    /// Logged once so we know which detection path is live in the field.
    private var loggedMode = false

    func start() {
        guard pollTask == nil else { return }
        Self.log.notice("starting meeting detector (poll every 3s)")
        pollTask = Task { @MainActor [weak self] in
            // Small initial delay so we don't fire during app launch (the
            // user may already be in a meeting — no need to nag them in
            // the first second).
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            while let self, !Task.isCancelled {
                self.pollOnce()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() {
        Self.log.notice("stopping meeting detector")
        pollTask?.cancel()
        pollTask = nil
        firedFor.removeAll()
    }

    /// Exposed for tests and one-shot manual triggers (e.g. a future
    /// "Test the meeting prompt" button in Settings).
    func pollOnce() {
        var activeMeetings: Set<String> = []

        // Primary path: which bundle IDs are capturing the mic right now?
        // nil ⇒ the per-process audio API isn't available (older macOS).
        let capturing = bundleIDsCapturingMicInput()
        if !loggedMode {
            loggedMode = true
            Self.log.notice("detection mode: \(capturing == nil ? "window-title (fallback)" : "mic-capture", privacy: .public)")
        }

        for app in Self.supportedApps {
            let inMeeting: Bool
            if let capturing {
                inMeeting = app.captureBundlePrefixes.contains { prefix in
                    capturing.contains { $0.hasPrefix(prefix) }
                }
            } else {
                inMeeting = isRunning(app) && hasMeetingWindow(for: app)
            }

            if inMeeting {
                activeMeetings.insert(app.bundleID)
                if !firedFor.contains(app.bundleID) {
                    firedFor.insert(app.bundleID)
                    Self.log.notice("meeting detected: \(app.displayName, privacy: .public) → firing prompt")
                    meetingStarted.send(app)
                }
            }
        }

        // Re-arm any app that left its meeting — leaving a call and
        // joining a new one should produce a fresh prompt.
        let ended = firedFor.subtracting(activeMeetings)
        if !ended.isEmpty {
            Self.log.notice("meeting ended, re-armed: \(ended, privacy: .public)")
        }
        firedFor = firedFor.intersection(activeMeetings)
    }

    private func isRunning(_ app: App) -> Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == app.bundleID }
    }

    // MARK: - Primary signal: per-process mic capture (Core Audio)

    /// Bundle IDs of processes currently capturing microphone input, via
    /// the Core Audio per-process object API. Returns `nil` when that API
    /// is unavailable (older macOS) so the caller falls back to window
    /// titles. Reading capture *state* (not the audio samples) needs no
    /// permission and triggers no TCC prompt.
    private func bundleIDsCapturingMicInput() -> Set<String>? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(system, &listAddr) else { return nil }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddr, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processes = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &listAddr, 0, nil, &size, &processes) == noErr
        else { return nil }

        var capturing: Set<String> = []
        for proc in processes where isRunningInput(proc) {
            if let bundleID = processBundleID(proc) {
                capturing.insert(bundleID)
            }
        }
        return capturing
    }

    private func isRunningInput(_ object: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &addr) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    private func processBundleID(_ object: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var cfString: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &cfString) == noErr,
              let cfString else { return nil }
        return cfString.takeRetainedValue() as String
    }

    // MARK: - Fallback signal: window title (older macOS)

    /// True iff a window owned by an app with the given bundle ID has a
    /// title containing one of `app.meetingTitleHints`. Without Screen
    /// Recording permission, window titles for other processes come back
    /// nil — in that case we conservatively return false.
    private func hasMeetingWindow(for app: App) -> Bool {
        let runningPIDs = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == app.bundleID }
            .map { $0.processIdentifier }
        guard !runningPIDs.isEmpty else { return false }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        for window in info {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  runningPIDs.contains(pid) else { continue }
            guard let title = window[kCGWindowName as String] as? String,
                  !title.isEmpty else { continue }
            let lower = title.lowercased()
            if app.meetingTitleHints.contains(where: { lower.contains($0) }) {
                return true
            }
        }
        return false
    }
}
