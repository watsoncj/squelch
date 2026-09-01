import Foundation

/// One JS8 frame as it comes off the modem: 72 payload bits and the 3-bit
/// transmission type that rides beside them (JS8's `i3`). The frame layer
/// (`JS8Varicode`) turns the bits into heartbeats, directed messages and
/// text; the modem only knows the bits.
struct JS8Frame: Equatable, Hashable {
    /// Transmission-type flags carried in the 3 bits outside the payload.
    struct TransmissionType: OptionSet, Hashable {
        let rawValue: UInt8
        static let first = TransmissionType(rawValue: 1)
        static let last = TransmissionType(rawValue: 2)
        /// A data frame with no frame-type header (its bits are all text).
        static let data = TransmissionType(rawValue: 4)
    }

    /// 72 bits, MSB first, in 9 bytes.
    let payload: [UInt8]
    let type: TransmissionType

    init(payload: [UInt8], type: TransmissionType) {
        precondition(payload.count == 9)
        self.payload = payload
        self.type = type
    }

    init(payload: [UInt8], typeBits: UInt8) {
        self.init(payload: payload, type: TransmissionType(rawValue: typeBits & 0x7))
    }

    /// The 72 payload bits as a `UInt64` (bit 71 of the frame is the MSB).
    var bits: UInt64 {
        payload.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    /// Frame from the low 64 of its 72 bits (the top byte is zero) —
    /// enough for tests; the frame layer builds payloads byte-wise.
    init(bits: UInt64, type: TransmissionType) {
        var value = bits
        var bytes = [UInt8](repeating: 0, count: 9)
        for i in stride(from: 8, through: 0, by: -1) {
            bytes[i] = UInt8(value & 0xFF)
            value >>= 8
        }
        self.init(payload: bytes, type: type)
    }

    var hexString: String {
        payload.map { String(format: "%02x", $0) }.joined()
    }

    /// Placeholder rendering until the frame layer decodes it.
    var debugText: String {
        "JS8 \(hexString) t\(type.rawValue)"
    }
}
