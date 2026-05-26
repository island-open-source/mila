import Foundation
import Combine

/// User-facing toggle + per-app silencing for the meeting auto-prompt.
///
/// The prompt asks "Start transcribing?" when a meeting app (Zoom for
/// now — Google Meet / Teams are easy to add later) becomes the active
/// meeting host. Two pieces of state are persisted:
///
///   * `enabled` — global on/off. ON by default; the toggle lives in
///     Settings → Meetings.
///   * `disabledBundleIDs` — apps the user said "stop asking for this"
///     about, via the prompt's overflow chevron. Stored as a comma-
///     separated string in UserDefaults so it survives launches without
///     a custom Codable property list.
@MainActor
final class MeetingDetectionSettings: ObservableObject {
    /// How long we suppress the prompt for a bundle ID after the user
    /// dismisses it ("Not now" or auto-dismiss). Matches the user's
    /// "at least 60 minutes" floor: we can't reliably tell a same vs
    /// different meeting from window titles alone, so we snooze the
    /// app and re-arm on the next poll past this deadline.
    static let snoozeDuration: TimeInterval = 60 * 60

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    @Published private(set) var disabledBundleIDs: Set<String> {
        didSet {
            let joined = disabledBundleIDs.sorted().joined(separator: ",")
            defaults.set(joined, forKey: Keys.disabledBundleIDs)
        }
    }
    /// `bundleID` -> wall-clock expiry (`timeIntervalSince1970`). Stored
    /// as `[String: Double]` because that's natively plist-codable.
    @Published private(set) var snoozedUntil: [String: Double] {
        didSet { defaults.set(snoozedUntil, forKey: Keys.snoozedUntil) }
    }

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
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
        let stored = defaults.dictionary(forKey: Keys.snoozedUntil) as? [String: Double] ?? [:]
        let cutoff = now().timeIntervalSince1970
        self.snoozedUntil = stored.filter { $0.value > cutoff }
    }

    func isDisabled(forBundleID bundleID: String) -> Bool {
        disabledBundleIDs.contains(bundleID)
    }

    /// True iff a fresh dismiss has happened recently enough that we
    /// shouldn't re-prompt for this app yet.
    func isSnoozed(forBundleID bundleID: String) -> Bool {
        guard let expiry = snoozedUntil[bundleID] else { return false }
        return expiry > now().timeIntervalSince1970
    }

    /// Suppress the prompt for `bundleID` for `Self.snoozeDuration`.
    /// Called when the user dismisses the prompt (explicit "Not now"
    /// or auto-dismiss timeout). Replaces any earlier snooze for the
    /// same app — a fresh dismiss restarts the clock.
    func snooze(bundleID: String) {
        guard !bundleID.isEmpty else { return }
        var copy = snoozedUntil
        copy[bundleID] = now().addingTimeInterval(Self.snoozeDuration).timeIntervalSince1970
        // Garbage-collect any other expired entries while we're here so
        // the dict doesn't grow over time.
        let cutoff = now().timeIntervalSince1970
        copy = copy.filter { $0.value > cutoff }
        snoozedUntil = copy
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
        static let snoozedUntil = "meetingDetection.snoozedUntil"
    }
}
