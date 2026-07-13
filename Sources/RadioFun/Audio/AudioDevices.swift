import Foundation
import CoreAudio

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// CoreAudio input-device enumeration.
enum AudioDevices {
    static func inputDevices() -> [AudioDevice] {
        devices(scope: kAudioDevicePropertyScopeInput)
    }

    static func outputDevices() -> [AudioDevice] {
        devices(scope: kAudioDevicePropertyScopeOutput)
    }

    private static func devices(scope: AudioObjectPropertyScope) -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }

        return ids.compactMap { id in
            guard channelCount(of: id, scope: scope) > 0 else { return nil }
            let name = stringProperty(of: id, selector: kAudioObjectPropertyName) ?? "Unknown device"
            let uid = stringProperty(of: id, selector: kAudioDevicePropertyDeviceUID) ?? String(id)
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    /// Best guess at the Digirig's sound card: its CM108/CM119 codec shows up
    /// as a generic "USB Audio Device" / "USB PnP Sound Device".
    static func likelyDigirig(in devices: [AudioDevice]) -> AudioDevice? {
        let keywords = ["digirig", "usb pnp", "usb audio", "cm108", "c-media"]
        return devices.first { device in
            let lower = device.name.lowercased()
            return keywords.contains { lower.contains($0) }
        }
    }

    private static func channelCount(of id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(of id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? (value as String) : nil
    }
}
