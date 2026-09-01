import Foundation

/// Field packers of the JS8 frame layer: callsigns, grids, numbers, SNR
/// and the compound-directed command byte. Written from the protocol
/// description; the constants (radices, base-call table, thresholds) are
/// protocol facts.
enum JS8Fields {
    /// 37·36·10·27·27·27 — every standard callsign packs below this.
    static let baseCallValue: UInt32 = 262_177_560
    static let placeholderCall = "<....>"
    static let noGrid: UInt16 = 32767
    static let gridUpperBound: UInt16 = 32400
    static let compoundCommandBase: UInt16 = 32410

    /// Group/base-call names, k = 1...54 → value baseCallValue + k.
    static let baseCalls: [String] = [
        "<....>", "@ALLCALL", "@JS8NET", "@DX/NA", "@DX/SA", "@DX/EU", "@DX/AS", "@DX/AF", "@DX/OC", "@DX/AN",
        "@REGION/1", "@REGION/2", "@REGION/3", "@GROUP/0", "@GROUP/1", "@GROUP/2", "@GROUP/3", "@GROUP/4",
        "@GROUP/5", "@GROUP/6", "@GROUP/7", "@GROUP/8", "@GROUP/9", "@COMMAND", "@CONTROL", "@NET", "@NTS",
        "@RESERVE/0", "@RESERVE/1", "@RESERVE/2", "@RESERVE/3", "@RESERVE/4", "@APRSIS", "@RAGCHEW", "@JS8",
        "@EMCOMM", "@ARES", "@MARS", "@AMRRON", "@RACES", "@RAYNET", "@RADAR", "@SKYWARN", "@CQ", "@HB", "@QSO",
        "@QSOPARTY", "@CONTEST", "@FIELDDAY", "@SOTA", "@IOTA", "@POTA", "@QRP", "@QRO",
    ]
    static let disallowedGroups: Set<String> = ["@APRSIS", "@JS8NET"]

    static func isGroupAllowed(_ group: String) -> Bool {
        !disallowedGroups.contains(group.uppercased())
    }

    private static let baseCallValues: [String: UInt32] = {
        var m: [String: UInt32] = [:]
        for (i, name) in baseCalls.enumerated() {
            m[name] = baseCallValue + UInt32(i + 1)
        }
        return m
    }()

    private static let baseCallNames: [UInt32: String] = {
        var m: [UInt32: String] = [:]
        for (name, v) in baseCallValues { m[v] = name }
        return m
    }()

    static func isBaseCall(_ call: String) -> Bool {
        baseCallValues[call.uppercased()] != nil
    }

    // MARK: 28-bit callsign

    private static let standardForm = try! NSRegularExpression(pattern: "([0-9A-Z ])([0-9A-Z])([0-9])([A-Z ])([A-Z ])([A-Z ])")

    /// Packs a standard callsign (or group) into 28 bits. Returns 0 on
    /// failure. `portable` reports a stripped "/P".
    static func packCallsign(_ input: String) -> (value: UInt32, portable: Bool) {
        var call = input.uppercased().trimmingCharacters(in: .whitespaces)
        if let fixed = baseCallValues[call] {
            return (fixed, false)
        }
        var portable = false
        if call.hasSuffix("/P") {
            call = String(call.dropLast(2))
            portable = true
        }
        if call.hasPrefix("3DA0") {
            call = "3D0" + call.dropFirst(4)
        } else if call.hasPrefix("3X"), let third = call.dropFirst(2).first, third.isLetter, third.isUppercase {
            call = "Q" + call.dropFirst(2)
        }
        let n = call.count
        guard n >= 2, n <= 6 else { return (0, portable) }
        let candidates: [String]
        switch n {
        case 6: candidates = [call]
        case 5: candidates = [call, " " + call, call + " "]
        case 4: candidates = [call, " " + call + " ", call + "  "]
        case 3: candidates = [call, " " + call + "  ", call + "   "]
        default: candidates = [call, " " + call + "   "]
        }
        var matched: String?
        for candidate in candidates {
            let range = NSRange(candidate.startIndex..., in: candidate)
            if let m = standardForm.firstMatch(in: candidate, range: range),
               let r = Range(m.range, in: candidate), candidate[r].count == 6 {
                matched = String(candidate[r])
            }
        }
        guard let form = matched else { return (0, portable) }
        let c = Array(form)
        func i(_ ch: Character) -> UInt32 { UInt32(JS8Alphabet.index(of: ch, in: JS8Alphabet.alphanumeric) ?? 0) }
        var v = i(c[0])
        v = 36 * v + i(c[1])
        v = 10 * v + i(c[2])
        v = 27 * v + (i(c[3]) - 10)
        v = 27 * v + (i(c[4]) - 10)
        v = 27 * v + (i(c[5]) - 10)
        return (v, portable)
    }

    static func unpackCallsign(_ value: UInt32, portable: Bool) -> String {
        if let name = baseCallNames[value] { return name }
        let a = JS8Alphabet.alphanumeric
        var v = value
        var chars = [Character](repeating: " ", count: 6)
        chars[5] = a[Int(v % 27) + 10]; v /= 27
        chars[4] = a[Int(v % 27) + 10]; v /= 27
        chars[3] = a[Int(v % 27) + 10]; v /= 27
        chars[2] = a[Int(v % 10)]; v /= 10
        chars[1] = a[Int(v % 36)]; v /= 36
        chars[0] = a[min(Int(v), a.count - 1)]
        var call = String(chars)
        if call.hasPrefix("3D0") {
            call = "3DA0" + call.dropFirst(3)
        } else if call.hasPrefix("Q"), let second = call.dropFirst().first, second.isLetter {
            call = "3X" + call.dropFirst()
        }
        call = call.trimmingCharacters(in: .whitespaces)
        return portable ? call + "/P" : call
    }

    private static let validCallsign = try! NSRegularExpression(
        pattern: "^\\b(?<base>([0-9A-Z])?([0-9A-Z])([0-9])([A-Z])?([A-Z])?([A-Z])?)(?<portable>[/][P])?\\b$")
    private static let digitLetter = try! NSRegularExpression(pattern: "[0-9][A-Z]|[A-Z][0-9]")
    private static let compoundForm = try! NSRegularExpression(
        pattern: "^(?:[@]?|\\b)(?<extended>[A-Z0-9/@][A-Z0-9/]{0,2}[/]?[A-Z0-9/]{0,3}[/]?[A-Z0-9/]{0,3})\\b$")

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// A valid *standard* callsign (fits the 28-bit packer) or group name.
    static func isStandardCallsign(_ input: String) -> Bool {
        let call = input.uppercased()
        if isBaseCall(call) { return true }
        return matches(validCallsign, call) && call.count > 2 && matches(digitLetter, call)
    }

    /// A valid compound callsign (needs the 50-bit packer).
    static func isCompoundCallsign(_ input: String) -> Bool {
        let call = input.uppercased()
        if isBaseCall(call) { return false }
        guard matches(compoundForm, call) else { return false }
        if call.filter({ $0 != "/" }).count > 9 { return false }
        if call.contains("/") {
            let head = String(call.prefix(while: { $0 != "/" }))
            return !isBaseCall(head)
        }
        if call.hasPrefix("@") { return true }
        return call.count > 2 && matches(digitLetter, call)
    }

    static func isValidCallsign(_ input: String) -> Bool {
        isStandardCallsign(input) || isCompoundCallsign(input)
    }

    // MARK: 50-bit alphanumeric (compound callsigns)

    static func packAlphaNumeric50(_ input: String) -> UInt64 {
        var chars = input.uppercased().filter { JS8Alphabet.alphanumeric.contains($0) }.map { $0 }
        if chars.count > 3, chars[3] != "/" { chars.insert(" ", at: 3) }
        if chars.count > 7, chars[7] != "/" { chars.insert(" ", at: 7) }
        while chars.count < 11 { chars.append(" ") }
        chars = Array(chars.prefix(11))
        func i(_ ch: Character) -> UInt64 { UInt64(JS8Alphabet.index(of: ch, in: JS8Alphabet.alphanumeric) ?? 36) }
        func s(_ ch: Character) -> UInt64 { ch == "/" ? 1 : 0 }
        var v = i(chars[0])
        v = 38 * v + i(chars[1])
        v = 38 * v + i(chars[2])
        v = 2 * v + s(chars[3])
        v = 38 * v + i(chars[4])
        v = 38 * v + i(chars[5])
        v = 38 * v + i(chars[6])
        v = 2 * v + s(chars[7])
        v = 38 * v + i(chars[8])
        v = 38 * v + i(chars[9])
        v = 38 * v + i(chars[10])
        return v
    }

    static func unpackAlphaNumeric50(_ value: UInt64) -> String {
        let a = JS8Alphabet.alphanumeric
        var v = value
        var chars = [Character](repeating: " ", count: 11)
        for slot in stride(from: 10, through: 0, by: -1) {
            switch slot {
            case 3, 7:
                chars[slot] = (v % 2 == 1) ? "/" : " "
                v /= 2
            case 0:
                chars[slot] = a[Int(v % 39)]
                v /= 39
            default:
                chars[slot] = a[Int(v % 38)]
                v /= 38
            }
        }
        return String(chars.filter { $0 != " " })
    }

    // MARK: 15-bit grid

    static func packGrid(_ input: String) -> UInt16 {
        let g = Array(input.uppercased().trimmingCharacters(in: .whitespaces))
        guard g.count >= 4,
              let a1 = g[0].asciiValue, let a2 = g[1].asciiValue, let d1 = g[2].asciiValue, let d2 = g[3].asciiValue,
              (65...82).contains(a1), (65...82).contains(a2), (48...57).contains(d1), (48...57).contains(d2)
        else { return noGrid }
        let lonField = Int(a1) - 65
        let latField = Int(a2) - 65
        let lonSq = Int(d1) - 48
        let latSq = Int(d2) - 48
        let k = 180 - 20 * lonField - 2 * lonSq
        let ilong = k >= 2 ? k - 2 : k - 1
        let ilat = 10 * latField + latSq
        return UInt16(((ilong + 180) / 2) * 180 + ilat)
    }

    static func unpackGrid(_ value: UInt16) -> String {
        guard value <= gridUpperBound else { return "" }
        let v = Int(value)
        let lat = v % 180 - 90
        let lon = (v / 180) * 2 - 180 + 2
        let nlong = 12 * (180 - lon)
        let n1 = nlong / 240
        let n2 = (nlong - 240 * n1) / 24
        let nlat = 24 * (lat + 90)
        let m1 = nlat / 240
        let m2 = (nlat - 240 * m1) / 24
        guard (0...17).contains(n1), (0...17).contains(m1) else { return "" }
        return String([Character(UnicodeScalar(65 + n1)!), Character(UnicodeScalar(65 + m1)!),
                       Character(UnicodeScalar(48 + n2)!), Character(UnicodeScalar(48 + m2)!)])
    }

    // MARK: numbers / SNR

    /// 0 = absent; otherwise n + 31 for n clamped to −30…31.
    static func packNum(_ text: String) -> UInt8 {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let n = Int(t) else { return 0 }
        return UInt8(max(-30, min(31, n)) + 31)
    }

    static func formatSNR(_ n: Int) -> String {
        guard n >= -60, n <= 60 else { return "" }
        return n >= 0 ? String(format: "+%02d", n) : String(format: "-%02d", -n)
    }

    /// Compound-directed command byte (added to 32410).
    static func packCmd(code: Int, num: UInt8) -> UInt8 {
        if code == JS8Command.snr.code || code == JS8Command.heartbeatSNR.code {
            return 0x80 | (code == JS8Command.heartbeatSNR.code ? 0x40 : 0) | (num & 63)
        }
        return UInt8(code & 127)
    }

    static func unpackCmd(_ value: UInt8) -> (code: Int, num: UInt8) {
        if value & 0x80 != 0 {
            return (value & 0x40 != 0 ? JS8Command.heartbeatSNR.code : JS8Command.snr.code, value & 63)
        }
        return (Int(value & 127), 0)
    }
}
