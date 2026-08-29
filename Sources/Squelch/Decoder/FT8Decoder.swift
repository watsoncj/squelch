import Foundation
import CFT8

struct FT8Result {
    let snr: Float
    let timeOffset: Float
    let freqHz: Float
    let text: String
}

/// The digital modes we speak. Both share message formats and the QSO
/// sequence; they differ in slot length and waveform.
enum DigiMode: String, CaseIterable, Identifiable {
    case ft8 = "FT8"
    case ft4 = "FT4"
    case wspr = "WSPR"

    var id: String { rawValue }

    var slotSeconds: Double {
        switch self {
        case .ft8: return 15.0
        case .ft4: return 7.5
        case .wspr: return 120.0
        }
    }

    /// Time on air, first symbol to last — the height a transmission
    /// paints on the waterfall. FT8 79 × 0.160 s, FT4 105 × 0.048 s.
    var transmissionSeconds: Double {
        switch self {
        case .ft8: return 79 * 0.160   // 12.64
        case .ft4: return 105 * 0.048  // 5.04
        case .wspr: return WSPRCodec.transmissionSeconds // 110.6
        }
    }

    /// How wide the tone set paints. Tone spacing is the reciprocal of the
    /// symbol period, so this is tone count ÷ symbol period: FT8 8 ×
    /// 6.25 Hz, FT4 4 × 20.83 Hz, WSPR 4 × 1.46 Hz. FT4 is the widest of
    /// the three despite having half FT8's tones.
    var toneSpanHz: Double {
        switch self {
        case .ft8: return 8 / 0.160        // 50.00
        case .ft4: return 4 / 0.048        // 83.33
        case .wspr: return 4 * 12000 / 8192 // 5.86
        }
    }

    var isFT4: Bool { self == .ft4 }
    /// WSPR is a beacon mode: no QSO sequencer, 2-minute slots.
    var supportsQSO: Bool { self != .wspr }

    static var current: DigiMode {
        DigiMode(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.digiMode) ?? "") ?? .ft8
    }
}

enum FT8Encoder {
    /// Encode a message into 12 kHz mono audio (0.5 s lead silence +
    /// 12.64 s FT8 / 5.04 s FT4 of tones). Nil if the text can't be packed.
    static func encode(message: String, frequencyHz: Double, mode: DigiMode = .ft8) -> [Float]? {
        var buffer = [Float](repeating: 0, count: 15 * FT8Decoder.sampleRate)
        let written = buffer.withUnsafeMutableBufferPointer { buf in
            Int(cft8_encode(message, Float(frequencyHz), Int32(FT8Decoder.sampleRate), mode.isFT4, buf.baseAddress, Int32(buf.count)))
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

    init?(mode: DigiMode = .ft8) {
        guard let d = cft8_create(Int32(Self.sampleRate), mode.isFT4) else { return nil }
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
