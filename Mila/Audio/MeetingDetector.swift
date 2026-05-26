import AppKit
import Combine
import CoreGraphics

/// Detects when the user joined a meeting in a supported app, so the
/// app-level prompt coordinator can offer to start transcribing.
///
/// Detection is a low-frequency poll (every 3 s) of the window list,
/// not an event subscription, because none of the meeting apps publish
/// a "user joined a meeting" notification. The polling cost is trivial
/// — `CGWindowListCopyWindowInfo` is a single syscall returning a
/// description dictionary, and we only inspect titles for processes
/// matching a known bundle ID.
///
/// We rely on Screen Recording permission for cross-process window
/// titles. Mila already requests this for `SystemAudioRecorder`, so the
/// common case is "we have it." When the permission is missing we
/// silently skip detection — the prompt simply never fires, which is
/// better than nagging the user about another permission.
@MainActor
final class MeetingDetector: ObservableObject {
    /// One supported app — bundle ID plus the window-title substrings
    /// that indicate the user is *in a meeting* (as opposed to just
    /// having the app open on the launcher screen).
    struct App: Hashable {
        let bundleID: String
        let displayName: String
        /// Substrings, lowercased, used against window titles. A match
        /// means "this app is hosting a meeting right now."
        let meetingTitleHints: [String]
    }

    /// The current list of supported meeting apps. Zoom is the only one
    /// implemented now; adding Google Meet / Teams later is just an
    /// entry in this array.
    static let supportedApps: [App] = [
        App(
            bundleID: "us.zoom.xos",
            displayName: "Zoom",
            // Zoom's meeting window title is "Zoom Meeting" most of the
            // time; the standalone launcher window is "Zoom Workplace"
            // or "Zoom" without "Meeting" in it, so the substring is
            // tight enough not to false-positive.
            meetingTitleHints: ["zoom meeting"]
        )
    ]

    /// Fired exactly once per meeting — the first time we detect that a
    /// supported app has a meeting window. Re-armed when the meeting
    /// window disappears, so leaving and rejoining a call surfaces a
    /// second prompt.
    let meetingStarted = PassthroughSubject<App, Never>()

    private var pollTask: Task<Void, Never>?
    /// Bundle IDs we've already prompted for in the current "session"
    /// (a continuous run of the meeting window). Cleared when the
    /// meeting window goes away.
    private var firedFor: Set<String> = []

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            // Initial small delay so the detector doesn't fire during
            // app launch (when Zoom might already have a meeting open
            // — the user just got home from work, that's fine, no need
            // to nag them in the first second).
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            while let self, !Task.isCancelled {
                self.pollOnce()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        firedFor.removeAll()
    }

    /// Exposed for tests and one-shot manual triggers (e.g. a future
    /// "Test the meeting prompt" button in Settings).
    func pollOnce() {
        let running = NSWorkspace.shared.runningApplications
        var activeMeetings: Set<String> = []

        for app in Self.supportedApps {
            // First, is the app even running? Bail early — cheap check
            // before pulling the window list.
            guard running.contains(where: { $0.bundleIdentifier == app.bundleID }) else {
                continue
            }
            if hasMeetingWindow(for: app) {
                activeMeetings.insert(app.bundleID)
                if !firedFor.contains(app.bundleID) {
                    firedFor.insert(app.bundleID)
                    meetingStarted.send(app)
                }
            }
        }

        // Re-arm any app whose meeting window went away — leaving a
        // call and joining a new one should produce a fresh prompt.
        firedFor = firedFor.intersection(activeMeetings)
    }

    /// True iff a window owned by an app with the given bundle ID has a
    /// title containing one of `app.meetingTitleHints`. Without Screen
    /// Recording permission, window titles for other processes come
    /// back nil — in that case we conservatively return false rather
    /// than firing on every running supported app.
    private func hasMeetingWindow(for app: App) -> Bool {
        let runningPIDs = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == app.bundleID }
            .map { $0.processIdentifier }
        guard !runningPIDs.isEmpty else { return false }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for window in info {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  runningPIDs.contains(pid) else { continue }
            guard let title = window[kCGWindowName as String] as? String,
                  !title.isEmpty else {
                // No title (or empty title) most likely means we don't
                // have Screen Recording permission for window titles —
                // skip the window. (Zoom's meeting window always has a
                // non-empty title when permission is granted.)
                continue
            }
            let lower = title.lowercased()
            if app.meetingTitleHints.contains(where: { lower.contains($0) }) {
                return true
            }
        }
        return false
    }
}
