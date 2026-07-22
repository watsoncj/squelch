import Foundation
import CSerial

/// Yaesu FT-891 CAT protocol: ASCII commands terminated with ';' over the
/// radio's USB "Enhanced" serial port. Pure functions, testable without a
/// radio.
enum FT891CAT {
    static let readFrequency = "FA;"
    static let readMode = "MD0;"
    static let setDataUSB = "MD0C;"
    static let pttOn = "TX1;"
    static let pttOff = "TX0;"
    static let readPower = "PC;"

    /// "PC005;" → 5 (watts). Read-only by design: Squelch never writes the
    /// radio's power — the knob is the operator's.
    static func parsePowerResponse(_ response: String) -> Int? {
        guard response.hasPrefix("PC"), response.hasSuffix(";") else { return nil }
        let digits = response.dropFirst(2).dropLast()
        guard digits.count == 3, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// "FA014074000;" → 14.074
    static func parseFrequencyResponse(_ response: String) -> Double? {
        guard response.hasPrefix("FA"), response.hasSuffix(";") else { return nil }
        let digits = response.dropFirst(2).dropLast()
        guard digits.count == 9, digits.allSatisfy(\.isNumber), let hz = Double(digits) else { return nil }
        return hz / 1_000_000.0
    }

    /// 28.074 → "FA028074000;"
    static func setFrequencyCommand(mhz: Double) -> String {
        let hz = Int((mhz * 1_000_000.0).rounded())
        return String(format: "FA%09d;", hz)
    }

    /// "MD0C;" → "DATA-USB"
    static func parseModeResponse(_ response: String) -> String? {
        guard response.hasPrefix("MD0"), response.count >= 5, response.hasSuffix(";") else { return nil }
        let code = response[response.index(response.startIndex, offsetBy: 3)]
        return modeName(code)
    }

    static func modeName(_ code: Character) -> String {
        switch code {
        case "1": return "LSB"
        case "2": return "USB"
        case "3": return "CW-U"
        case "4": return "FM"
        case "5": return "AM"
        case "6": return "RTTY-L"
        case "7": return "CW-L"
        case "8": return "DATA-L"
        case "9": return "RTTY-U"
        case "A": return "FM-N"
        case "B": return "DATA-FM"
        case "C": return "DATA-USB"
        default: return "?"
        }
    }
}

/// Talks to the FT-891 over CAT: reads the VFO to keep the app's dial
/// setting in sync, and QSYs the radio when the user picks a frequency.
final class CATController: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var radioFrequencyMHz: Double?
    @Published private(set) var radioModeName: String?
    @Published private(set) var radioPowerWatts: Int?
    @Published var lastError: String?

    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "squelch.cat", qos: .utility)
    private var pollTimer: DispatchSourceTimer?
    private var pendingFrequencyMHz: Double? // QSY requested before connect finished
    private var retryWork: DispatchWorkItem?
    private var wantsConnection = false // false after explicit disconnect

    private func scheduleRetry() {
        guard wantsConnection else { return }
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.connect()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    var portPath: String {
        UserDefaults.standard.string(forKey: SettingsKeys.catPortPath) ?? ""
    }

    /// 0 = auto-detect. A successful probe caches the rate for the session
    /// so 30 s retries don't re-sweep.
    @Published private(set) var detectedBaud: Int?

    private var configuredBaud: Int {
        UserDefaults.standard.integer(forKey: SettingsKeys.catBaud)
    }

    /// Rates the FT-891 supports (menu 05-06), most common first.
    static let baudCandidates = [9600, 4800, 19200, 38400]

    /// The CAT port is usually the first of the FT-891's two serial ports
    /// (the "Enhanced" CP2105 interface).
    static func likelyCATPort(in ports: [String]) -> String? {
        ports.first { $0.lowercased().contains("usbserial") || $0.contains("SLAB") }
    }

    func connect() {
        wantsConnection = true
        let path = portPath
        guard !path.isEmpty, fd < 0 else { return }
        // Configured rate, or auto: cached detection first, then the sweep
        let rates: [Int]
        if configuredBaud > 0 {
            rates = [configuredBaud]
        } else if let cached = detectedBaud {
            rates = [cached] + Self.baudCandidates.filter { $0 != cached }
        } else {
            rates = Self.baudCandidates
        }
        queue.async { [weak self] in
            guard let self else { return }
            for rate in rates {
                let fd = cserial_open_cat(path, Int32(rate))
                if fd < 0 { continue }
                let reply = Self.transact(fd: fd, command: FT891CAT.readFrequency)
                if let mhz = reply.flatMap(FT891CAT.parseFrequencyResponse) {
                    DispatchQueue.main.async {
                        self.finishConnect(fd: fd, mhz: mhz, baud: rate)
                    }
                    return
                }
                cserial_close(fd)
            }
            DispatchQueue.main.async {
                self.lastError = rates.count == 1
                    ? "CAT: no response at \(rates[0]) baud — radio off? (retrying; check menu 05-06 CAT RATE)"
                    : "CAT: no response at any baud rate — radio off? (retrying every 30 s)"
                self.scheduleRetry()
            }
        }
    }

    private func finishConnect(fd: Int32, mhz: Double, baud: Int) {
        self.fd = fd
        detectedBaud = baud
        isConnected = true
        lastError = nil
        apply(frequency: mhz, mode: nil)
        startPolling()
        if let pending = pendingFrequencyMHz {
            pendingFrequencyMHz = nil
            setFrequency(mhz: pending)
        }
    }

    /// Explicit user disconnect (Settings button) also stops auto-retry.
    func disconnectManually() {
        wantsConnection = false
        retryWork?.cancel()
        retryWork = nil
        disconnect()
    }

    func disconnect() {
        pollTimer?.cancel()
        pollTimer = nil
        let oldFD = fd
        fd = -1
        isConnected = false
        radioFrequencyMHz = nil
        radioModeName = nil
        radioPowerWatts = nil
        if oldFD >= 0 {
            queue.async { cserial_close(oldFD) }
        }
    }

    /// Key/unkey via CAT (TX1;/TX0;). Fire-and-forget: no response wait, so
    /// keying latency is just the serial write (~15 ms at 9600). This is
    /// the DR-891's supported PTT path and works regardless of the radio's
    /// DATA PTT SELECT menu.
    func setPTT(_ keyed: Bool) {
        guard isConnected else { return }
        let fd = self.fd
        let command = keyed ? FT891CAT.pttOn : FT891CAT.pttOff
        queue.async {
            let bytes = Array(command.utf8).map { CChar(bitPattern: $0) }
            _ = cserial_write(fd, bytes, Int32(bytes.count))
        }
    }

    /// Ensure the radio is in DATA-USB (the mode our audio path requires).
    /// Called right before transmissions; no-op when already correct.
    func ensureDataUSB() {
        guard isConnected, radioModeName != "DATA-USB" else { return }
        let fd = self.fd
        queue.async { [weak self] in
            _ = Self.transact(fd: fd, command: FT891CAT.setDataUSB)
            self?.pollOnce()
        }
    }

    /// QSY the radio and put it in DATA-USB. If a connection attempt is in
    /// flight, the QSY is applied as soon as it succeeds.
    func setFrequency(mhz: Double) {
        guard isConnected else {
            pendingFrequencyMHz = mhz
            connect()
            return
        }
        let fd = self.fd
        queue.async { [weak self] in
            _ = Self.transact(fd: fd, command: FT891CAT.setFrequencyCommand(mhz: mhz))
            _ = Self.transact(fd: fd, command: FT891CAT.setDataUSB)
            self?.pollOnce()
        }
    }

    private func startPolling() {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.pollOnce() }
        timer.resume()
        pollTimer = timer
    }

    private func pollOnce() {
        let fd = self.fd
        guard fd >= 0 else { return }
        let freqReply = Self.transact(fd: fd, command: FT891CAT.readFrequency)
        let modeReply = Self.transact(fd: fd, command: FT891CAT.readMode)
        let powerReply = Self.transact(fd: fd, command: FT891CAT.readPower)
        let mhz = freqReply.flatMap(FT891CAT.parseFrequencyResponse)
        let mode = modeReply.flatMap(FT891CAT.parseModeResponse)
        let watts = powerReply.flatMap(FT891CAT.parsePowerResponse)
        DispatchQueue.main.async { [weak self] in
            self?.apply(frequency: mhz, mode: mode, powerWatts: watts)
        }
    }

    private func apply(frequency: Double?, mode: String?, powerWatts: Int? = nil) {
        if let frequency {
            radioFrequencyMHz = frequency
            // Keep the app's dial setting in lockstep with the radio
            UserDefaults.standard.set(frequency, forKey: SettingsKeys.dialFrequencyMHz)
        }
        if let mode {
            radioModeName = mode
        }
        if let powerWatts {
            radioPowerWatts = powerWatts
        }
    }

    /// Write a command and collect the reply up to the terminating ';'.
    private static func transact(fd: Int32, command: String) -> String? {
        guard fd >= 0 else { return nil }
        let bytes = Array(command.utf8).map { CChar(bitPattern: $0) }
        guard cserial_write(fd, bytes, Int32(bytes.count)) == bytes.count else { return nil }

        var response = ""
        var buf = [CChar](repeating: 0, count: 64)
        // Measured on the DR-891 passthrough: responses take ~250 ms and
        // arrive with per-byte pacing right after open — give them room
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let n = cserial_read(fd, &buf, Int32(buf.count), 100)
            if n < 0 { return nil }
            if n == 0 { continue }
            response += String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if response.contains(";") {
                return String(response.prefix(through: response.firstIndex(of: ";")!))
            }
        }
        return nil
    }

    deinit {
        pollTimer?.cancel()
        if fd >= 0 {
            cserial_close(fd)
        }
    }
}
