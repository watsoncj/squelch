import Foundation

/// Extracts the sending callsign and grid locator from standard FT8 message text.
///
/// Standard shapes:
///   "CQ W0CJW EN35"            CQ with grid
///   "CQ POTA W0CJW EN35"       CQ with modifier
///   "K1ABC W9XYZ EN52"         reply with grid
///   "K1ABC W9XYZ -12"          signal report
///   "K1ABC W9XYZ R-08"         roger + report
///   "K1ABC W9XYZ RR73"         (RR73 looks like a grid but is a sign-off)
enum FT8MessageParser {
    struct Parsed {
        var sender: String?
        var addressee: String? // station being called; nil for CQ/free text
        var grid: String?
        var isCQ: Bool
    }

    static func parse(_ text: String) -> Parsed {
        let tokens = text.uppercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return Parsed(sender: nil, addressee: nil, grid: nil, isCQ: false) }

        if tokens[0] == "CQ" {
            var rest = Array(tokens.dropFirst())
            var grid: String? = nil
            if let last = rest.last, isGrid(last) {
                grid = last
                rest.removeLast()
            }
            // Whatever remains is [modifier] callsign — take the last callsign-shaped token
            let sender = rest.reversed().map(stripHashBrackets).first(where: isCallsign)
            return Parsed(sender: sender, addressee: nil, grid: grid, isCQ: true)
        }

        guard tokens.count >= 2 else { return Parsed(sender: nil, addressee: nil, grid: nil, isCQ: false) }
        let addresseeCandidate = stripHashBrackets(tokens[0])
        let addressee = isCallsign(addresseeCandidate) ? addresseeCandidate : nil
        let candidate = stripHashBrackets(tokens[1])
        let sender = isCallsign(candidate) ? candidate : nil
        var grid: String? = nil
        if tokens.count >= 3, isGrid(tokens[2]) {
            grid = tokens[2]
        }
        return Parsed(sender: sender, addressee: addressee, grid: grid, isCQ: false)
    }

    /// 4-character Maidenhead grid; RR73 is excluded (it's a sign-off, not a location).
    static func isGrid(_ s: String) -> Bool {
        guard s.count == 4, s != "RR73" else { return false }
        let chars = Array(s)
        return ("A"..."R").contains(chars[0]) && ("A"..."R").contains(chars[1])
            && chars[2].isNumber && chars[3].isNumber
    }

    /// Loose callsign check: 3–11 chars of A–Z, 0–9, '/', with at least one letter and one digit.
    static func isCallsign(_ s: String) -> Bool {
        guard (3...11).contains(s.count) else { return false }
        var hasLetter = false, hasDigit = false
        for c in s {
            if c.isLetter { hasLetter = true }
            else if c.isNumber { hasDigit = true }
            else if c != "/" { return false }
        }
        return hasLetter && hasDigit
    }

    private static func stripHashBrackets(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    /// True when the callsign indicates a US station (including AK/HI and
    /// territories): prefixes K, N, W, and AA–AL. For compound calls the
    /// first segment wins — it's the location prefix ("PJ4/K1ABC" is a US
    /// call operating from Bonaire → not US; "K1ABC/7" is stateside).
    static func isUSCallsign(_ callsign: String) -> Bool {
        let location = callsign.split(separator: "/").first.map(String.init) ?? callsign
        guard let first = location.first else { return false }
        switch first {
        case "K", "N", "W":
            return true
        case "A":
            guard location.count >= 2 else { return false }
            let second = location[location.index(location.startIndex, offsetBy: 1)]
            return ("A"..."L").contains(second)
        default:
            return false
        }
    }
}
