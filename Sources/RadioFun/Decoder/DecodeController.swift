import Foundation
import AVFoundation
import Accelerate

/// Runs the receive pipeline: audio capture → 15 s slot buffer → FT8 decode.
/// FT8 slots start at :00/:15/:30/:45 UTC; a timer aligned to those
/// boundaries snapshots the accumulated audio and decodes it off-main.
final class DecodeController: ObservableObject {
    @Published var isRunning = false
    @Published var statusText = "Stopped"
    @Published var deviceName = ""
    @Published var audioLevelDB: Float = -80
    @Published var lastSlotCount: Int?
    @Published var micDenied = false

    /// Called on the main queue with each slot's decodes.
    var onSlotDecoded: (([FT8Result], Date) -> Void)?

    private let capture = AudioCapture()
    private let decodeQueue = DispatchQueue(label: "radiofun.ft8.decode", qos: .userInitiated)
    private var decoder: FT8Decoder? // confined to decodeQueue
    private var timer: DispatchSourceTimer?

    private let bufferLock = NSLock()
    private var sampleBuffer: [Float] = []

    /// Mode is latched at start; switching FT8↔FT4 requires stop/start.
    private(set) var mode: DigiMode = .ft8
    private var slotSeconds: Double { mode.slotSeconds }
    private var maxBufferedSamples: Int { Int((slotSeconds + 1) * Double(FT8Decoder.sampleRate)) }
    /// Decode partial slots — audio can glitch briefly around our own
    /// TX/RX turnaround, and half a slot still decodes most signals.
    private var minDecodableSamples: Int { Int(0.5 * slotSeconds * Double(FT8Decoder.sampleRate)) }

    private var lastLevelUpdate = Date.distantPast

    func start(device: AudioDevice?) {
        guard !isRunning else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginCapture(device: device)
        case .notDetermined:
            statusText = "Requesting microphone access…"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.beginCapture(device: device)
                    } else {
                        self?.micDenied = true
                        self?.statusText = "Microphone access denied"
                    }
                }
            }
        default:
            micDenied = true
            statusText = "Microphone access denied — enable it in System Settings → Privacy & Security → Microphone"
        }
    }

    func stop() {
        capture.stop()
        timer?.cancel()
        timer = nil
        bufferLock.lock()
        sampleBuffer.removeAll()
        bufferLock.unlock()
        isRunning = false
        statusText = "Stopped"
        audioLevelDB = -80
    }

    private func beginCapture(device: AudioDevice?) {
        mode = DigiMode.current
        decodeQueue.async { [weak self] in self?.decoder = nil } // rebuild for mode
        capture.onSamples = { [weak self] samples in
            self?.append(samples)
        }
        do {
            try capture.start(deviceID: device?.id)
        } catch {
            statusText = error.localizedDescription
            return
        }
        deviceName = device?.name ?? "Default input"
        isRunning = true
        statusText = "Listening (\(mode.rawValue)) — decoding at each \(mode == .ft8 ? "15" : "7.5") s slot boundary"
        scheduleSlotTimer()
    }

    private func append(_ samples: [Float]) {
        let cap = maxBufferedSamples
        bufferLock.lock()
        sampleBuffer.append(contentsOf: samples)
        if sampleBuffer.count > cap {
            sampleBuffer.removeFirst(sampleBuffer.count - cap)
        }
        bufferLock.unlock()

        // Throttled input level for the UI meter
        let now = Date()
        if now.timeIntervalSince(lastLevelUpdate) > 0.25, !samples.isEmpty {
            lastLevelUpdate = now
            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
            let db = max(-80, 20 * log10(max(rms, 1e-9)))
            DispatchQueue.main.async { self.audioLevelDB = db }
        }
    }

    private func scheduleSlotTimer() {
        timer?.cancel()
        let period = slotSeconds
        let t = DispatchSource.makeTimerSource(queue: decodeQueue)
        let now = Date().timeIntervalSince1970
        let untilNextSlot = period - now.truncatingRemainder(dividingBy: period)
        t.schedule(
            deadline: .now() + untilNextSlot,
            repeating: period,
            leeway: .milliseconds(50)
        )
        t.setEventHandler { [weak self] in
            self?.processSlot()
        }
        t.resume()
        timer = t
    }

    /// Runs on decodeQueue at each slot boundary.
    private func processSlot() {
        let period = slotSeconds
        let boundary = (Date().timeIntervalSince1970 / period).rounded() * period
        let slotStart = Date(timeIntervalSince1970: boundary - period)

        bufferLock.lock()
        let slotSamples = sampleBuffer
        sampleBuffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()

        if decoder == nil {
            decoder = FT8Decoder(mode: mode)
        }

        // Always report the slot — even empty — so the QSO sequencer keeps
        // getting its transmit windows when a slot's audio is unusable.
        let results: [FT8Result]
        if slotSamples.count >= minDecodableSamples, let decoder {
            results = decoder.decodeSlot(slotSamples)
        } else {
            results = []
        }
        DispatchQueue.main.async {
            self.lastSlotCount = results.count
            self.onSlotDecoded?(results, slotStart)
        }
    }
}
