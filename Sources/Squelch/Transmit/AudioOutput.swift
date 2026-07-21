import Foundation
import AudioToolbox
import CoreAudio

/// Plays 12 kHz mono float samples out a chosen output device (the
/// Digirig's speaker side, which drives the radio's data input).
///
/// Implemented directly on a HAL output AudioUnit pinned to the device.
/// AVAudioEngine's device binding proved untrustworthy: engines restarted
/// after configuration changes (AirPods connecting) silently rebind to the
/// system default, and the readback used for verification echoes the set
/// value rather than the actual route. A HAL unit bound to a specific
/// AudioDeviceID cannot follow the default device.
final class AudioOutput {
    /// Fired when playback dies mid-stream (device removed) — the
    /// transmitter should unkey rather than send dead carrier.
    var onEngineLost: (() -> Void)?

    private var unit: AudioComponentInstance?
    private var currentDeviceUID: String?
    private var boundDeviceID: AudioDeviceID = 0

    private let lock = NSLock()
    private var samples: [Float] = []
    private var cursor = 0
    private var looping = false
    private var finished = true
    private var completion: (() -> Void)?

    // MARK: - Public API (unchanged shape)

    func play(samples newSamples: [Float], deviceUID: String?, loop: Bool, completion newCompletion: (() -> Void)? = nil) throws {
        guard !newSamples.isEmpty else { return }
        try prepareUnit(deviceUID: deviceUID)

        lock.lock()
        samples = newSamples
        cursor = 0
        looping = loop
        finished = false
        completion = newCompletion
        lock.unlock()

        guard let unit else { throw AudioCaptureError.formatUnsupported }
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            throw AudioCaptureError.deviceSelectionFailed(status)
        }
    }

    func warmUp(deviceUID: String?) throws {
        try prepareUnit(deviceUID: deviceUID)
    }

    /// End playback; the unit stays initialized and device-bound.
    func stop() {
        lock.lock()
        finished = true
        completion = nil
        lock.unlock()
        if let unit {
            AudioOutputUnitStop(unit)
        }
    }

    func shutdown() {
        stop()
        if let unit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        currentDeviceUID = nil
        boundDeviceID = 0
    }

    deinit {
        shutdown()
    }

    // MARK: - HAL unit

    private func prepareUnit(deviceUID: String?) throws {
        if unit != nil, currentDeviceUID == deviceUID {
            // Re-verify the binding is still what we set — device lists
            // change under us and silence beats misroute
            if boundDeviceID != 0, readBackDevice() == boundDeviceID {
                return
            }
            shutdown()
        } else if unit != nil {
            shutdown()
        }

        var targetDevice: AudioDeviceID = 0
        if let deviceUID, !deviceUID.isEmpty {
            guard let device = AudioDevices.outputDevices().first(where: { $0.uid == deviceUID }) else {
                throw AudioCaptureError.outputDeviceUnavailable
            }
            targetDevice = device.id
        }

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioCaptureError.formatUnsupported
        }
        var newUnit: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &newUnit) == noErr, let halUnit = newUnit else {
            throw AudioCaptureError.formatUnsupported
        }

        if targetDevice != 0 {
            var device = targetDevice
            let status = AudioUnitSetProperty(
                halUnit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &device, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                AudioComponentInstanceDispose(halUnit)
                throw AudioCaptureError.deviceSelectionFailed(status)
            }
        }

        // Client-side format: our 12 kHz mono float; the HAL unit converts
        // to the device's native format
        var format = AudioStreamBasicDescription(
            mSampleRate: Float64(FT8Decoder.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard AudioUnitSetProperty(
            halUnit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0,
            &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ) == noErr else {
            AudioComponentInstanceDispose(halUnit)
            throw AudioCaptureError.formatUnsupported
        }

        var callback = AURenderCallbackStruct(
            inputProc: audioOutputRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        guard AudioUnitSetProperty(
            halUnit, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ) == noErr, AudioUnitInitialize(halUnit) == noErr else {
            AudioComponentInstanceDispose(halUnit)
            throw AudioCaptureError.formatUnsupported
        }

        unit = halUnit
        currentDeviceUID = deviceUID
        boundDeviceID = targetDevice

        // Verify against the initialized unit: the actual bound device
        if targetDevice != 0, readBackDevice() != targetDevice {
            shutdown()
            throw AudioCaptureError.outputRoutingFailed
        }
    }

    private func readBackDevice() -> AudioDeviceID {
        guard let unit else { return 0 }
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &device, &size
        )
        return status == noErr ? device : 0
    }

    // MARK: - Render (audio thread)

    fileprivate func render(frames: UInt32, into buffer: UnsafeMutablePointer<Float>) {
        lock.lock()
        defer { lock.unlock() }

        var out = 0
        let total = Int(frames)
        if !finished {
            while out < total {
                if cursor >= samples.count {
                    if looping {
                        cursor = 0
                    } else {
                        finished = true
                        if let done = completion {
                            completion = nil
                            DispatchQueue.main.async { done() }
                        }
                        break
                    }
                }
                buffer[out] = samples[cursor]
                out += 1
                cursor += 1
            }
        }
        while out < total {
            buffer[out] = 0
            out += 1
        }
    }
}

private func audioOutputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData else { return noErr }
    let output = Unmanaged<AudioOutput>.fromOpaque(inRefCon).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    guard let first = buffers.first, let data = first.mData else { return noErr }
    output.render(frames: inNumberFrames, into: data.assumingMemoryBound(to: Float.self))
    // Mirror into any additional buffers (non-interleaved stereo devices)
    for extra in buffers.dropFirst() {
        if let dst = extra.mData {
            memcpy(dst, data, Int(first.mDataByteSize))
        }
    }
    return noErr
}
