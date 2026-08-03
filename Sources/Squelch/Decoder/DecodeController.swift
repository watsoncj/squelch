import Foundation
#if os(macOS)
import AppKit
#endif
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
    /// Capture failed to start (no input device, engine error) — shown as
    /// a chip; statusText alone is invisible since the status bar retired.
    @Published var startError: String?
    /// Running but hearing nothing for a sustained stretch: wrong input
    /// device, dead USB cable, or radio volume at zero. Without this the
    /// symptom is just "no decodes", indistinguishable from a quiet band.
    @Published var inputSilent = false
    /// The input is slamming full scale — overdriven audio distorts and
    /// kills weak-signal decoding.
    @Published var inputClipping = false
    /// FT8/FT4 decodes are piling into one narrow slice of audio — the
    /// signature of a narrow IF filter (a healthy band spreads decodes
    /// across ~200–2800 Hz). Found the hard way: an FT-891 whose data-mode
    /// WIDTH sat at minimum decoded only 750–1250 Hz all day and starved
    /// WSPR (1400–1600 Hz) completely. The observed 5th–95th percentile
    /// span is published so the warning can show it.
    @Published var narrowFilterSpan: (lo: Int, hi: Int)?
    /// WSPR only: several consecutive slots contained strong WSPR-shaped
    /// sync structure yet nothing decoded. Real signals are arriving but
    /// something is mangling them — radio DSP (noise reduction, auto-notch,
    /// EQ) is the usual culprit. Discovered the hard way: an FT-891 with
    /// DNR enabled on data mode crushed local −4 dB beacons to nothing,
    /// silently, all day.
    @Published var wsprAudioSuspect = false

    /// Called on the main queue with each slot's decodes.
    var onSlotDecoded: (([FT8Result], Date) -> Void)?
    /// Raw 12 kHz mono samples, invoked on the audio thread — keep it light.
    var audioTap: (([Float]) -> Void)?

    private let capture = AudioCapture()
    private let decodeQueue = DispatchQueue(label: "squelch.ft8.decode", qos: .userInitiated)
    private var decoder: FT8Decoder? // confined to decodeQueue
    private var timer: DispatchSourceTimer?

    private let bufferLock = NSLock()
    private var sampleBuffer: [Float] = []

    /// Mode is latched at start; switching modes requires stop/start.
    private(set) var mode: DigiMode = .ft8
    private var slotSeconds: Double { mode.slotSeconds }
    private var maxBufferedSamples: Int { Int((slotSeconds + 1) * Double(FT8Decoder.sampleRate)) }
    /// Decode partial slots — audio can glitch briefly around our own
    /// TX/RX turnaround, and half a slot still decodes most signals.
    /// WSPR needs nearly the whole 110.6 s transmission.
    private var minDecodableSamples: Int {
        let factor = mode == .wspr ? 0.9 : 0.5
        return Int(factor * slotSeconds * Double(FT8Decoder.sampleRate))
    }

    private var lastLevelUpdate = Date.distantPast
    /// Silence detection: above this is "real audio" (Digirig band noise
    /// sits far higher; digital silence/zeros sit at -80).
    private static let audibleFloorDB: Float = -70
    private static let silentAfterSeconds: TimeInterval = 10
    private var lastAudibleAt = Date.distantPast

    // Clipping: sustained (not one static pop), self-clearing
    private var clippedLevelWindows = 0
    private var cleanLevelWindows = 0

    // Rolling audio frequencies of recent FT8/FT4 decodes (filter diagnosis)
    private var recentDecodeFreqs: [Float] = []

    // "Strong sync but no decodes" streak across WSPR slots
    private var wsprStrongUnverifiedSlots = 0
    /// Real WSPR structure scores ≥ 2 even below the decode floor; noise
    /// candidates stay near the 1.1 gate.
    private static let wsprStrongSyncThreshold: Float = 1.8
    private static let wsprSuspectAfterSlots = 3

    /// Held while capture is live so the Mac doesn't idle-sleep mid-session
    /// (the display may still sleep; decoding continues). Lid-close sleep is
    /// not overridden.
    private var sleepAssertion: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    #if os(macOS)
    func start(device: AudioDevice?) {
        startAuthorized { $0.beginCapture(device: device) }
    }
    #else
    func start() {
        startAuthorized { $0.beginCapture() }
    }
    #endif

    private func startAuthorized(_ begin: @escaping (DecodeController) -> Void) {
        guard !isRunning else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin(self)
        case .notDetermined:
            statusText = "Requesting microphone access…"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        begin(self)
                    } else {
                        self.micDenied = true
                        self.statusText = "Microphone access denied"
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
        #if os(macOS)
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        #endif
        bufferLock.lock()
        sampleBuffer.removeAll()
        bufferLock.unlock()
        isRunning = false
        statusText = "Stopped"
        audioLevelDB = -80
        inputSilent = false
        if let assertion = sleepAssertion {
            ProcessInfo.processInfo.endActivity(assertion)
            sleepAssertion = nil
        }
    }

    #if os(macOS)
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
            startError = error.localizedDescription
            return
        }
        deviceName = device?.name ?? "Default input"
        finishStart()
    }
    #else
    private func beginCapture() {
        mode = DigiMode.current
        decodeQueue.async { [weak self] in self?.decoder = nil } // rebuild for mode
        capture.onSamples = { [weak self] samples in
            self?.append(samples)
        }
        do {
            try capture.start()
        } catch {
            statusText = error.localizedDescription
            startError = error.localizedDescription
            return
        }
        deviceName = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "Default input"
        finishStart()
    }
    #endif

    private func finishStart() {
        isRunning = true
        micDenied = false // permission was fixed and Start succeeded
        startError = nil
        inputSilent = false
        inputClipping = false
        clippedLevelWindows = 0
        cleanLevelWindows = 0
        wsprAudioSuspect = false
        wsprStrongUnverifiedSlots = 0
        narrowFilterSpan = nil
        recentDecodeFreqs.removeAll()
        lastAudibleAt = Date()
        if sleepAssertion == nil {
            sleepAssertion = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "Decoding \(mode.rawValue) slots"
            )
        }
        statusText = "Listening (\(mode.rawValue)) — decoding at each \(String(format: "%g", mode.slotSeconds)) s slot boundary"
        scheduleSlotTimer()
        #if os(macOS)
        // Audio buffered before a sleep plus the gap across it would decode
        // as one garbage slot after waking; start the next slot clean.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.bufferLock.lock()
            self.sampleBuffer.removeAll(keepingCapacity: true)
            self.bufferLock.unlock()
            self.scheduleSlotTimer()
        }
        #endif
    }

    private func append(_ samples: [Float]) {
        audioTap?(samples)
        let cap = maxBufferedSamples
        bufferLock.lock()
        sampleBuffer.append(contentsOf: samples)
        if sampleBuffer.count > cap {
            sampleBuffer.removeFirst(sampleBuffer.count - cap)
        }
        bufferLock.unlock()

        // Throttled input level for the UI meter. Every publish invalidates
        // the whole SwiftUI window, so update sparingly and only on change.
        let now = Date()
        if now.timeIntervalSince(lastLevelUpdate) > 0.5, !samples.isEmpty {
            lastLevelUpdate = now
            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
            let db = max(-80, 20 * log10(max(rms, 1e-9)))
            if db > Self.audibleFloorDB {
                lastAudibleAt = now
            }
            let silent = now.timeIntervalSince(lastAudibleAt) > Self.silentAfterSeconds
            var peak: Float = 0
            vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
            if peak >= 0.985 {
                clippedLevelWindows += 1
                cleanLevelWindows = 0
            } else {
                cleanLevelWindows += 1
                if cleanLevelWindows >= 10 {
                    clippedLevelWindows = 0
                }
            }
            let clipping = clippedLevelWindows >= 3
            DispatchQueue.main.async {
                if abs(db - self.audioLevelDB) > 0.8 {
                    self.audioLevelDB = db
                }
                if silent != self.inputSilent {
                    self.inputSilent = silent
                }
                if clipping != self.inputClipping {
                    self.inputClipping = clipping
                }
            }
        }
    }

    private func scheduleSlotTimer() {
        timer?.cancel()
        let period = slotSeconds
        let t = DispatchSource.makeTimerSource(queue: decodeQueue)
        let now = Date().timeIntervalSince1970
        let untilNextSlot = period - now.truncatingRemainder(dividingBy: period)
        // Wall clock, not monotonic: slots are UTC-aligned, and a monotonic
        // deadline pauses across system sleep — every slot after a wake
        // would fire late by the slept time and decode misaligned windows.
        t.schedule(
            wallDeadline: .now() + untilNextSlot,
            repeating: period,
            leeway: .milliseconds(50)
        )
        t.setEventHandler { [weak self] in
            self?.processSlot()
        }
        t.resume()
        timer = t
    }

    /// A slot handler that starts well after its boundary snapshots a
    /// misaligned audio window (the ring buffer only holds ~one slot).
    /// Decoding that window can't succeed and — for WSPR — is exactly the
    /// slow-grind case, so one late slot would cascade into a permanent
    /// backlog on the serial queue. Near a full period late self-corrects:
    /// the buffer then holds the just-ended slot, correctly aligned.
    static func isMisaligned(now: TimeInterval, period: Double, tolerance: Double = 5) -> Bool {
        let sinceBoundary = now.truncatingRemainder(dividingBy: period)
        return sinceBoundary > tolerance && sinceBoundary < period - tolerance
    }

    /// Runs on decodeQueue at each slot boundary.
    private func processSlot() {
        let period = slotSeconds
        let now = Date().timeIntervalSince1970
        let boundary = (now / period).rounded() * period
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
        var wsprSlotSync: Float? // nil = no WSPR decode was attempted
        if slotSamples.count < minDecodableSamples || Self.isMisaligned(now: now, period: period) {
            results = []
        } else if mode == .wspr {
            let defaults = UserDefaults.standard
            let rcall = defaults.string(forKey: SettingsKeys.myCallsign) ?? ""
            let rgrid = String((defaults.string(forKey: SettingsKeys.myGrid) ?? "").prefix(4))
            let dialHz = Int(defaults.double(forKey: SettingsKeys.dialFrequencyMHz) * 1_000_000)
            let outcome = WSPRDecoderEngine
                .decodeSlotDetailed(slotSamples, rcall: rcall, rgrid: rgrid, dialHz: dialHz)
            wsprSlotSync = outcome.strongestSync
            results = outcome.spots.map { spot in
                FT8Result(
                    snr: spot.snr,
                    timeOffset: spot.dt,
                    freqHz: Float(spot.frequencyHz - Double(dialHz)),
                    text: "WSPR \(spot.call) \(spot.grid) \(spot.powerDBm)dBm"
                )
            }
        } else if let decoder {
            results = decoder.decodeSlot(slotSamples)
        } else {
            results = []
        }
        let isWSPR = mode == .wspr
        DispatchQueue.main.async {
            self.lastSlotCount = results.count
            if let sync = wsprSlotSync {
                self.noteWSPRSlot(spotCount: results.count, strongestSync: sync)
            }
            if !isWSPR {
                self.noteDecodedFrequencies(results.map(\.freqHz))
            }
            self.onSlotDecoded?(results, slotStart)
        }
    }

    /// Feed FT8/FT4 decode audio frequencies into the narrow-filter check:
    /// plenty of decodes all bunched into one thin slice means the radio's
    /// IF width is eating the rest of the passband.
    func noteDecodedFrequencies(_ freqs: [Float]) {
        recentDecodeFreqs.append(contentsOf: freqs)
        if recentDecodeFreqs.count > 200 {
            recentDecodeFreqs.removeFirst(recentDecodeFreqs.count - 200)
        }
        guard recentDecodeFreqs.count >= 40 else { return }
        let sorted = recentDecodeFreqs.sorted()
        let lo = sorted[Int(0.05 * Double(sorted.count))]
        let hi = sorted[max(0, Int(0.95 * Double(sorted.count)) - 1)]
        // Hysteresis so the chip doesn't flap at the boundary
        if hi - lo < 900 {
            narrowFilterSpan = (Int(lo), Int(hi))
        } else if hi - lo > 1200 {
            narrowFilterSpan = nil
        }
    }

    /// Track the "strong sync, zero decodes" streak that betrays mangled
    /// audio. Any decode — or the structure vanishing — clears it.
    func noteWSPRSlot(spotCount: Int, strongestSync: Float) {
        if spotCount > 0 || strongestSync < Self.wsprStrongSyncThreshold {
            wsprStrongUnverifiedSlots = 0
            wsprAudioSuspect = false
        } else {
            wsprStrongUnverifiedSlots += 1
            if wsprStrongUnverifiedSlots >= Self.wsprSuspectAfterSlots {
                wsprAudioSuspect = true
            }
        }
    }
}
