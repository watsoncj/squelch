import XCTest
@testable import Squelch

/// Measures the decoder's SNR floor: 3 trials per level (different noise
/// seed, frequency, and start offset), −14 → −28 dB in 2 dB steps.
/// Run in release config for speed: swift test -c release --filter WSPRSensitivityProbe
final class WSPRSensitivityProbe: XCTestCase {
    private struct NoiseSource {
        var state: UInt64
        mutating func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Float {
            Float((-2 * log(max(uniform(), 1e-12))).squareRoot() * cos(2 * .pi * uniform()))
        }
    }

    static func trialSlot(snrDB: Double, seed: UInt64, hz: Double, dt: Double) -> [Float] {
        let sampleRate = 12_000.0
        let slotCount = 120 * 12_000
        let noiseRMS: Float = 0.1
        let noisePower2500 = Double(noiseRMS * noiseRMS) * (2500.0 / (sampleRate / 2))
        let amplitude = Float((2 * pow(10, snrDB / 10) * noisePower2500).squareRoot())
        guard let tx = WSPREncoder.encode(call: "K1ABC", grid4: "FN42", dbm: 30, frequencyHz: hz) else {
            return []
        }
        var buf = [Float](repeating: 0, count: slotCount)
        let start = Int(dt * sampleRate)
        for i in 0..<min(tx.count, slotCount - start) {
            buf[start + i] = tx[i] * amplitude
        }
        var noise = NoiseSource(state: seed)
        for i in buf.indices {
            buf[i] += noise.gaussian() * noiseRMS
        }
        return buf
    }

    func testDiagnoseWall() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WSPR_SWEEP"] == "1",
                          "diagnostic — run with WSPR_SWEEP=1 swift test -c release")
        for snr in [-20.0, -22.0, -24.0] {
            print("=== SNR \(snr) ===")
            let slot = Self.trialSlot(snrDB: snr, seed: 0x2545_F491_4F6C_DD1D, hz: 1465.2, dt: 1.0)
            for line in WSPRDecoder.diagnose(slot, expectedAudioHz: 1465.2,
                                             call: "K1ABC", grid: "FN42", dBm: 30) {
                print(line)
            }
        }
    }

    func testSensitivityFloorSweep() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WSPR_SWEEP"] == "1",
                          "~5 min in release, far longer in debug — run with WSPR_SWEEP=1 swift test -c release")
        let trials: [(seed: UInt64, hz: Double, dt: Double)] = [
            (0x2545_F491_4F6C_DD1D, 1465.2, 1.0),
            (0x9E37_79B9_7F4A_7C15, 1537.8, 1.3),
            (0xD1B5_4A32_D192_ED03, 1411.5, 0.9),
        ]
        var lastFullHit: Double?
        for snr in stride(from: -14.0, through: -28.0, by: -2.0) {
            var hits = 0
            for t in trials {
                let slot = Self.trialSlot(snrDB: snr, seed: t.seed, hz: t.hz, dt: t.dt)
                if WSPRDecoder.decode(slot).contains(where: { $0.call == "K1ABC" }) {
                    hits += 1
                }
            }
            print(String(format: "SNR %5.0f dB → %d/3", snr, hits))
            if hits == trials.count {
                lastFullHit = snr
            }
        }
        print("floor (3/3 decodes): \(lastFullHit.map { String($0) } ?? "none") dB")
        XCTAssertNotNil(lastFullHit)
    }
}
