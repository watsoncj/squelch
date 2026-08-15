import Foundation
import CoreAudio

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// A TX output device resolved from persisted settings. `healed` means the
/// stored UID didn't match directly and the recovered device should be
/// written back to settings and surfaced to the user.
struct TXOutputResolution: Equatable {
    let device: AudioDevice
    let healed: Bool
}

/// CoreAudio device enumeration.
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

    /// Resolve which output device TX audio should use, healing stale or
    /// mismatched UIDs. macOS USB audio UIDs embed the USB location ID, so
    /// moving the interface to a different port invalidates a persisted UID.
    /// Split-duplex codecs (the FT-991's PCM2903) enumerate input and output
    /// as separate CoreAudio devices with different UIDs, so the RX-input
    /// fallback UID may never appear among the outputs.
    ///
    /// Returns nil only when nothing plausible is connected — callers must
    /// then fail rather than fall through to the system default.
    static func resolveTXOutput(
        storedOutputUID: String,
        storedInputUID: String,
        outputs: [AudioDevice],
        inputs: [AudioDevice]
    ) -> TXOutputResolution? {
        if !storedOutputUID.isEmpty {
            if let exact = outputs.first(where: { $0.uid == storedOutputUID }) {
                return TXOutputResolution(device: exact, healed: false)
            }
            let norm = normalizedUID(storedOutputUID)
            if !norm.isEmpty, let moved = outputs.first(where: { normalizedUID($0.uid) == norm }) {
                return TXOutputResolution(device: moved, healed: true)
            }
        } else if !storedInputUID.isEmpty {
            // Duplex codec (Digirig CM108): one device carries both sides
            if let exact = outputs.first(where: { $0.uid == storedInputUID }) {
                return TXOutputResolution(device: exact, healed: false)
            }
            // Split-duplex codec: the output sibling shares the input's name
            if let input = inputs.first(where: { $0.uid == storedInputUID }),
               let sibling = outputs.first(where: { $0.name == input.name }) {
                return TXOutputResolution(device: sibling, healed: true)
            }
            // Input device gone too (port move) — match on stable identity
            let norm = normalizedUID(storedInputUID)
            if !norm.isEmpty, let sibling = outputs.first(where: { normalizedUID($0.uid) == norm }) {
                return TXOutputResolution(device: sibling, healed: true)
            }
        }
        if let guess = likelyDigirig(in: outputs) {
            return TXOutputResolution(device: guess, healed: true)
        }
        return nil
    }

    /// UID with the volatile numeric segments (USB location ID, engine
    /// index) removed — the stable identity of a device model across port
    /// moves and across a split-duplex codec's input/output pair.
    static func normalizedUID(_ uid: String) -> String {
        uid.split(separator: ":")
            .filter { segment in
                let isNumericID = segment.allSatisfy(\.isHexDigit) && segment.contains(where: \.isNumber)
                return !isNumericID
            }
            .joined(separator: ":")
            .lowercased()
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
