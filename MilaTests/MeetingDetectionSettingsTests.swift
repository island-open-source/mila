import XCTest
@testable import Mila

@MainActor
final class MeetingDetectionSettingsTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "MeetingDetectionSettingsTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func test_snooze_marks_bundle_id_as_snoozed_until_expiry() {
        var clock = Date()
        let s = MeetingDetectionSettings(defaults: freshDefaults(), now: { clock })

        XCTAssertFalse(s.isSnoozed(forBundleID: "us.zoom.xos"))
        s.snooze(bundleID: "us.zoom.xos")
        XCTAssertTrue(s.isSnoozed(forBundleID: "us.zoom.xos"))

        clock = clock.addingTimeInterval(MeetingDetectionSettings.snoozeDuration - 1)
        XCTAssertTrue(s.isSnoozed(forBundleID: "us.zoom.xos"),
                      "Still inside snooze window")

        clock = clock.addingTimeInterval(2)
        XCTAssertFalse(s.isSnoozed(forBundleID: "us.zoom.xos"),
                       "Past snooze deadline — re-arm allowed")
    }

    func test_snooze_persists_across_re_init_until_expiry() {
        let defaults = freshDefaults()
        var clock = Date()

        do {
            let s = MeetingDetectionSettings(defaults: defaults, now: { clock })
            s.snooze(bundleID: "us.zoom.xos")
        }

        // Reload with the same defaults — snooze should still apply.
        clock = clock.addingTimeInterval(30 * 60)
        let reloaded = MeetingDetectionSettings(defaults: defaults, now: { clock })
        XCTAssertTrue(reloaded.isSnoozed(forBundleID: "us.zoom.xos"))

        // Past expiry — re-init drops the stale entry.
        clock = clock.addingTimeInterval(60 * 60)
        let afterExpiry = MeetingDetectionSettings(defaults: defaults, now: { clock })
        XCTAssertFalse(afterExpiry.isSnoozed(forBundleID: "us.zoom.xos"))
        XCTAssertTrue(afterExpiry.snoozedUntil.isEmpty,
                      "Expired entries should be GC'd on init")
    }

    func test_snooze_empty_bundle_id_is_noop() {
        let s = MeetingDetectionSettings(defaults: freshDefaults())
        s.snooze(bundleID: "")
        XCTAssertTrue(s.snoozedUntil.isEmpty)
        XCTAssertFalse(s.isSnoozed(forBundleID: ""))
    }
}
