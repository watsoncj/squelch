import Foundation

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
    /// Backed by the clean-room WSPRCodec (spec-derived, MIT-licensable).
    static func encode(call: String, grid4: String, dbm: Int, frequencyHz: Double) -> [Float]? {
        WSPRCodec.audio(call: call, grid: grid4, dBm: dbm, offsetHz: frequencyHz)
    }
}

enum WSPRDecoderEngine {
    /// Decode a ~2-minute slot of 12 kHz audio. Stateless.
    /// Backed by the clean-room WSPRDecoder (type-1 messages).
    static func decodeSlot(_ samples: [Float], rcall: String, rgrid: String, dialHz: Int) -> [WSPRSpot] {
        WSPRDecoder.decode(samples).map { r in
            WSPRSpot(
                call: r.call,
                grid: r.grid,
                powerDBm: r.dBm,
                snr: Float(r.snrDB),
                dt: Float(r.dtSeconds),
                drift: 0,
                frequencyHz: Double(dialHz) + r.audioFrequencyHz
            )
        }
    }
}
