import XCTest
@testable import IslandWhisper

/// These tests run against the host machine's real Core Audio devices.
/// We can't assert specific hardware, so the assertions here verify that
/// the API is well-behaved (returns sensible data, doesn't crash).
final class AudioDeviceManagerTests: XCTestCase {

    func test_input_devices_returns_at_least_one_input() {
        let devices = AudioDeviceManager.inputDevices()
        XCTAssertFalse(devices.isEmpty,
                       "Expected the host to expose at least one audio input device")
        for device in devices {
            XCTAssertFalse(device.name.isEmpty)
            XCTAssertGreaterThan(device.id, 0)
        }
    }

    func test_preferred_device_is_a_real_input_or_nil() {
        let preferred = AudioDeviceManager.preferredInputDevice()
        guard let preferred else {
            // Acceptable on a machine without any physical inputs.
            return
        }
        let inputs = AudioDeviceManager.inputDevices()
        XCTAssertTrue(inputs.contains { $0.id == preferred.id },
                      "preferredInputDevice() returned a device not in inputDevices()")
    }

    func test_preferred_device_avoids_obvious_virtual_devices() {
        // The preferred device should never be one we recognise as virtual
        // (BlackHole, Loopback, Krisp, etc). If our host has only virtual
        // devices, the result is allowed to be one of them.
        let preferred = AudioDeviceManager.preferredInputDevice()
        let inputs = AudioDeviceManager.inputDevices()
        let nonVirtual = inputs.filter { !$0.isVirtual }
        if !nonVirtual.isEmpty {
            XCTAssertNotNil(preferred)
            XCTAssertEqual(preferred?.isVirtual, false,
                           "Preferred should be a real device when one exists")
        }
    }

    func test_device_struct_is_hashable_and_equatable() {
        let devices = AudioDeviceManager.inputDevices()
        guard let first = devices.first else { return }
        let copy = AudioDeviceManager.Device(id: first.id,
                                             uid: first.uid,
                                             name: first.name,
                                             manufacturer: first.manufacturer,
                                             isBuiltIn: first.isBuiltIn,
                                             isVirtual: first.isVirtual)
        XCTAssertEqual(first, copy)
        var set: Set<AudioDeviceManager.Device> = [first]
        set.insert(copy)
        XCTAssertEqual(set.count, 1)
    }
}
