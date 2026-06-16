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

    func test_enabled_defaults_on_for_first_launch() {
        let s = MeetingDetectionSettings(defaults: freshDefaults())
        XCTAssertTrue(s.enabled, "Detection should default ON so users discover it")
    }

    func test_disable_then_reenable_bundle_id() {
        let s = MeetingDetectionSettings(defaults: freshDefaults())
        XCTAssertFalse(s.isDisabled(forBundleID: "us.zoom.xos"))

        s.disable(bundleID: "us.zoom.xos")
        XCTAssertTrue(s.isDisabled(forBundleID: "us.zoom.xos"))

        s.reenable(bundleID: "us.zoom.xos")
        XCTAssertFalse(s.isDisabled(forBundleID: "us.zoom.xos"))
    }

    func test_disabled_bundle_ids_persist_across_re_init() {
        let defaults = freshDefaults()
        do {
            let s = MeetingDetectionSettings(defaults: defaults)
            s.disable(bundleID: "us.zoom.xos")
        }
        let reloaded = MeetingDetectionSettings(defaults: defaults)
        XCTAssertTrue(reloaded.isDisabled(forBundleID: "us.zoom.xos"),
                      "Silenced apps should survive a relaunch")
    }

    func test_disable_empty_bundle_id_is_noop() {
        let s = MeetingDetectionSettings(defaults: freshDefaults())
        s.disable(bundleID: "")
        XCTAssertFalse(s.isDisabled(forBundleID: ""))
        XCTAssertTrue(s.disabledBundleIDs.isEmpty)
    }
}
