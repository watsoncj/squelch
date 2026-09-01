import Foundation

/// Keys the radio and plays FT8 audio. Enforces the Technician-license
/// frequency guard and a hard PTT watchdog. All calls on the main queue.
final class TransmitController: ObservableObject {
    @Published private(set) var isTransmitting = false
    @Published private(set) var isTuning = false
    @Published private(set) var currentTXText = ""
    @Published var txError: String?
    /// Non-blocking heads-up (e.g. the TX output device was re-selected
    /// after a USB port change) — informational, TX proceeded.
    @Published var txNotice: String?

    private let audioOut = AudioOutput()
    private let ptt = SerialPTT()
    private var watchdog: DispatchWorkItem?

    /// Invoked as each transmission starts — wired to CAT's ensureDataUSB
    /// so a radio left in SSB/CW gets flipped back before the tones flow.
    var preTransmitHook: (() -> Void)?

    /// CAT-based PTT: returns true if it handled the keying (CAT
    /// connected). Preferred over serial RTS — it works regardless of the
    /// radio's DATA PTT SELECT menu. Falls back to RTS when unavailable.
    var catPTT: ((Bool) -> Bool)?
    private var keyedViaCAT = false

    init() {
        audioOut.onEngineLost = { [weak self] in
            guard let self, self.anyTXActive else { return }
            self.endTransmission()
            self.txError = "TX ended early: the audio output device changed mid-transmission"
        }
    }

    /// Tune gets longer for antenna-tuner work, but still force-drops.
    private static let tuneWatchdogSeconds: TimeInterval = 60

    /// Hard TX lock: data privileges of the license class set in Settings.
    static func isTXLegalMHz(_ mhz: Double, license: LicenseClass = .current) -> Bool {
        license.canTransmitData(mhz: mhz)
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

    /// Transmit pre-encoded audio (a JS8 frame). Same guards and watchdog
    /// as the FT8 path; the samples carry their own lead-in.
    @discardableResult
    func transmitRaw(samples: [Float], label: String) -> Bool {
        guard !anyTXActive else { return false }
        guard checkLegalAndConfigured() else { return false }
        return performTransmission(samples: samples, label: label)
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
            try audioOut.play(samples: samples, deviceUID: resolveOutputDeviceUID(), loop: false) { [weak self] in
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
            try audioOut.play(samples: oneSecond, deviceUID: resolveOutputDeviceUID(), loop: true)
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
        try? audioOut.warmUp(deviceUID: resolveOutputDeviceUID())
    }

    // MARK: - Internals

    private func checkLegalAndConfigured() -> Bool {
        let call = (UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !call.isEmpty else {
            txError = "TX blocked: set your callsign in Settings first"
            return false
        }
        let dial = UserDefaults.standard.double(forKey: SettingsKeys.dialFrequencyMHz)
        guard Self.isTXLegalMHz(dial) else {
            txError = LicenseClass.current == .unlicensed
                ? "TX blocked: license class is None (receive only)"
                : String(format: "TX blocked: %.3f MHz is outside %@ data privileges",
                         dial, LicenseClass.current.rawValue)
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
        if let catPTT, catPTT(true) {
            keyedViaCAT = true
            return true
        }
        keyedViaCAT = false
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
        if keyedViaCAT {
            _ = catPTT?(false)
            keyedViaCAT = false
            return
        }
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
    ///
    /// Stale UIDs are healed here rather than left to fail forever: a USB
    /// port move changes the UID, and split-duplex codecs (FT-991) give the
    /// RX input a UID that never appears among outputs. A recovered device
    /// is written back to Settings and announced via `txNotice`; if nothing
    /// plausible is connected, the stored UID passes through unchanged so
    /// AudioOutput throws the usual "device not found" error.
    private func resolveOutputDeviceUID() -> String {
        let defaults = UserDefaults.standard
        let explicit = defaults.string(forKey: SettingsKeys.audioOutputUID) ?? ""
        let input = defaults.string(forKey: SettingsKeys.audioDeviceUID) ?? ""
        guard let resolution = AudioDevices.resolveTXOutput(
            storedOutputUID: explicit,
            storedInputUID: input,
            outputs: AudioDevices.outputDevices(),
            inputs: AudioDevices.inputDevices()
        ) else {
            return explicit.isEmpty ? input : explicit
        }
        if resolution.healed {
            defaults.set(resolution.device.uid, forKey: SettingsKeys.audioOutputUID)
            txNotice = "TX output re-selected: \(resolution.device.name)"
        }
        return resolution.device.uid
    }
}
