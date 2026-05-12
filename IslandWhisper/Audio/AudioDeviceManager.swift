import Foundation
import CoreAudio
import AVFoundation
import AudioToolbox

/// Helpers for enumerating Core Audio input devices and forcing
/// `AVAudioEngine` to use a specific one (instead of the system default,
/// which can be a virtual loopback like BlackHole / Existential Audio).
enum AudioDeviceManager {

    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        /// Stable identifier (kAudioDevicePropertyDeviceUID). AudioDeviceID is
        /// reassigned on every plug/unplug, so it's unsafe to persist; the UID
        /// is what we save when the user pins an input in Settings.
        let uid: String
        let name: String
        let manufacturer: String
        let isBuiltIn: Bool
        let isVirtual: Bool
    }

    /// All hardware devices that expose at least one input channel.
    static func inputDevices() -> [Device] {
        var devices: [Device] = []
        for deviceID in allDeviceIDs() {
            guard let info = info(for: deviceID), info.inputChannels > 0 else { continue }
            devices.append(Device(
                id: deviceID,
                uid: info.uid,
                name: info.name,
                manufacturer: info.manufacturer,
                isBuiltIn: info.isBuiltIn,
                isVirtual: info.isVirtual
            ))
        }
        return devices
    }

    /// Look up a device by its stable UID (kAudioDevicePropertyDeviceUID).
    /// Returns nil if no current input matches — the device may have been
    /// unplugged since the user last picked it in Settings.
    static func device(uid: String) -> Device? {
        inputDevices().first(where: { $0.uid == uid })
    }

    /// Best guess for the user's actual microphone:
    /// 0. If `preferredUID` is given and matches a connected input, use it.
    /// 1. The current system default input — but only if it's not a virtual device.
    /// 2. Otherwise, the built-in MacBook microphone if present.
    /// 3. Otherwise, the first non-virtual physical input device.
    /// Returns `nil` to mean "fall back to AVAudioEngine's default behavior".
    static func preferredInputDevice(preferredUID: String? = nil) -> Device? {
        let inputs = inputDevices()
        if let preferredUID, let pinned = inputs.first(where: { $0.uid == preferredUID }) {
            return pinned
        }
        let defaultID = systemDefaultInputDeviceID()
        if let def = inputs.first(where: { $0.id == defaultID }), !def.isVirtual {
            return def
        }
        if let builtIn = inputs.first(where: { $0.isBuiltIn }) { return builtIn }
        return inputs.first(where: { !$0.isVirtual })
    }

    /// Force an existing `AVAudioEngine`'s input node to read from the given device.
    /// Must be called before `engine.start()` and *after* touching `engine.inputNode`.
    static func setInputDevice(_ device: Device, on engine: AVAudioEngine) throws {
        guard let unit = engine.inputNode.audioUnit else {
            throw NSError(domain: "AudioDeviceManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Engine has no input audio unit."])
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    // MARK: - Internal Core Audio helpers

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                              &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                 &address, 0, nil, &size, &ids)
        return status == noErr ? ids : []
    }

    private static func systemDefaultInputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                    &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    private struct DeviceInfo {
        let uid: String
        let name: String
        let manufacturer: String
        let inputChannels: Int
        let isBuiltIn: Bool
        let isVirtual: Bool
    }

    private static func info(for deviceID: AudioDeviceID) -> DeviceInfo? {
        let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID) ?? ""
        let name = stringProperty(deviceID, kAudioDevicePropertyDeviceNameCFString) ?? ""
        let manufacturer = stringProperty(deviceID, kAudioDevicePropertyDeviceManufacturerCFString) ?? ""
        let transport = uint32Property(deviceID, kAudioDevicePropertyTransportType) ?? 0
        let inputChannels = inputChannelCount(deviceID)
        let isBuiltIn = (transport == kAudioDeviceTransportTypeBuiltIn)
        let isVirtual = (transport == kAudioDeviceTransportTypeVirtual
                         || transport == kAudioDeviceTransportTypeAggregate
                         || isKnownVirtualVendor(name: name, manufacturer: manufacturer))
        return DeviceInfo(uid: uid,
                          name: name,
                          manufacturer: manufacturer,
                          inputChannels: inputChannels,
                          isBuiltIn: isBuiltIn,
                          isVirtual: isVirtual)
    }

    private static func isKnownVirtualVendor(name: String, manufacturer: String) -> Bool {
        let n = (name + " " + manufacturer).lowercased()
        return n.contains("blackhole")
            || n.contains("existential audio")
            || n.contains("soundflower")
            || n.contains("loopback")
            || n.contains("zoom audio")
            || n.contains("microsoft teams audio")
            || n.contains("krisp")
            || n.contains("ivrit") // our own future virtual device, if any
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw)
        guard status == noErr else { return 0 }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let list = UnsafeMutableAudioBufferListPointer(abl)
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfStr)
        guard status == noErr, let cf = cfStr else { return nil }
        let value = cf.takeRetainedValue() as String
        return value
    }

    private static func uint32Property(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }
}
