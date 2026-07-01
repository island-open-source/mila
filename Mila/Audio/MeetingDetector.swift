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
    private static let log = MilaLog(category: "MeetingDetector")

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

    /// Fired exactly once when a previously-active meeting goes inactive —
    /// the inverse of `meetingStarted`. Debounced (see
    /// `endConfirmationPolls`) so a momentary mic drop by Zoom doesn't
    /// masquerade as the meeting ending. The coordinator uses this to ask
    /// whether to STOP an in-flight recording.
    let meetingEnded = PassthroughSubject<App, Never>()

    /// How many consecutive polls a previously-active meeting must read as
    /// inactive before we treat it as genuinely ended. At a 3 s poll this
    /// is ~6 s of sustained silence — long enough to ride out Zoom briefly
    /// releasing the mic (mute/unmute, device switch) without a false
    /// "meeting ended". Internal so tests can drive the transition with a
    /// known threshold.
    let endConfirmationPolls: Int

    private var pollTask: Task<Void, Never>?
    /// Canonical bundle IDs we've already prompted for in the current run
    /// of a meeting. Cleared (re-armed) when the meeting ends.
    private var firedFor: Set<String> = []
    /// Canonical bundle IDs we've seen in a meeting AND not yet fired a
    /// `meetingEnded` for. A bundle ID stays here from the first active
    /// poll until the end transition is confirmed and emitted, so we emit
    /// `meetingEnded` exactly once per meeting.
    private var endArmed: Set<String> = []
    /// Per-app count of consecutive polls observed inactive while still
    /// `endArmed`. Reset to zero on any active poll; once it reaches
    /// `endConfirmationPolls` we emit `meetingEnded` and disarm.
    private var inactiveStreak: [String: Int] = [:]
    /// Logged once so we know which detection path is live in the field.
    private var loggedMode = false

    init(endConfirmationPolls: Int = 2) {
        self.endConfirmationPolls = max(1, endConfirmationPolls)
    }

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
        endArmed.removeAll()
        inactiveStreak.removeAll()
    }

    /// Exposed for tests and one-shot manual triggers (e.g. a future
    /// "Test the meeting prompt" button in Settings).
    func pollOnce() {
        // Primary path: which bundle IDs are capturing the mic right now?
        // nil ⇒ the per-process audio API isn't available (older macOS).
        let capturing = bundleIDsCapturingMicInput()
        if !loggedMode {
            loggedMode = true
            Self.log.notice("detection mode: \(capturing == nil ? "window-title (fallback)" : "mic-capture", privacy: .public)")
        }

        var activeMeetings: Set<String> = []
        for app in Self.supportedApps {
            let inMeeting: Bool
            if let capturing {
                inMeeting = app.captureBundlePrefixes.contains { prefix in
                    capturing.contains { $0.hasPrefix(prefix) }
                }
            } else {
                inMeeting = isRunning(app) && hasMeetingWindow(for: app)
            }
            if inMeeting { activeMeetings.insert(app.bundleID) }
        }
        processActiveMeetings(activeMeetings)
    }

    /// Test seam: drive the state machine directly with a set of "in a
    /// meeting" bundle IDs, bypassing Core Audio. Lets unit tests exercise
    /// the start/end transitions (and the end-debounce) deterministically
    /// without a real Zoom or any audio hardware.
    func simulatePollForTesting(activeBundleIDs: Set<String>) {
        processActiveMeetings(activeBundleIDs)
    }

    /// The pure transition core shared by the live poll and the test seam:
    /// given the set of bundle IDs currently in a meeting, fire
    /// `meetingStarted` on the rising edge and `meetingEnded` on a
    /// debounced falling edge.
    private func processActiveMeetings(_ activeMeetings: Set<String>) {
        for app in Self.supportedApps where activeMeetings.contains(app.bundleID) {
            // A meeting is (still) live — arm the end-detector and
            // clear any in-progress inactivity streak so a brief mic
            // drop that already recovered doesn't count toward "ended".
            endArmed.insert(app.bundleID)
            inactiveStreak[app.bundleID] = 0
            if !firedFor.contains(app.bundleID) {
                firedFor.insert(app.bundleID)
                Self.log.notice("meeting detected: \(app.displayName, privacy: .public) → firing prompt")
                meetingStarted.send(app)
            }
        }

        // Re-arm the START prompt for any app that left its meeting —
        // leaving a call and joining a new one should produce a fresh
        // prompt. This is immediate (no debounce): re-arming early is
        // harmless because the next *start* still requires a fresh active
        // poll.
        let ended = firedFor.subtracting(activeMeetings)
        if !ended.isEmpty {
            Self.log.notice("meeting ended, re-armed: \(ended, privacy: .public)")
        }
        firedFor = firedFor.intersection(activeMeetings)

        // Drive the debounced active→inactive transition that powers the
        // STOP prompt. Unlike the re-arm above, this only fires after the
        // meeting has read inactive for `endConfirmationPolls` consecutive
        // polls, so a momentary Zoom mic release doesn't look like the call
        // ending.
        for bundleID in endArmed where !activeMeetings.contains(bundleID) {
            let streak = (inactiveStreak[bundleID] ?? 0) + 1
            if streak >= endConfirmationPolls {
                inactiveStreak[bundleID] = nil
                endArmed.remove(bundleID)
                if let app = Self.supportedApps.first(where: { $0.bundleID == bundleID }) {
                    Self.log.notice("meeting ended (confirmed): \(app.displayName, privacy: .public) → firing stop prompt")
                    meetingEnded.send(app)
                }
            } else {
                inactiveStreak[bundleID] = streak
            }
        }
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
