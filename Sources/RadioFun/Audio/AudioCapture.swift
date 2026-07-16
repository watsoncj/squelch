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

    func start(deviceID: AudioDeviceID?) throws {
        stop()

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
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        outputFormat = nil
    }

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let outputFormat else { return }
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
