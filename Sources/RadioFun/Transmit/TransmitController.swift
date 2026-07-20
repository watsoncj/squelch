import Foundation

/// Keys the radio and plays FT8 audio. Enforces the Technician-license
/// frequency guard and a hard PTT watchdog. All calls on the main queue.
final class TransmitController: ObservableObject {
    @Published private(set) var isTransmitting = false
    @Published private(set) var isTuning = false
    @Published private(set) var currentTXText = ""
    @Published var txError: String?

    private let audioOut = AudioOutput()
    private let ptt = SerialPTT()
    private var watchdog: DispatchWorkItem?

    /// Invoked as each transmission starts — wired to CAT's ensureDataUSB
    /// so a radio left in SSB/CW gets flipped back before the tones flow.
    var preTransmitHook: (() -> Void)?

    init() {
        audioOut.onEngineLost = { [weak self] in
            guard let self, self.anyTXActive else { return }
            self.endTransmission()
            self.txError = "TX ended early: the audio output device changed mid-transmission"
        }
    }

    /// Tune gets longer for antenna-tuner work, but still force-drops.
    private static let tuneWatchdogSeconds: TimeInterval = 60

    /// Segments where a US Technician may transmit data/FT8.
    static func isTechLegalMHz(_ mhz: Double) -> Bool {
        (28.000...28.300).contains(mhz)   // 10 m data segment
            || (50.0...54.0).contains(mhz)    // 6 m
            || (144.0...148.0).contains(mhz)  // 2 m
            || (222.0...225.0).contains(mhz)  // 1.25 m
            || (420.0...450.0).contains(mhz)  // 70 cm
    }

    var anyTXActive: Bool { isTransmitting || isTuning }

    /// Transmit one FT8 message immediately (the encoded audio carries the
    /// standard 0.5 s lead-in; call this right at/after a slot boundary).
    @discardableResult
    func transmitNow(text: String) -> Bool {
        guard !anyTXActive else { return false }
        guard checkLegalAndConfigured() else { return false }

        let offset = txOffsetHz
        let mode = DigiMode.current
        guard let samples = FT8Encoder.encode(message: text, frequencyHz: offset, mode: mode) else {
            txError = "Cannot encode message “\(text)” as \(mode.rawValue)"
            return false
        }
        return performTransmission(samples: samples, label: text)
    }

    /// WSPR beacon: 110.6 s transmission at the given audio offset (the
    /// caller randomizes within the sub-band to spread beacons).
    @discardableResult
    func transmitWSPR(call: String, grid4: String, dbm: Int, offsetHz: Double) -> Bool {
        guard !anyTXActive else { return false }
        guard checkLegalAndConfigured() else { return false }
        guard let samples = WSPREncoder.encode(call: call, grid4: grid4, dbm: dbm, frequencyHz: offsetHz) else {
            txError = "Cannot encode WSPR message for \(call) \(grid4)"
            return false
        }
        return performTransmission(samples: samples, label: "WSPR \(call) \(grid4) \(dbm)dBm")
    }

    private func performTransmission(samples: [Float], label: String) -> Bool {
        preTransmitHook?()
        guard keyPTT() else { return false }

        do {
            try audioOut.play(samples: samples, deviceUID: outputDeviceUID, loop: false) { [weak self] in
                self?.endTransmission()
            }
        } catch {
            unkeyPTT()
            txError = error.localizedDescription
            return false
        }
        isTransmitting = true
        currentTXText = label
        txError = nil
        // AVAudioPlayerNode completion callbacks are unreliable across
        // stop/reschedule cycles — when one is dropped, only the watchdog
        // unkeys. End deterministically at the audio's actual duration.
        let duration = Double(samples.count) / Double(FT8Decoder.sampleRate)
        armWatchdog(after: duration + 0.35)
        return true
    }

    /// Steady tone at the TX offset for setting drive level / tuning.
    func startTune() {
        guard !anyTXActive else { return }
        guard checkLegalAndConfigured() else { return }

        let rate = Double(FT8Decoder.sampleRate)
        let omega = 2.0 * Double.pi * txOffsetHz / rate
        let oneSecond = (0..<Int(rate)).map { Float(sin(omega * Double($0))) }
        guard keyPTT() else { return }
        do {
            try audioOut.play(samples: oneSecond, deviceUID: outputDeviceUID, loop: true)
        } catch {
            unkeyPTT()
            txError = error.localizedDescription
            return
        }
        isTuning = true
        currentTXText = "TUNE"
        txError = nil
        armWatchdog(after: Self.tuneWatchdogSeconds)
    }

    func stopTune() {
        guard isTuning else { return }
        endTransmission()
    }

    /// Immediate halt of any transmission (panic button / app teardown).
    func haltAll() {
        endTransmission()
    }

    /// Best-effort: spin up the silent output engine ahead of any TX so its
    /// device reconfiguration doesn't disrupt receive mid-QSO. Never keys.
    func warmUp() {
        try? audioOut.warmUp(deviceUID: outputDeviceUID)
    }

    // MARK: - Internals

    private func checkLegalAndConfigured() -> Bool {
        let dial = UserDefaults.standard.double(forKey: SettingsKeys.dialFrequencyMHz)
        guard Self.isTechLegalMHz(dial) else {
            txError = String(
                format: "TX blocked: %.3f MHz is outside Technician data privileges (10 m: 28.000–28.300, or 50 MHz and up)",
                dial
            )
            return false
        }
        guard !pttPortPath.isEmpty else {
            txError = "TX blocked: no PTT serial port selected in Settings"
            return false
        }
        let offset = txOffsetHz
        guard (200.0...3000.0).contains(offset) else {
            txError = "TX blocked: audio offset must be 200–3000 Hz"
            return false
        }
        return true
    }

    private func keyPTT() -> Bool {
        do {
            try ptt.open(path: pttPortPath)
        } catch {
            txError = error.localizedDescription
            return false
        }
        ptt.key()
        return true
    }

    private func unkeyPTT() {
        ptt.unkey()
    }

    private func endTransmission() {
        watchdog?.cancel()
        watchdog = nil
        audioOut.stop()
        unkeyPTT()
        isTransmitting = false
        isTuning = false
        currentTXText = ""
    }

    private func armWatchdog(after seconds: TimeInterval) {
        watchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.endTransmission()
        }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private var txOffsetHz: Double {
        let v = UserDefaults.standard.double(forKey: SettingsKeys.txOffsetHz)
        return v > 0 ? v : 1500
    }

    private var pttPortPath: String {
        UserDefaults.standard.string(forKey: SettingsKeys.pttPortPath) ?? ""
    }

    /// Explicit TX output selection, falling back to the same device as the
    /// RX input (the Digirig carries both sides) — never the system default,
    /// so TX audio can't end up on the Mac speakers.
    private var outputDeviceUID: String {
        let explicit = UserDefaults.standard.string(forKey: SettingsKeys.audioOutputUID) ?? ""
        if !explicit.isEmpty { return explicit }
        return UserDefaults.standard.string(forKey: SettingsKeys.audioDeviceUID) ?? ""
    }
}
