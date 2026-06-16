import Foundation
import Combine

/// User-facing toggle + per-app silencing for the meeting auto-prompt.
///
/// The prompt asks "Start transcribing?" when a meeting app (Zoom for
/// now — Google Meet / Teams are easy to add later) is detected in a live
/// meeting. Two pieces of state are persisted:
///
///   * `enabled` — global on/off. ON by default; the toggle lives in
///     Settings → Meetings.
///   * `disabledBundleIDs` — apps the user said "stop asking for this"
///     about, via the prompt's overflow chevron. Stored as a comma-
///     separated string in UserDefaults so it survives launches without
///     a custom Codable property list.
///
/// There used to be a 60-minute per-app *snooze* on dismiss — a workaround
/// for the old window-title detector that couldn't tell one meeting from
/// the next. `MeetingDetector` now re-arms reliably when a meeting ends
/// (mic capture stops), so "Not now" simply declines the current meeting
/// and the next one prompts again; no app-wide snooze is needed.
@MainActor
final class MeetingDetectionSettings: ObservableObject {
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    @Published private(set) var disabledBundleIDs: Set<String> {
        didSet {
            let joined = disabledBundleIDs.sorted().joined(separator: ",")
            defaults.set(joined, forKey: Keys.disabledBundleIDs)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // ON by default — first launch should surface the feature so
        // users discover it. The toggle in Settings flips it.
        if defaults.object(forKey: Keys.enabled) == nil {
            defaults.set(true, forKey: Keys.enabled)
        }
        self.enabled = defaults.bool(forKey: Keys.enabled)
        let raw = defaults.string(forKey: Keys.disabledBundleIDs) ?? ""
        self.disabledBundleIDs = Set(
            raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        )
    }

    func isDisabled(forBundleID bundleID: String) -> Bool {
        disabledBundleIDs.contains(bundleID)
    }

    /// Permanently silence the prompt for `bundleID`. Used by the
    /// "Don't show this for X" affordance inside the prompt overlay.
    func disable(bundleID: String) {
        guard !bundleID.isEmpty else { return }
        var copy = disabledBundleIDs
        copy.insert(bundleID)
        disabledBundleIDs = copy
    }

    /// Undo a silence — reverse of `disable(bundleID:)`. Surfaced from
    /// Settings → Meetings so the user can re-enable a previously-
    /// silenced app without digging into defaults.
    func reenable(bundleID: String) {
        var copy = disabledBundleIDs
        copy.remove(bundleID)
        disabledBundleIDs = copy
    }

    private enum Keys {
        static let enabled = "meetingDetection.enabled"
        static let disabledBundleIDs = "meetingDetection.disabledBundleIDs"
    }
}
