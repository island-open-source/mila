import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

/// Thin wrapper around macOS power-management APIs. Two responsibilities:
///
///  1. Hold an `IOPMAssertion` of type `PreventUserIdleSystemSleep` while a
///     recording is in flight, so the Mac doesn't doze off mid-meeting when
///     the user steps away from the keyboard. The assertion is released the
///     moment the recording stops or the app quits — leaving one pinned
///     would block sleep indefinitely.
///
///  2. Tell callers whether the Mac is currently running on AC. macOS will
///     forcibly sleep on lid close when on battery regardless of any
///     assertion an app holds, so the UI uses this signal to warn the user
///     that closing the lid will still cut the recording short.
///
/// Not @MainActor: the assertion APIs are thread-safe and we want to be able
/// to release the assertion from teardown paths (app termination) without
/// hopping back to the main actor.
final class SleepGuard {
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var held = false

    /// Take the assertion if we don't already hold one. Idempotent — repeated
    /// calls while held are no-ops, so callers can call this at the start of
    /// every recording without tracking state themselves.
    func preventIdleSleep(reason: String) {
        guard !held else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            held = true
        } else {
            print("SleepGuard: failed to take power assertion (\(result))")
        }
    }

    /// Release the assertion. Safe to call when not held.
    func allowIdleSleep() {
        guard held else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        held = false
    }

    deinit {
        if held {
            IOPMAssertionRelease(assertionID)
        }
    }

    /// True when the Mac is plugged in (AC power), false on battery. Returns
    /// true on desktops (Mac mini / Studio / Pro) and any machine where the
    /// power source can't be determined — we'd rather not nag desktop users
    /// with a battery-only warning.
    static func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return true
        }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            // `Power Source State` is "AC Power", "Battery Power", or
            // "Off Line". We only treat explicit battery as off-AC.
            if let state = info[kIOPSPowerSourceStateKey] as? String,
               state == kIOPSBatteryPowerValue {
                return false
            }
        }
        return true
    }
}
