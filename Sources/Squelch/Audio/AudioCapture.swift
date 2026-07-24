import Foundation
import AVFoundation
import CoreAudio

enum AudioCaptureError: LocalizedError {
    case noInputAvailable
    case deviceSelectionFailed(OSStatus)
    case formatUnsupported
    case outputDeviceUnavailable
    case outputRoutingFailed

    var errorDescription: String? {
        switch self {
        case .noInputAvailable: return "No audio input available. Is the Digirig plugged in?"
        case .deviceSelectionFailed(let status): return "Could not select the audio device (CoreAudio error \(status))."
        case .formatUnsupported: return "The audio device's format is not supported."
        case .outputDeviceUnavailable: return "TX blocked: the selected TX audio output device was not found — check Settings → Transmit."
        case .outputRoutingFailed: return "TX blocked: macOS bound the TX audio to the wrong output device — check Settings → Transmit and try again."
        }
    }
}

/// Captures audio from a chosen input device and delivers 12 kHz mono
/// Float32 samples via `onSamples` (called on an audio thread).
final class AudioCapture {
    var onSamples: (([Float]) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var configObserver: NSObjectProtocol?
    private var currentDeviceID: AudioDeviceID?
    /// One rebuild request per drift detection — the tap fires ~12×/s and
    /// must not queue a rebuild storm while the first one is in flight.
    private var rebuildRequested = false

    func start(deviceID: AudioDeviceID?) throws {
        stop()
        currentDeviceID = deviceID
        rebuildRequested = false

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode

        if let deviceID {
            guard let audioUnit = input.audioUnit else { throw AudioCaptureError.noInputAvailable }
            var device = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &device,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw AudioCaptureError.deviceSelectionFailed(status) }
        }

        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputAvailable
        }
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(FT8Decoder.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw AudioCaptureError.formatUnsupported
        }
        self.converter = converter
        self.outputFormat = outFormat

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }

        engine.prepare()
        try engine.start()

        // CoreAudio stops the engine on device configuration changes —
        // including the FIRST start of the TX output engine on the same
        // Digirig. Without this restart, receive dies silently mid-QSO.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigChange(attempt: 1)
        }
    }

    private func restartAfterConfigChange(attempt: Int) {
        // Trust a self-recovered engine only if it's still bound to our
        // device in our format — recovery can silently rebind the input to
        // the system default (internal mic), which keeps audio flowing but
        // feeds the decoder room noise (waterfall collapses to low-end
        // rumble, spots stop).
        if let engine, engine.isRunning, inputBindingIntact(engine) { return }
        guard currentDeviceID != nil || engine != nil || attempt > 1 else { return }
        // Full rebuild, not restart-in-place: after a device configuration
        // change (AirPods connecting, etc.) a restarted engine can silently
        // rebind to the new system default instead of our explicit device.
        let device = currentDeviceID
        let callback = onSamples
        stop()
        onSamples = callback
        do {
            try start(deviceID: device)
        } catch {
            guard attempt < 3 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restartAfterConfigChange(attempt: attempt + 1)
            }
        }
    }

    private func inputBindingIntact(_ engine: AVAudioEngine) -> Bool {
        if let deviceID = currentDeviceID {
            guard let unit = engine.inputNode.audioUnit else { return false }
            var bound = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitGetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &bound,
                &size
            )
            guard status == noErr, bound == deviceID else { return false }
        }
        guard let converter else { return false }
        let format = engine.inputNode.inputFormat(forBus: 0)
        return format.sampleRate == converter.inputFormat.sampleRate
            && format.channelCount == converter.inputFormat.channelCount
    }

    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        outputFormat = nil
    }

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let outputFormat else { return }
        // Format drift can arrive with no configuration-change notification;
        // converting through a stale converter mislabels the sample rate and
        // shifts every signal's apparent frequency. Rebuild instead.
        if buffer.format.sampleRate != converter.inputFormat.sampleRate
            || buffer.format.channelCount != converter.inputFormat.channelCount {
            if !rebuildRequested {
                rebuildRequested = true
                DispatchQueue.main.async { [weak self] in
                    self?.restartAfterConfigChange(attempt: 1)
                }
            }
            return
        }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        onSamples?(samples)
    }
}
