import Foundation

/// Checksums appended to buffered directed-command text.
enum JS8Checksum {
    /// CRC-16/KERMIT: poly 0x1021 reflected, init 0, no final XOR.
    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1
            }
        }
        return crc
    }

    /// CRC-32/BZIP2: poly 0x04C11DB7, init 0xFFFFFFFF, no reflection, final XOR.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func pack16(_ v: UInt16) -> String {
        let a = JS8Alphabet.base41
        let v = Int(v)
        return String([a[v / 1681], a[(v - 1681 * (v / 1681)) / 41], a[v % 41]])
    }

    static func unpack16(_ s: String) -> UInt16 {
        let c = Array(s)
        guard c.count == 3,
              let i0 = JS8Alphabet.index(of: c[0], in: JS8Alphabet.base41),
              let i1 = JS8Alphabet.index(of: c[1], in: JS8Alphabet.base41),
              let i2 = JS8Alphabet.index(of: c[2], in: JS8Alphabet.base41) else { return 0 }
        let v = 1681 * i0 + 41 * i1 + i2
        return v > 65535 ? 0 : UInt16(v)
    }

    static func pack32(_ v: UInt32) -> String {
        pack16(UInt16(v >> 16)) + pack16(UInt16(v & 0xFFFF))
    }

    static func checksum16(_ text: String) -> String {
        pack16(crc16(Array(text.utf8)))
    }

    static func checksum32(_ text: String) -> String {
        pack32(crc32(Array(text.utf8)))
    }

    static func isValid16(_ checksum: String, for text: String) -> Bool {
        checksum16(text) == checksum
    }

    static func isValid32(_ checksum: String, for text: String) -> Bool {
        checksum32(text) == checksum
    }
}
