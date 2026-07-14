import Foundation
import AVFoundation
import CoreAudio

/// Plays 12 kHz mono float samples out a chosen output device (the
/// Digirig's speaker side, which drives the radio's data input).
///
/// The engine is kept alive between transmissions: starting/stopping an
/// output engine on the same USB device the decoder is capturing from makes
/// CoreAudio reconfigure the device and glitches the input stream — which
/// silently corrupted the receive slot right after each transmission.
final class AudioOutput {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var currentDeviceUID: String?

    /// Play once; `completion` fires on the main queue when the buffer has
    /// been fully rendered. With `loop: true`, plays until `stop()`.
    func play(samples: [Float], deviceUID: String?, loop: Bool, completion: (() -> Void)? = nil) throws {
        guard !samples.isEmpty else { return }
        try prepareEngine(deviceUID: deviceUID)
        guard let player, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw AudioCaptureError.formatUnsupported
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        player.stop() // clear anything pending; engine keeps running
        if loop {
            player.scheduleBuffer(buffer, at: nil, options: .loops)
        } else {
            player.scheduleBuffer(buffer, at: nil, completionCallbackType: .dataRendered) { _ in
                DispatchQueue.main.async { completion?() }
            }
        }
        player.play()
    }

    /// End playback but leave the engine running (silent) so the shared
    /// USB device is not reconfigured between transmissions.
    func stop() {
        player?.stop()
    }

    /// Full teardown — device change or app shutdown.
    func shutdown() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        format = nil
        currentDeviceUID = nil
    }

    private func prepareEngine(deviceUID: String?) throws {
        if engine == nil || currentDeviceUID != deviceUID {
            shutdown()

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
            ) else {
                throw AudioCaptureError.formatUnsupported
            }
            engine.connect(player, to: engine.mainMixerNode, format: format)

            self.engine = engine
            self.player = player
            self.format = format
            self.currentDeviceUID = deviceUID
        }

        if let engine, !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    deinit {
        shutdown()
    }
}
