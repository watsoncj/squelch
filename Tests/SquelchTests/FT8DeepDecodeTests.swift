import XCTest
@testable import Squelch

/// The deep FT8 decoder (baseband demodulation + subtraction) against the
/// stock ft8_lib path it can be switched back to.
final class FT8DeepDecodeTests: XCTestCase {
    private static let rate = FT8Decoder.sampleRate
    private static let slotSamples = 15 * rate

    /// Deterministic Gaussian noise, so a marginal decode can't flap.
    private struct Noise {
        var state: UInt64
        mutating func uniform() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state >> 11) / 9007199254740992.0
        }
        mutating func gaussian() -> Float {
            Float((-2 * log(uniform() + 1e-300)).squareRoot() * cos(2 * .pi * uniform()))
        }
    }

    /// Signal amplitude for an SNR in the 2500 Hz reference bandwidth
    /// (WSJT-X's convention) over white noise of the given sigma.
    private static func amplitude(snrDB: Double, sigma: Double) -> Float {
        let noiseIn2500 = sigma * sigma * 2500 / (Double(rate) / 2)
        return Float((2 * noiseIn2500 * pow(10, snrDB / 10)).squareRoot())
    }

    private func slot(seed: UInt64, sigma: Float = 0.05,
                      signals: [(text: String, hz: Double, snrDB: Double, delay: Double)]) throws -> [Float] {
        var out = [Float](repeating: 0, count: Self.slotSamples)
        for signal in signals {
            let tones = try XCTUnwrap(FT8Encoder.encode(message: signal.text, frequencyHz: signal.hz))
            let amp = Self.amplitude(snrDB: signal.snrDB, sigma: Double(sigma))
            let offset = Int(signal.delay * Double(Self.rate))
            for (i, sample) in tones.enumerated() where i + offset < out.count {
                out[i + offset] += amp * sample
            }
        }
        var noise = Noise(state: seed)
        for i in out.indices {
            out[i] += sigma * noise.gaussian()
        }
        return out
    }

    private func decoder(deep: Bool) throws -> FT8Decoder {
        let decoder = try XCTUnwrap(FT8Decoder())
        decoder.deepDecode = deep
        return decoder
    }

    func testBothDecodersReadACleanSignal() throws {
        let samples = try slot(seed: 1, signals: [("CQ W0CJW DM79", 1500, 0, 0)])
        for deep in [true, false] {
            let results = try decoder(deep: deep).decodeSlot(samples)
            XCTAssertEqual(results.map(\.text), ["CQ W0CJW DM79"], "deep \(deep)")
            XCTAssertEqual(results.first?.freqHz ?? 0, 1500, accuracy: 4, "deep \(deep)")
        }
    }

    /// The stock path reads SNR off the sync score, which saturates; the
    /// deep path measures it. Time is the first symbol's start: the encoded
    /// audio's 0.5 s lead, without the waterfall's analysis-window lag.
    func testDeepDecodeMeasuresSNRAndTime() throws {
        for snr in [-12.0, 0.0, 10.0] {
            let samples = try slot(seed: 2, signals: [("K1ABC W0CJW -05", 1200.4, snr, 0.3)])
            let result = try XCTUnwrap(try decoder(deep: true).decodeSlot(samples).first)
            XCTAssertEqual(Double(result.snr), snr, accuracy: 2.5, "at \(snr) dB")
            XCTAssertEqual(result.timeOffset, 0.8, accuracy: 0.03)
            XCTAssertEqual(result.freqHz, 1200.4, accuracy: 0.5)
        }
        let loud = try slot(seed: 2, signals: [("K1ABC W0CJW -05", 1200.4, 10, 0.3)])
        let stock = try XCTUnwrap(try decoder(deep: false).decodeSlot(loud).first)
        XCTAssertLessThan(stock.snr, 0, "the stock estimate tops out well below a +10 dB signal")
    }

    /// A signal 10 dB under another on the same frequency: only decodable
    /// once the strong one has been subtracted.
    func testDeepDecodeSeparatesStackedSignals() throws {
        let samples = try slot(seed: 3, signals: [
            ("CQ K1ABC FN42", 1500, 3, 0),
            ("W9XYZ N0ABC R-11", 1501, -7, 0.4),
        ])
        let deep = Set(try decoder(deep: true).decodeSlot(samples).map(\.text))
        XCTAssertEqual(deep, ["CQ K1ABC FN42", "W9XYZ N0ABC R-11"])
        let stock = try decoder(deep: false).decodeSlot(samples).map(\.text)
        XCTAssertEqual(stock, ["CQ K1ABC FN42"])
    }

    /// −19.5 dB sits between the two decoders' thresholds (stock ≈ −18.5,
    /// deep ≈ −20.4 for half the signals).
    func testDeepDecodeIsMoreSensitive() throws {
        let deepDecoder = try decoder(deep: true)
        let stockDecoder = try decoder(deep: false)
        var deepCount = 0, stockCount = 0
        let trials = 12
        for trial in 0..<trials {
            let samples = try slot(seed: 100 + UInt64(trial),
                                   signals: [("CQ W0CJW DM79", 900 + 150.3 * Double(trial), -19.5, 0.1)])
            deepCount += deepDecoder.decodeSlot(samples).filter { $0.text == "CQ W0CJW DM79" }.count
            stockCount += stockDecoder.decodeSlot(samples).filter { $0.text == "CQ W0CJW DM79" }.count
        }
        XCTAssertGreaterThanOrEqual(deepCount, trials * 2 / 3)
        XCTAssertGreaterThanOrEqual(deepCount, stockCount + 3)
    }

    func testNoiseDecodesNothing() throws {
        for deep in [true, false] {
            let decoder = try decoder(deep: deep)
            for seed in 200..<204 {
                XCTAssertEqual(decoder.decodeSlot(try slot(seed: UInt64(seed), signals: [])).count, 0)
            }
        }
    }

    /// Out of time, the deep decoder falls back to the stock decode for
    /// what's left; it never returns less than the stock decoder would.
    func testExhaustedTimeBudgetFallsBackToStockDecode() throws {
        let samples = try slot(seed: 4, signals: [("CQ W0CJW DM79", 1500, 5, 0)])
        let decoder = try decoder(deep: true)
        decoder.timeBudget = 1e-6
        XCTAssertEqual(decoder.decodeSlot(samples).map(\.text), ["CQ W0CJW DM79"])
    }

    /// Deep decode is FT8's alone; the flag must not disturb the others.
    func testDeepFlagIsIgnoredOutsideFT8() throws {
        let decoder = try XCTUnwrap(FT8Decoder(mode: .ft4))
        decoder.deepDecode = true
        var samples = try XCTUnwrap(FT8Encoder.encode(message: "CQ W0CJW DM79", frequencyHz: 1200, mode: .ft4))
        samples.append(contentsOf: [Float](repeating: 0, count: Int(7.5 * Double(Self.rate)) - samples.count))
        XCTAssertEqual(decoder.decodeSlot(samples).map(\.text), ["CQ W0CJW DM79"])
    }

    // MARK: Slot timer

    func testSlotTimerFiresAheadOfTheBoundaryByTheLead() {
        let boundary = 1_800_000_000.0 // a multiple of 15
        XCTAssertEqual(DecodeController.nextSlotFire(now: boundary + 3, period: 15, lead: 0), boundary + 15, accuracy: 1e-6)
        XCTAssertEqual(DecodeController.nextSlotFire(now: boundary + 3, period: 15, lead: 0.4), boundary + 14.6, accuracy: 1e-6)
    }

    func testStartInsideTheLeadWindowFiresAtOnce() {
        // Waiting for the next lead point would let this slot's tail run
        // into the following slot's buffer
        let boundary = 1_800_000_000.0
        XCTAssertEqual(DecodeController.nextSlotFire(now: boundary + 14.8, period: 15, lead: 0.4), boundary + 14.8, accuracy: 1e-6)
    }

    func testChangingTheLeadNeverRepeatsASlot() {
        let boundary = 1_800_000_000.0
        // Deep switched off just after an early fire for `boundary`: the
        // next fire is the following boundary, not `boundary` again
        XCTAssertEqual(DecodeController.nextSlotFire(now: boundary - 0.39, period: 15, lead: 0, afterBoundary: boundary),
                       boundary + 15, accuracy: 1e-6)
        // Deep switched on just after an on-boundary fire
        XCTAssertEqual(DecodeController.nextSlotFire(now: boundary + 0.01, period: 15, lead: 0.4, afterBoundary: boundary),
                       boundary + 14.6, accuracy: 1e-6)
    }
}
