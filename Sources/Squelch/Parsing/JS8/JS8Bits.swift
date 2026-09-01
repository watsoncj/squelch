import Foundation

/// Bit-level helpers for the 72-bit JS8 frame payload. Everything is
/// MSB-first; a frame is 12 six-bit symbols of the modem alphabet.
enum JS8Alphabet {
    /// The 64-symbol modem alphabet, index order.
    static let modem: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-+")
    /// Base-41 alphabet used by the checksum renderers.
    static let base41: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ+-./?")
    /// Callsign/grid alphabet: digits, letters, space (36), "/" (37), "@" (38).
    static let alphanumeric: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ /@")

    static func index(of c: Character, in table: [Character]) -> Int? {
        table.firstIndex(of: c)
    }
}

/// Appends bit fields MSB-first into a 72-bit payload.
struct JS8BitWriter {
    private(set) var bits: [Bool] = []

    mutating func append(_ value: UInt64, width: Int) {
        for i in stride(from: width - 1, through: 0, by: -1) {
            bits.append((value >> UInt64(i)) & 1 == 1)
        }
    }

    mutating func append(bits other: [Bool]) {
        bits.append(contentsOf: other)
    }

    var count: Int { bits.count }

    /// Pads per the data-frame rule (one 0 then 1s) and returns the payload.
    func paddedPayload() -> [UInt8] {
        var b = bits
        precondition(b.count < 72)
        b.append(false)
        while b.count < 72 { b.append(true) }
        return JS8BitWriter.pack(b)
    }

    /// Exactly 72 bits → 9 bytes.
    func payload() -> [UInt8] {
        precondition(bits.count == 72)
        return JS8BitWriter.pack(bits)
    }

    static func pack(_ bits: [Bool]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (i, bit) in bits.enumerated() where bit {
            out[i / 8] |= 0x80 >> UInt8(i % 8)
        }
        return out
    }
}

/// Reads bit fields MSB-first from a 72-bit payload.
struct JS8BitReader {
    let bits: [Bool]
    private(set) var position = 0

    init(payload: [UInt8]) {
        var b: [Bool] = []
        b.reserveCapacity(payload.count * 8)
        for byte in payload {
            for i in 0..<8 {
                b.append((byte >> UInt8(7 - i)) & 1 == 1)
            }
        }
        bits = Array(b.prefix(72))
    }

    init(bits: [Bool]) {
        self.bits = bits
    }

    var remaining: Int { bits.count - position }

    mutating func read(_ width: Int) -> UInt64 {
        var v: UInt64 = 0
        for _ in 0..<width {
            v = (v << 1) | (bits[position] ? 1 : 0)
            position += 1
        }
        return v
    }

    mutating func readBit() -> Bool {
        let b = bits[position]
        position += 1
        return b
    }

    mutating func skip(_ n: Int) { position += n }

    /// The bits from `position` up to (not including) the last zero bit —
    /// the data-frame unpadding rule.
    func unpaddedRest() -> [Bool] {
        guard let lastZero = bits.lastIndex(of: false), lastZero >= position else { return [] }
        return Array(bits[position..<lastZero])
    }
}

extension JS8Frame {
    /// The 12-character modem-alphabet rendering of the payload.
    var frameString: String {
        let reader = JS8BitReader(payload: payload)
        var r = reader
        var s = ""
        for _ in 0..<12 {
            s.append(JS8Alphabet.modem[Int(r.read(6))])
        }
        return s
    }

    /// Nil unless the string is exactly 12 modem-alphabet symbols.
    init?(frameString: String, type: TransmissionType) {
        guard frameString.count == 12 else { return nil }
        var w = JS8BitWriter()
        for c in frameString {
            guard let idx = JS8Alphabet.index(of: c, in: JS8Alphabet.modem) else { return nil }
            w.append(UInt64(idx), width: 6)
        }
        self.init(payload: w.payload(), type: type)
    }
}
