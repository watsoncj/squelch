import Foundation
import CFT8

struct FT8Result {
    let snr: Float
    let timeOffset: Float
    let freqHz: Float
    let text: String
}

enum FT8Encoder {
    /// Encode a standard FT8 message into 12 kHz mono audio (0.5 s lead
    /// silence + 12.64 s of tones). Nil if the text can't be packed.
    static func encode(message: String, frequencyHz: Double) -> [Float]? {
        var buffer = [Float](repeating: 0, count: 15 * FT8Decoder.sampleRate)
        let written = buffer.withUnsafeMutableBufferPointer { buf in
            Int(cft8_encode(message, Float(frequencyHz), Int32(FT8Decoder.sampleRate), buf.baseAddress, Int32(buf.count)))
        }
        guard written > 0 else { return nil }
        return Array(buffer.prefix(written))
    }
}

/// Thin Swift wrapper over the CFT8 glue. Not thread-safe: confine each
/// instance to one queue.
final class FT8Decoder {
    static let sampleRate = 12000

    private let dec: OpaquePointer

    init?() {
        guard let d = cft8_create(Int32(Self.sampleRate)) else { return nil }
        dec = d
    }

    deinit {
        cft8_destroy(dec)
    }

    /// Decode one slot's worth of 12 kHz mono samples. Resets the decoder for
    /// the next slot before returning.
    func decodeSlot(_ samples: [Float]) -> [FT8Result] {
        samples.withUnsafeBufferPointer { buf in
            cft8_feed(dec, buf.baseAddress, Int32(buf.count))
        }
        var raw = [cft8_result_t](repeating: cft8_result_t(), count: 50)
        let count = raw.withUnsafeMutableBufferPointer { buf in
            Int(cft8_decode(dec, buf.baseAddress, Int32(buf.count)))
        }
        cft8_reset(dec)

        return (0..<count).map { i in
            let r = raw[i]
            let text = withUnsafeBytes(of: r.text) { rawBuf in
                String(decoding: rawBuf.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return FT8Result(snr: r.snr, timeOffset: r.time_sec, freqHz: r.freq_hz, text: text)
        }
    }
}
