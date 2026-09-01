import Foundation
import CFT8

struct FT8Result {
    let snr: Float
    let timeOffset: Float
    let freqHz: Float
    let text: String
    /// JS8 modes: the raw frame; `text` then holds whatever the frame
    /// layer rendered from it.
    var js8: JS8Frame? = nil
}

/// The digital modes we speak. FT8 and FT4 share message formats and the
/// QSO sequence; WSPR is a beacon; the JS8 speeds share one frame format
/// and differ in symbol period (and so slot length and bandwidth).
enum DigiMode: String, CaseIterable, Identifiable {
    case ft8 = "FT8"
    case ft4 = "FT4"
    case wspr = "WSPR"
    /// JS8Call speed 0 — 15 s period, the one with heartbeat networking.
    case js8 = "JS8"
    /// JS8Call speed 1 — 10 s period.
    case js8Fast = "JS8 FAST"
    /// JS8Call speed 2 ("JS8 40", formerly Turbo) — 6 s period.
    case js8Turbo = "JS8 40"
    /// JS8Call speed 4 — 30 s period, the most sensitive.
    case js8Slow = "JS8 SLOW"
    /// JS8Call speed 8 ("JS8 60") — 4 s period; experimental upstream.
    case js8Ultra = "JS8 60"

    var id: String { rawValue }

    static let js8Speeds: [DigiMode] = [.js8Slow, .js8, .js8Fast, .js8Turbo, .js8Ultra]

    var isJS8: Bool { protocolID.rawValue >= CFT8_PROTOCOL_JS8_NORMAL.rawValue }

    /// JS8Call's speed number (its API's MODE.SPEED): 0 normal, 1 fast,
    /// 2 JS8 40, 4 slow, 8 JS8 60.
    var js8Speed: Int? {
        switch self {
        case .js8: return 0
        case .js8Fast: return 1
        case .js8Turbo: return 2
        case .js8Slow: return 4
        case .js8Ultra: return 8
        default: return nil
        }
    }

    /// The CFT8 waveform this mode decodes/encodes with (WSPR has its own
    /// Swift codec and never reaches CFT8).
    var protocolID: cft8_protocol_t {
        switch self {
        case .ft8, .wspr: return CFT8_PROTOCOL_FT8
        case .ft4: return CFT8_PROTOCOL_FT4
        case .js8: return CFT8_PROTOCOL_JS8_NORMAL
        case .js8Fast: return CFT8_PROTOCOL_JS8_FAST
        case .js8Turbo: return CFT8_PROTOCOL_JS8_TURBO
        case .js8Slow: return CFT8_PROTOCOL_JS8_SLOW
        case .js8Ultra: return CFT8_PROTOCOL_JS8_ULTRA
        }
    }

    /// Symbol duration; tone spacing is its reciprocal.
    var symbolSeconds: Double {
        switch self {
        case .ft8: return 0.160
        case .ft4: return 0.048
        case .wspr: return 8192.0 / 12000.0
        default: return Double(cft8_symbol_period(protocolID))
        }
    }

    var slotSeconds: Double {
        switch self {
        case .ft8: return 15.0
        case .ft4: return 7.5
        case .wspr: return 120.0
        default: return Double(cft8_slot_seconds(protocolID))
        }
    }

    /// Delay from the slot boundary to the first symbol — the lead silence
    /// in the encoded audio.
    var startDelaySeconds: Double {
        switch self {
        case .ft8, .ft4: return 0.5
        case .wspr: return 1.0
        default: return Double(cft8_start_delay(protocolID))
        }
    }

    /// Time on air, first symbol to last — the height a transmission
    /// paints on the waterfall. FT8 79 × 0.160 s, FT4 105 × 0.048 s,
    /// JS8 79 symbols at the speed's period.
    var transmissionSeconds: Double {
        switch self {
        case .ft8: return 79 * 0.160   // 12.64
        case .ft4: return 105 * 0.048  // 5.04
        case .wspr: return WSPRCodec.transmissionSeconds // 110.6
        default: return 79 * symbolSeconds
        }
    }

    /// How wide the tone set paints. Tone spacing is the reciprocal of the
    /// symbol period, so this is tone count ÷ symbol period: FT8 8 ×
    /// 6.25 Hz, FT4 4 × 20.83 Hz, WSPR 4 × 1.46 Hz. FT4 is the widest of
    /// the three despite having half FT8's tones; JS8 SLOW is 25 Hz, JS8 60
    /// is 250 Hz.
    var toneSpanHz: Double {
        switch self {
        case .ft8: return 8 / 0.160        // 50.00
        case .ft4: return 4 / 0.048        // 83.33
        case .wspr: return 4 * 12000 / 8192 // 5.86
        default: return 8 / symbolSeconds
        }
    }

    /// FT8's auto-sequencer (CQ, hunt, reply) runs only for FT8/FT4: WSPR
    /// is a beacon and JS8 has its own conversational frame layer.
    var supportsQSO: Bool { self == .ft8 || self == .ft4 }

    /// The mode name for the QSO log and ADIF: all JS8 speeds are "JS8".
    var logName: String { isJS8 ? "JS8" : rawValue }

    static var current: DigiMode {
        DigiMode(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.digiMode) ?? "") ?? .ft8
    }
}

enum FT8Encoder {
    /// Encode a message into 12 kHz mono audio (0.5 s lead silence +
    /// 12.64 s FT8 / 5.04 s FT4 of tones). Nil if the text can't be packed.
    static func encode(message: String, frequencyHz: Double, mode: DigiMode = .ft8) -> [Float]? {
        var buffer = [Float](repeating: 0, count: Int((mode.slotSeconds + 1) * Double(FT8Decoder.sampleRate)))
        let written = buffer.withUnsafeMutableBufferPointer { buf in
            Int(cft8_encode(message, Float(frequencyHz), Int32(FT8Decoder.sampleRate), mode.protocolID, buf.baseAddress, Int32(buf.count)))
        }
        guard written > 0 else { return nil }
        return Array(buffer.prefix(written))
    }

    /// Encode one JS8 frame into audio: the speed's start delay of silence
    /// followed by 79 tones. Nil for non-JS8 modes.
    static func encode(frame: JS8Frame, frequencyHz: Double, mode: DigiMode) -> [Float]? {
        guard mode.isJS8 else { return nil }
        var buffer = [Float](repeating: 0, count: Int((mode.slotSeconds + 1) * Double(FT8Decoder.sampleRate)))
        let written = buffer.withUnsafeMutableBufferPointer { buf in
            frame.payload.withUnsafeBufferPointer { payload in
                Int(cft8_encode_js8(payload.baseAddress, Int32(frame.type.rawValue), Float(frequencyHz),
                                    Int32(FT8Decoder.sampleRate), mode.protocolID, buf.baseAddress, Int32(buf.count)))
            }
        }
        guard written > 0 else { return nil }
        return Array(buffer.prefix(written))
    }
}

/// Tone-level JS8 codec, for tests and diagnostics.
enum JS8ToneCodec {
    static func tones(for frame: JS8Frame, mode: DigiMode = .js8) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 79)
        frame.payload.withUnsafeBufferPointer { payload in
            out.withUnsafeMutableBufferPointer { buf in
                cft8_js8_tones(payload.baseAddress, Int32(frame.type.rawValue), mode.protocolID, buf.baseAddress)
            }
        }
        return out
    }

    /// Hard-decision decode; nil when the parity checks or CRC fail.
    static func frame(fromTones tones: [UInt8]) -> JS8Frame? {
        guard tones.count == 79 else { return nil }
        var payload = [UInt8](repeating: 0, count: 9)
        var type: Int32 = 0
        let ok = tones.withUnsafeBufferPointer { t in
            payload.withUnsafeMutableBufferPointer { p in
                cft8_js8_decode_tones(t.baseAddress, p.baseAddress, &type)
            }
        }
        guard ok else { return nil }
        return JS8Frame(payload: payload, typeBits: UInt8(type))
    }
}

/// Thin Swift wrapper over the CFT8 glue. Not thread-safe: confine each
/// instance to one queue.
final class FT8Decoder {
    static let sampleRate = 12000

    private let dec: OpaquePointer

    private let mode: DigiMode

    init?(mode: DigiMode = .ft8) {
        guard let d = cft8_create(Int32(Self.sampleRate), mode.protocolID) else { return nil }
        dec = d
        self.mode = mode
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
            if mode.isJS8 {
                let payload = withUnsafeBytes(of: r.js8_payload) { Array($0.prefix(9)) }
                let frame = JS8Frame(payload: payload, typeBits: r.js8_type)
                return FT8Result(snr: r.snr, timeOffset: r.time_sec, freqHz: r.freq_hz, text: frame.debugText, js8: frame)
            }
            let text = withUnsafeBytes(of: r.text) { rawBuf in
                String(decoding: rawBuf.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return FT8Result(snr: r.snr, timeOffset: r.time_sec, freqHz: r.freq_hz, text: text)
        }
    }
}
