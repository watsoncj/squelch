import XCTest
@testable import Squelch

/// Decodes a recorded off-air slot (raw Float32 @ 12 kHz, as written by
/// the record_slot.swift scratch tool). Ground truth: wspr.live spots for
/// the same slot. Run: WSPR_SLOT_RAW=/path/slot.raw swift test -c release --filter WSPROffAirProbe
final class WSPROffAirProbe: XCTestCase {
    func testDecodeRecordedSlot() throws {
        guard let path = ProcessInfo.processInfo.environment["WSPR_SLOT_RAW"] else {
            throw XCTSkip("set WSPR_SLOT_RAW=/path/to/slot.raw")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var samples = [Float](repeating: 0, count: data.count / 4)
        samples.withUnsafeMutableBytes { _ = data.copyBytes(to: $0) }
        var sumSq = 0.0
        for s in samples {
            sumSq += Double(s) * Double(s)
        }
        print(String(format: "loaded %d samples (%.1f s), rms %.5f",
                     samples.count, Double(samples.count) / 12_000.0,
                     (sumSq / Double(max(samples.count, 1))).squareRoot()))
        let spots = WSPRDecoder.decode(samples, deadline: Date().addingTimeInterval(300))
        for s in spots {
            print(String(format: "spot: %@ %@ %ddBm  audio %.1f Hz  dt %.1f  snr %+.1f",
                         s.call, s.grid, s.dBm, s.audioFrequencyHz, s.dtSeconds, s.snrDB))
        }
        print("total spots: \(spots.count)")

        // Optional: stage-by-stage trace at specific audio frequencies
        // (comma-separated Hz in WSPR_SLOT_HZ)
        if let hzList = ProcessInfo.processInfo.environment["WSPR_SLOT_HZ"] {
            for hzText in hzList.split(separator: ",") {
                guard let hz = Double(hzText) else { continue }
                print("--- diagnose \(hz) Hz ---")
                for line in WSPRDecoder.diagnose(samples, expectedAudioHz: hz,
                                                 call: "K1ABC", grid: "FN42", dBm: 30) {
                    print(line)
                }
            }
        }
    }
}
