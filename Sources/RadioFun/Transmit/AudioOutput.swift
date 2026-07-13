import Foundation
import AVFoundation
import CoreAudio

/// Plays 12 kHz mono float samples out a chosen output device (the
/// Digirig's speaker side, which drives the radio's data input).
final class AudioOutput {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    /// Play once; `completion` fires on the main queue when the buffer has
    /// been fully rendered. With `loop: true`, plays until `stop()`.
    func play(samples: [Float], deviceUID: String?, loop: Bool, completion: (() -> Void)? = nil) throws {
        stop()
        guard !samples.isEmpty else { return }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        if let deviceUID, !deviceUID.isEmpty,
           let device = AudioDevices.outputDevices().first(where: { $0.uid == deviceUID }) {
            guard let audioUnit = engine.outputNode.audioUnit else {
                throw AudioCaptureError.formatUnsupported
            }
            var id = device.id
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw AudioCaptureError.deviceSelectionFailed(status) }
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(FT8Decoder.sampleRate),
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw AudioCaptureError.formatUnsupported
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()

        if loop {
            player.scheduleBuffer(buffer, at: nil, options: .loops)
        } else {
            player.scheduleBuffer(buffer, at: nil, completionCallbackType: .dataRendered) { _ in
                DispatchQueue.main.async { completion?() }
            }
        }
        player.play()

        self.engine = engine
        self.player = player
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }
}
