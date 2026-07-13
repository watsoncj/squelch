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

    /// Hard cap on a single keydown: an FT8 transmission is 12.64 s + lead.
    private static let watchdogSeconds: TimeInterval = 16
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
        guard let samples = FT8Encoder.encode(message: text, frequencyHz: offset) else {
            txError = "Cannot encode message “\(text)” as FT8"
            return false
        }
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
        currentTXText = text
        txError = nil
        armWatchdog(after: Self.watchdogSeconds)
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

    private var outputDeviceUID: String {
        UserDefaults.standard.string(forKey: SettingsKeys.audioOutputUID) ?? ""
    }
}
