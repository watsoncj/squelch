import Foundation
import CSerial

/// Yaesu FT-891 CAT protocol: ASCII commands terminated with ';' over the
/// radio's USB "Enhanced" serial port. Pure functions, testable without a
/// radio.
enum FT891CAT {
    static let readFrequency = "FA;"
    static let readMode = "MD0;"
    static let setDataUSB = "MD0C;"

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
    @Published var lastError: String?

    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "radiofun.cat", qos: .utility)
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

    private var baud: Int {
        let b = UserDefaults.standard.integer(forKey: SettingsKeys.catBaud)
        return b > 0 ? b : 4800
    }

    /// The CAT port is usually the first of the FT-891's two serial ports
    /// (the "Enhanced" CP2105 interface).
    static func likelyCATPort(in ports: [String]) -> String? {
        ports.first { $0.lowercased().contains("usbserial") || $0.contains("SLAB") }
    }

    func connect() {
        wantsConnection = true
        let path = portPath
        guard !path.isEmpty, fd < 0 else { return }
        let baud = self.baud
        queue.async { [weak self] in
            guard let self else { return }
            let fd = cserial_open_cat(path, Int32(baud))
            DispatchQueue.main.async {
                if fd < 0 {
                    self.lastError = "CAT: cannot open \(path)"
                    return
                }
                self.fd = fd
                self.probe()
            }
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
        if oldFD >= 0 {
            queue.async { cserial_close(oldFD) }
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

    /// Confirm the radio is there, then poll the VFO every 2 s so the
    /// app's dial setting follows the physical knob.
    private func probe() {
        let fd = self.fd
        queue.async { [weak self] in
            let reply = Self.transact(fd: fd, command: FT891CAT.readFrequency)
            let mhz = reply.flatMap(FT891CAT.parseFrequencyResponse)
            DispatchQueue.main.async {
                guard let self else { return }
                if let mhz {
                    self.isConnected = true
                    self.lastError = nil
                    self.apply(frequency: mhz, mode: nil)
                    self.startPolling()
                    if let pending = self.pendingFrequencyMHz {
                        self.pendingFrequencyMHz = nil
                        self.setFrequency(mhz: pending)
                    }
                } else {
                    self.lastError = "CAT: no response — radio off? (retrying every 30 s; check menu 05-06 CAT RATE matches Settings)"
                    self.disconnect()
                    // The radio's USB bridge enumerates even with the radio
                    // powered off — keep retrying so CAT comes up on its
                    // own once the radio is switched on.
                    self.scheduleRetry()
                }
            }
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
        let mhz = freqReply.flatMap(FT891CAT.parseFrequencyResponse)
        let mode = modeReply.flatMap(FT891CAT.parseModeResponse)
        DispatchQueue.main.async { [weak self] in
            self?.apply(frequency: mhz, mode: mode)
        }
    }

    private func apply(frequency: Double?, mode: String?) {
        if let frequency {
            radioFrequencyMHz = frequency
            // Keep the app's dial setting in lockstep with the radio
            UserDefaults.standard.set(frequency, forKey: SettingsKeys.dialFrequencyMHz)
        }
        if let mode {
            radioModeName = mode
        }
    }

    /// Write a command and collect the reply up to the terminating ';'.
    private static func transact(fd: Int32, command: String) -> String? {
        guard fd >= 0 else { return nil }
        let bytes = Array(command.utf8).map { CChar(bitPattern: $0) }
        guard cserial_write(fd, bytes, Int32(bytes.count)) == bytes.count else { return nil }

        var response = ""
        var buf = [CChar](repeating: 0, count: 64)
        let deadline = Date().addingTimeInterval(0.5)
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
