import Foundation

/// The fixed Huffman code used by Normal-speed data frames (header "10").
enum JS8Huffman {
    static let table: [Character: String] = [
        " ": "01", "E": "100", "T": "1101", "A": "0011", "O": "11111", "I": "11100", "N": "10111",
        "S": "10100", "H": "00011", "R": "00000", "D": "111011", "L": "110011", "C": "110001",
        "U": "101101", "M": "101011", "W": "001011", "F": "001001", "G": "000101", "Y": "000011",
        "P": "1111011", "B": "1111001", ".": "1110100", "V": "1100101", "K": "1100100", "-": "1100001",
        "+": "1100000", "?": "1011001", "!": "1011000", "\"": "1010101", "X": "1010100", "0": "0010101",
        "J": "0010100", "1": "0010001", "Q": "0010000", "2": "0001001", "Z": "0001000", "3": "0000101",
        "5": "0000100", "4": "11110101", "9": "11110100", "8": "11110001", "6": "11110000",
        "7": "11101011", "/": "11101010",
    ]

    private static let bitsByChar: [Character: [Bool]] = table.mapValues { $0.map { $0 == "1" } }
    private static let charByBits: [String: Character] = {
        var m: [String: Character] = [:]
        for (c, code) in table { m[code] = c }
        return m
    }()
    private static let maxCodeLength = 8

    static func canEncode(_ text: String) -> Bool {
        text.allSatisfy { table[$0] != nil }
    }

    /// Codes for as many leading characters as fit in `budget` bits under
    /// the strict "< budget" fill rule. Returns (bits, consumed); consumed
    /// is 0 when any character of `text` is outside the table.
    static func encode(_ text: String, budget: Int) -> (bits: [Bool], consumed: Int) {
        guard canEncode(text) else { return ([], 0) }
        var bits: [Bool] = []
        var consumed = 0
        for c in text {
            let code = bitsByChar[c]!
            guard bits.count + code.count < budget else { break }
            bits.append(contentsOf: code)
            consumed += 1
        }
        return (bits, consumed)
    }

    static func decode(_ bits: [Bool]) -> String {
        var out = ""
        var i = 0
        while i < bits.count {
            var found = false
            for len in 2...maxCodeLength where i + len <= bits.count {
                let key = String(bits[i..<i + len].map { $0 ? "1" : "0" })
                if let c = charByBits[key] {
                    out.append(c)
                    i += len
                    found = true
                    break
                }
            }
            if !found { break }
        }
        return out
    }
}
