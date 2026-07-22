import Foundation

/// Clean-room WSPR type-1 message codec.
///
/// Implemented solely from the public protocol specification — G4JNT,
/// "The WSPR Coding Process" (the canonical description of packing, the
/// K=32 r=1/2 convolutional code, interleaving, and symbol construction)
/// as reproduced in S. W. Harden's WSPR protocol notes. Contains no code
/// from WSJT-X/wsprd. The sync vector and generator polynomials are
/// protocol constants required for interoperability.
enum WSPRCodec {
    // MARK: - Protocol constants

    /// 162-symbol pseudo-random sync vector (per the G4JNT specification).
    static let syncVector: [UInt8] = [
        1,1,0,0,0,0,0,0,1,0,0,0,1,1,1,0,0,0,1,0,0,1,0,1,1,1,1,0,0,0,0,0,
        0,0,1,0,0,1,0,1,0,0,0,0,0,0,1,0,1,1,0,0,1,1,0,1,0,0,0,1,1,0,1,0,
        0,0,0,1,1,0,1,0,1,0,1,0,1,0,0,1,0,0,1,0,1,1,0,0,0,1,1,0,1,0,1,0,
        0,0,1,0,0,0,0,0,1,0,0,1,0,0,1,1,1,0,1,1,0,0,1,1,0,1,0,0,0,1,1,1,
        0,0,0,0,0,1,0,1,0,0,1,1,0,0,0,0,0,0,0,1,1,0,1,0,1,1,0,0,0,1,1,0,
        0,0,
    ]

    /// Layland–Lushbaugh generator polynomials for the K=32 rate-1/2 code.
    static let poly1: UInt32 = 0xF2D0_5351
    static let poly2: UInt32 = 0xE461_3C47

    static let symbolCount = 162
    static let toneSpacingHz = 12000.0 / 8192.0        // 1.4648 Hz
    static let symbolSeconds = 8192.0 / 12000.0        // 0.6827 s
    static let transmissionSeconds = 162.0 * 8192.0 / 12000.0 // 110.6 s

    // MARK: - Character mapping (0-9 → 0-9, A-Z → 10-35, space → 36)

    private static func charValue(_ c: Character) -> Int? {
        if let d = c.wholeNumberValue, c.isNumber { return d }
        if let a = c.asciiValue, a >= 65, a <= 90 { return Int(a) - 55 }
        if c == " " { return 36 }
        return nil
    }

    /// Normalize to the canonical 6 characters: third character must be a
    /// digit (prepend a space for calls like G4JNT), pad to 6 with spaces.
    static func normalizeCallsign(_ call: String) -> [Character]? {
        var chars = Array(call.uppercased())
        guard chars.count >= 3, chars.count <= 6 else { return nil }
        if !(chars.count > 2 && chars[2].isNumber) {
            // Second char must then be the digit once we prepend a space
            guard chars.count > 1, chars[1].isNumber else { return nil }
            chars.insert(" ", at: 0)
        }
        guard chars.count <= 6, chars[2].isNumber else { return nil }
        while chars.count < 6 { chars.append(" ") }
        // Last three: letters or space only
        for c in chars[3...] where !(c.isLetter || c == " ") { return nil }
        return chars
    }

    // MARK: - Packing (spec section: message coding)

    /// Callsign → 28-bit integer.
    static func packCallsign(_ call: String) -> UInt32? {
        guard let c = normalizeCallsign(call) else { return nil }
        guard let v0 = charValue(c[0]), let v1 = charValue(c[1]),
              let v2 = charValue(c[2]), let v3 = charValue(c[3]),
              let v4 = charValue(c[4]), let v5 = charValue(c[5]) else { return nil }
        guard v1 < 36, v2 < 10, v3 >= 10, v4 >= 10, v5 >= 10 else { return nil }
        var n = UInt32(v0)
        n = n * 36 + UInt32(v1)
        n = n * 10 + UInt32(v2)
        n = n * 27 + UInt32(v3 - 10)
        n = n * 27 + UInt32(v4 - 10)
        n = n * 27 + UInt32(v5 - 10)
        return n
    }

    /// 28-bit integer → callsign (inverse of packCallsign), trimmed.
    static func unpackCallsign(_ n: UInt32) -> String? {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ ")
        var n = n
        var chars = [Character](repeating: " ", count: 6)
        for i in [5, 4, 3] {
            let v = Int(n % 27) + 10
            guard v <= 36 else { return nil }
            chars[i] = alphabet[v]
            n /= 27
        }
        chars[2] = alphabet[Int(n % 10)]; n /= 10
        let v1 = Int(n % 36); n /= 36
        guard v1 < 36 else { return nil }
        chars[1] = alphabet[v1]
        guard n <= 36 else { return nil }
        chars[0] = alphabet[Int(n)]
        let call = String(chars).trimmingCharacters(in: .whitespaces)
        return call.isEmpty ? nil : call
    }

    /// 4-char locator + power (dBm) → 22-bit integer.
    static func packGridPower(grid: String, dBm: Int) -> UInt32? {
        let g = Array(grid.uppercased())
        guard g.count == 4,
              let f0 = charValue(g[0]), let f1 = charValue(g[1]),
              let d0 = charValue(g[2]), let d1 = charValue(g[3]),
              (10...27).contains(f0), (10...27).contains(f1), // A-R
              d0 < 10, d1 < 10,
              (0...60).contains(dBm) else { return nil }
        let l1 = f0 - 10, l2 = f1 - 10, l3 = d0, l4 = d1
        let m1 = UInt32((179 - 10 * l1 - l3) * 180 + 10 * l2 + l4)
        return m1 * 128 + UInt32(dBm + 64)
    }

    /// 22-bit integer → (grid, dBm).
    static func unpackGridPower(_ m: UInt32) -> (grid: String, dBm: Int)? {
        let dBm = Int(m % 128) - 64
        guard (0...60).contains(dBm) else { return nil }
        let m1 = Int(m / 128)
        let rest = m1 / 180
        let tail = m1 % 180
        let l3 = (179 - rest) % 10
        let l1 = (179 - rest - l3) / 10
        let l2 = tail / 10
        let l4 = tail % 10
        guard (0...17).contains(l1), (0...17).contains(l2) else { return nil }
        let letters = Array("ABCDEFGHIJKLMNOPQR")
        return ("\(letters[l1])\(letters[l2])\(l3)\(l4)", dBm)
    }

    /// The 50 message bits, MSB-first: 28-bit callsign then 22-bit grid+power.
    static func messageBits(call: String, grid: String, dBm: Int) -> [UInt8]? {
        guard let n = packCallsign(call),
              let m = packGridPower(grid: grid, dBm: dBm) else { return nil }
        var bits: [UInt8] = []
        for i in stride(from: 27, through: 0, by: -1) {
            bits.append(UInt8((n >> UInt32(i)) & 1))
        }
        for i in stride(from: 21, through: 0, by: -1) {
            bits.append(UInt8((m >> UInt32(i)) & 1))
        }
        return bits // 50 bits
    }

    // MARK: - Convolutional code (K=32, r=1/2, zero tail)

    /// 50 message bits + 31 zero tail → 162 coded bits.
    /// For each input bit (shifted into the register LSB), emit the parity
    /// of (register AND poly1) then (register AND poly2).
    static func convolve(_ messageBits: [UInt8]) -> [UInt8] {
        var reg: UInt32 = 0
        var out: [UInt8] = []
        out.reserveCapacity(162)
        let input = messageBits + [UInt8](repeating: 0, count: 31)
        for bit in input {
            reg = (reg << 1) | UInt32(bit)
            out.append(UInt8((reg & poly1).nonzeroBitCount & 1))
            out.append(UInt8((reg & poly2).nonzeroBitCount & 1))
        }
        return out
    }

    // MARK: - Interleaver (bit-reversed 8-bit addresses)

    /// Destination order: bit-reverse each address 0...255, keep those
    /// < 162, in ascending source order.
    static let interleaveMap: [Int] = {
        var map: [Int] = []
        map.reserveCapacity(162)
        for i in 0...255 {
            var j = 0
            for b in 0..<8 where (i >> b) & 1 == 1 {
                j |= 1 << (7 - b)
            }
            if j < 162 { map.append(j) }
        }
        return map // map[sourceIndex] = destinationIndex
    }()

    static func interleave(_ bits: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 162)
        for (src, dst) in interleaveMap.enumerated() {
            out[dst] = bits[src]
        }
        return out
    }

    static func deinterleave<T>(_ values: [T]) -> [T] {
        var out = [T]()
        out.reserveCapacity(162)
        for dst in interleaveMap {
            out.append(values[dst])
        }
        return out
    }

    // MARK: - Symbols

    /// Full encode: 162 tone values 0-3, Symbol[n] = Sync[n] + 2·Data[n].
    static func symbols(call: String, grid: String, dBm: Int) -> [UInt8]? {
        guard let msg = messageBits(call: call, grid: grid, dBm: dBm) else { return nil }
        let data = interleave(convolve(msg))
        return zip(syncVector, data).map { $0 + 2 * $1 }
    }

    // MARK: - Modulation

    static let sampleRate = 12000
    static let samplesPerSymbol = 8192

    /// Phase-continuous 4-FSK at 12 kHz. `offsetHz` is the center of the
    /// four-tone group (tone = offset + (symbol − 1.5) · spacing), matching
    /// how decoders report a spot's frequency.
    static func audio(call: String, grid: String, dBm: Int,
                      offsetHz: Double, leadInSeconds: Double = 1.0) -> [Float]? {
        guard let tones = symbols(call: call, grid: grid, dBm: dBm) else { return nil }
        let lead = Int(leadInSeconds * Double(sampleRate))
        var out = [Float](repeating: 0, count: lead)
        out.reserveCapacity(lead + tones.count * samplesPerSymbol)
        var phase = 0.0
        for tone in tones {
            let hz = offsetHz + (Double(tone) - 1.5) * toneSpacingHz
            let step = 2.0 * Double.pi * hz / Double(sampleRate)
            for _ in 0..<samplesPerSymbol {
                phase += step
                if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
                out.append(Float(sin(phase)) * 0.5)
            }
        }
        return out
    }
}
