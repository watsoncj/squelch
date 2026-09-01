import Foundation

/// The directed-command table. Strings carry their leading space (except
/// "?" and ">"); `canonical` is what a receiver renders.
struct JS8Command: Equatable {
    let code: Int
    let strings: [String]
    var canonical: String { strings[0] }

    static let table: [JS8Command] = [
        JS8Command(code: -1, strings: [" CQ", " HB", " HEARTBEAT"]),
        JS8Command(code: 0, strings: [" SNR?", "?"]),
        JS8Command(code: 1, strings: [" DIT DIT"]),
        JS8Command(code: 2, strings: [" NACK"]),
        JS8Command(code: 3, strings: [" HEARING?"]),
        JS8Command(code: 4, strings: [" GRID?"]),
        JS8Command(code: 5, strings: [">"]),
        JS8Command(code: 6, strings: [" STATUS?"]),
        JS8Command(code: 7, strings: [" STATUS"]),
        JS8Command(code: 8, strings: [" HEARING"]),
        JS8Command(code: 9, strings: [" MSG"]),
        JS8Command(code: 10, strings: [" MSG TO:"]),
        JS8Command(code: 11, strings: [" QUERY"]),
        JS8Command(code: 12, strings: [" QUERY MSGS", " QUERY MSGS?"]),
        JS8Command(code: 13, strings: [" QUERY CALL"]),
        JS8Command(code: 14, strings: [" ACK"]),
        JS8Command(code: 15, strings: [" GRID"]),
        JS8Command(code: 16, strings: [" INFO?"]),
        JS8Command(code: 17, strings: [" INFO"]),
        JS8Command(code: 18, strings: [" FB"]),
        JS8Command(code: 19, strings: [" HW CPY?"]),
        JS8Command(code: 20, strings: [" SK"]),
        JS8Command(code: 21, strings: [" RR"]),
        JS8Command(code: 22, strings: [" QSL?"]),
        JS8Command(code: 23, strings: [" QSL"]),
        JS8Command(code: 24, strings: [" CMD"]),
        JS8Command(code: 25, strings: [" SNR"]),
        JS8Command(code: 26, strings: [" NO"]),
        JS8Command(code: 27, strings: [" YES"]),
        JS8Command(code: 28, strings: [" 73"]),
        JS8Command(code: 29, strings: [" HEARTBEAT SNR"]),
        JS8Command(code: 30, strings: [" AGN?"]),
        JS8Command(code: 31, strings: [" ", "  "]),
    ]

    static let snr = table[26]
    static let heartbeatSNR = table[30]
    static let freeText = table[32]
    static let cq = table[0]

    static func byCode(_ code: Int) -> JS8Command? {
        table.first { $0.code == code }
    }

    /// Look up a captured command string: first as-is (with its leading
    /// space), then trimmed (that's how "?" and ">" are found).
    static func byString(_ s: String) -> JS8Command? {
        if let c = table.first(where: { $0.strings.contains(s) }) { return c }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return table.first { $0.strings.contains(trimmed) }
    }

    static let autoReplyCodes: Set<Int> = [0, 2, 3, 4, 6, 9, 10, 11, 12, 13, 14, 16, 30]
    static let explicitBufferedCodes: Set<Int> = [5, 9, 10, 11, 12, 13, 15, 24]
    static let snrNumberCodes: Set<Int> = [25, 29]
    /// Checksum width by code (0 = explicitly none; absent = none).
    static let checksumWidths: [Int: Int] = [5: 16, 9: 16, 10: 16, 11: 16, 12: 16, 13: 16, 15: 0, 24: 16]

    /// Every command except "?" opens a text buffer: a command string
    /// containing a space counts, and ">" is in the explicit set.
    static func isBuffered(_ cmd: String) -> Bool {
        if cmd.contains(" ") { return true }
        if let c = byString(cmd) { return explicitBufferedCodes.contains(c.code) }
        return false
    }

    static func checksumWidth(_ cmd: String) -> Int {
        guard let c = byString(cmd) else { return 0 }
        return checksumWidths[c.code] ?? 0
    }

    static func isAutoReply(_ cmd: String) -> Bool {
        guard let c = byString(cmd) else { return false }
        return autoReplyCodes.contains(c.code)
    }

    static func isSNRCommand(_ cmd: String) -> Bool {
        guard let c = byString(cmd) else { return false }
        return snrNumberCodes.contains(c.code)
    }

    var isSNR: Bool { JS8Command.snrNumberCodes.contains(code) }

    // MARK: Text grammar

    /// Directed text: "CALL CMD [NUM]" at the start of a line.
    static let directedPattern = "^(?<callsign>[@]?[A-Z0-9/]+)(?<cmd>\\s?(?:AGN[?]|QSL[?]|HW CPY[?]|MSG TO[:]|SNR[?]|INFO[?]|GRID[?]|STATUS[?]|QUERY MSGS[?]|HEARING[?]|(?:(?:STATUS|HEARING|QUERY CALL|QUERY MSGS|QUERY|CMD|MSG|NACK|ACK|73|YES|NO|HEARTBEAT SNR|SNR|QSL|RR|SK|FB|INFO|GRID|DIT DIT)(?=[ ]|$))|[?> ]))?(?<num>(?<=SNR)\\s?[-+]?(?:3[01]|[0-2]?[0-9]))?"
    static let directedRegex = try! NSRegularExpression(pattern: directedPattern)

    static let cqStrings = ["CQ CQ CQ", "CQ DX", "CQ QRP", "CQ CONTEST", "CQ FIELD", "CQ FD", "CQ CQ", "CQ"]
    static func cqString(_ n: Int) -> String { (0..<8).contains(n) ? cqStrings[n] : "" }
    /// Every heartbeat variant renders as HB (status flags retired in 2.2).
    static func hbString(_ n: Int) -> String { (0..<8).contains(n) ? "HB" : "" }

    static let heartbeatPattern = "^\\s*(?<callsign>[@](?:ALLCALL|HB)\\s+)?(?<type>CQ CQ CQ|CQ DX|CQ QRP|CQ CONTEST|CQ FIELD|CQ FD|CQ CQ|CQ|HB|HEARTBEAT(?!\\s+SNR))(?:\\s(?<grid>[A-R]{2}[0-9]{2}))?\\b"
    static let heartbeatRegex = try! NSRegularExpression(pattern: heartbeatPattern)

    /// Compound frame text: "`CALL [GRID] [CMD [NUM]]".
    static let compoundPattern = "^\\s*[`](?<callsign>[@]?[A-Z0-9/]+)(?<extra>(?<grid>\\s?[A-R]{2}[0-9]{2})?(?<cmd>\\s?(?:AGN[?]|QSL[?]|HW CPY[?]|MSG TO[:]|SNR[?]|INFO[?]|GRID[?]|STATUS[?]|QUERY MSGS[?]|HEARING[?]|(?:(?:STATUS|HEARING|QUERY CALL|QUERY MSGS|QUERY|CMD|MSG|NACK|ACK|73|YES|NO|HEARTBEAT SNR|SNR|QSL|RR|SK|FB|INFO|GRID|DIT DIT)(?=[ ]|$))|[?> ]))?(?<num>(?<=SNR)\\s?[-+]?(?:3[01]|[0-2]?[0-9]))?)"
    static let compoundRegex = try! NSRegularExpression(pattern: compoundPattern)
}

extension NSTextCheckingResult {
    /// Named capture as a Swift string, nil when the group didn't participate.
    func group(_ name: String, in s: String) -> String? {
        let r = range(withName: name)
        guard r.location != NSNotFound, let range = Range(r, in: s) else { return nil }
        return String(s[range])
    }

    func matchedString(in s: String) -> String {
        guard let r = Range(range, in: s) else { return "" }
        return String(s[r])
    }
}
