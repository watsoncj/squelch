import Foundation

/// JSC: (s,c)-dense coding of word-table ranks — JS8's text compression.
/// s = 7 stopper nibbles (0–6), c = 9 continuers (7–15); each token ends
/// with a stopper nibble plus one "a space follows" bit.
enum JS8JSC {
    static let tableSize = 262_144
    static let base: [Int] = [0, 7, 70, 637, 5740, 51667, 465010, 4185097]

    static func codeword(rank: Int, separator: Bool) -> [Bool] {
        var nibbles: [Int] = []
        var x = rank / 7
        while x > 0 {
            x -= 1
            nibbles.insert((x % 9) + 7, at: 0)
            x /= 9
        }
        nibbles.append(rank % 7)
        var bits: [Bool] = []
        for n in nibbles {
            for i in stride(from: 3, through: 0, by: -1) { bits.append((n >> i) & 1 == 1) }
        }
        bits.append(separator)
        return bits
    }

    /// Bits → text. Ranks missing from a sparse table decode as "".
    static func decode(_ bits: [Bool], dictionary: JS8Dictionary) -> String {
        var nibbles: [(value: Int, separator: Bool)] = []
        var i = 0
        while i + 4 <= bits.count {
            var v = 0
            for k in 0..<4 { v = (v << 1) | (bits[i + k] ? 1 : 0) }
            i += 4
            var sep = false
            if v < 7, i < bits.count {
                sep = bits[i]
                i += 1
            }
            nibbles.append((v, sep))
        }
        var out = ""
        var start = 0
        while start < nibbles.count {
            var j = 0
            var k = 0
            var pos = start
            while pos < nibbles.count, nibbles[pos].value >= 7 {
                j = j * 9 + (nibbles[pos].value - 7)
                k += 1
                pos += 1
                if j >= tableSize { return out }
            }
            guard pos < nibbles.count, k < base.count else { return out }
            let rank = j * 7 + nibbles[pos].value + base[k]
            guard rank < tableSize else { return out }
            out += dictionary.word(at: rank) ?? ""
            if nibbles[pos].separator { out += " " }
            start = pos + 1
        }
        return out
    }

    /// Tokens for `text`: (codeword bits, characters consumed). Characters
    /// with no table entry stop the tokenisation of their word.
    static func compress(_ text: String, dictionary: JS8Dictionary) -> [(bits: [Bool], consumed: Int)] {
        var out: [(bits: [Bool], consumed: Int)] = []
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        for (index, original) in parts.enumerated() {
            let isLastPart = index == parts.count - 1
            var part = original
            var isSpaceCharacter = false
            if part.isEmpty {
                if isLastPart { continue }
                part = " "
                isSpaceCharacter = true
            }
            while !part.isEmpty {
                guard let match = dictionary.longestPrefix(of: part) else { break }
                part = part.dropFirst(match.length)
                let isLast = part.isEmpty
                let separator = isLast && !isSpaceCharacter && !isLastPart
                out.append((codeword(rank: match.rank, separator: separator), match.length + (separator ? 1 : 0)))
            }
        }
        return out
    }

    /// As many leading tokens of `text` as fit in `budget` bits under the
    /// strict "< budget" rule.
    static func encode(_ text: String, budget: Int, dictionary: JS8Dictionary) -> (bits: [Bool], consumed: Int) {
        var bits: [Bool] = []
        var consumed = 0
        for token in compress(text, dictionary: dictionary) {
            guard bits.count + token.bits.count < budget else { break }
            bits.append(contentsOf: token.bits)
            consumed += token.consumed
        }
        return (bits, consumed)
    }
}
