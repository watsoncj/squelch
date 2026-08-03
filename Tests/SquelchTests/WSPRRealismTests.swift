import XCTest
@testable import Squelch

/// Off-air conditions the clean loopback tests never exercise: the ~1 s
/// slot offset, band noise, soundcard clock skew, and pileups. A decoder
/// that only passes clean loopback can still be deaf on a real antenna.
final class WSPRRealismTests: XCTestCase {
    private let sampleRate = 12_000
    private let slotSamples = 120 * 12_000

    /// Deterministic Gaussian noise (Box–Muller over an LCG).
    private struct NoiseSource {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        mutating func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Float {
            let u1 = max(uniform(), 1e-12)
            let u2 = uniform()
            return Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
        }
    }

    /// A 120 s slot: silence, then the encoded transmission at `dt`.
    private func slot(call: String, grid: String, dbm: Int, hz: Double,
                      dt: Double, amplitude: Float = 0.1) -> [Float] {
        guard let tx = WSPREncoder.encode(call: call, grid4: grid, dbm: dbm, frequencyHz: hz) else {
            XCTFail("encode failed")
            return []
        }
        var buffer = [Float](repeating: 0, count: slotSamples)
        let start = Int(dt * Double(sampleRate))
        for i in 0..<min(tx.count, slotSamples - start) {
            buffer[start + i] = tx[i] * amplitude
        }
        return buffer
    }

    private func addNoise(_ samples: inout [Float], rms: Float) {
        var noise = NoiseSource()
        for i in samples.indices {
            samples[i] += noise.gaussian() * rms
        }
    }

    /// Linear resample by `factor` — a soundcard clock running fast/slow.
    private func skewed(_ samples: [Float], factor: Double) -> [Float] {
        var out = [Float](repeating: 0, count: samples.count)
        for i in out.indices {
            let x = Double(i) * factor
            let j = Int(x)
            guard j + 1 < samples.count else { break }
            let frac = Float(x - Double(j))
            out[i] = samples[j] * (1 - frac) + samples[j + 1] * frac
        }
        return out
    }

    private func decodedCalls(_ samples: [Float]) -> [String] {
        WSPRDecoder.decode(samples).map(\.call)
    }

    func testDecodesWithRealisticSlotOffset() {
        // Real transmissions begin ~1 s after the even minute
        let samples = slot(call: "K1ABC", grid: "FN42", dbm: 30, hz: 1465.2, dt: 1.0)
        XCTAssertTrue(decodedCalls(samples).contains("K1ABC"))
    }

    func testDecodesLateStarter() {
        let samples = slot(call: "K1ABC", grid: "FN42", dbm: 30, hz: 1512.7, dt: 2.0)
        XCTAssertTrue(decodedCalls(samples).contains("K1ABC"))
    }

    func testDecodesInBandNoise() {
        // Audible-warble territory: signal well above the noise in its few Hz,
        // but the full 2.5 kHz channel is much noisier than the tone
        var samples = slot(call: "K1ABC", grid: "FN42", dbm: 30, hz: 1465.2, dt: 1.0)
        addNoise(&samples, rms: 0.1) // ≈ -14 dB SNR in 2500 Hz
        XCTAssertTrue(decodedCalls(samples).contains("K1ABC"))
    }

    func testDecodesWithSoundcardClockSkew() {
        // ±300 ppm is an ordinary USB codec crystal
        let clean = slot(call: "K1ABC", grid: "FN42", dbm: 30, hz: 1465.2, dt: 1.0)
        XCTAssertTrue(decodedCalls(skewed(clean, factor: 1.0003)).contains("K1ABC"), "fast clock")
        XCTAssertTrue(decodedCalls(skewed(clean, factor: 0.9997)).contains("K1ABC"), "slow clock")
    }

    /// WSPR has no CRC — the deep decode budget must never conjure spots
    /// out of a dead band.
    func testPureNoiseProducesNoDecodes() {
        for seed in [3, 7, 11] as [UInt64] {
            var noise = NoiseSource(state: seed &* 0x9E37_79B9_7F4A_7C15)
            var buf = [Float](repeating: 0, count: 120 * 12_000)
            for i in buf.indices {
                buf[i] = noise.gaussian() * 0.1
            }
            XCTAssertTrue(WSPRDecoder.decode(buf).isEmpty, "false decode from noise (seed \(seed))")
        }
    }

    func testDecodesTwoOverlappingSignals() {
        var a = slot(call: "K1ABC", grid: "FN42", dbm: 30, hz: 1450.0, dt: 1.0)
        let b = slot(call: "W9XYZ", grid: "EN52", dbm: 37, hz: 1530.0, dt: 1.4, amplitude: 0.2)
        for i in a.indices {
            a[i] += b[i]
        }
        addNoise(&a, rms: 0.05)
        let calls = decodedCalls(a)
        XCTAssertTrue(calls.contains("K1ABC"), "weaker of the pair")
        XCTAssertTrue(calls.contains("W9XYZ"))
    }
}
