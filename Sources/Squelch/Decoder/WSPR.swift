import Foundation
import CFT8

struct WSPRSpot {
    let call: String
    let grid: String
    let powerDBm: Int
    let snr: Float
    let dt: Float
    let drift: Float
    let frequencyHz: Double // absolute RF frequency
}

enum WSPREncoder {
    /// 1 s lead silence + 110.6 s of 4-FSK at audio frequency f0.
    static func encode(call: String, grid4: String, dbm: Int, frequencyHz: Double) -> [Float]? {
        var buffer = [Float](repeating: 0, count: 113 * FT8Decoder.sampleRate)
        let written = buffer.withUnsafeMutableBufferPointer { buf in
            Int(wspr_tx(call, grid4, Int32(dbm), Float(frequencyHz), Int32(FT8Decoder.sampleRate), buf.baseAddress, Int32(buf.count)))
        }
        guard written > 0 else { return nil }
        return Array(buffer.prefix(written))
    }
}

enum WSPRDecoderEngine {
    /// Decode a ~2-minute slot of 12 kHz audio. Stateless; confine calls to
    /// one queue at a time.
    static func decodeSlot(_ samples: [Float], rcall: String, rgrid: String, dialHz: Int) -> [WSPRSpot] {
        var raw = [wspr_spot](repeating: wspr_spot(), count: 30)
        let count = samples.withUnsafeBufferPointer { buf in
            raw.withUnsafeMutableBufferPointer { out in
                Int(wspr_rx(buf.baseAddress, Int32(buf.count), Int32(FT8Decoder.sampleRate),
                            rcall, rgrid, Int32(dialHz), out.baseAddress, Int32(out.count)))
            }
        }
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let s = raw[i]
            let call = withUnsafeBytes(of: s.call) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            let grid = withUnsafeBytes(of: s.grid) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            return WSPRSpot(
                call: call,
                grid: grid,
                powerDBm: Int(s.power_dbm),
                snr: s.snr,
                dt: s.dt,
                drift: s.drift,
                frequencyHz: s.freq_hz
            )
        }
    }
}
