import XCTest
@testable import Squelch

final class SlotAlignmentTests: XCTestCase {

    func testOnTimeSlotIsAligned() {
        // Fired within tolerance of a WSPR boundary
        XCTAssertFalse(DecodeController.isMisaligned(now: 1_800_000_000.3, period: 120))
        XCTAssertFalse(DecodeController.isMisaligned(now: 1_800_000_004.9, period: 120))
    }

    func testBackloggedSlotIsMisaligned() {
        // The death-spiral case: handler starts 30–116 s after its boundary
        XCTAssertTrue(DecodeController.isMisaligned(now: 1_800_000_030, period: 120))
        XCTAssertTrue(DecodeController.isMisaligned(now: 1_800_000_100, period: 120))
    }

    func testFullPeriodLateSelfCorrects() {
        // ~One whole period late: the ring buffer holds the just-ended slot,
        // correctly aligned — decode it rather than dropping it
        XCTAssertFalse(DecodeController.isMisaligned(now: 1_800_000_119.5, period: 120))
    }

    func testFT8PeriodUsesSameTolerance() {
        XCTAssertFalse(DecodeController.isMisaligned(now: 1_800_000_001, period: 15))
        XCTAssertTrue(DecodeController.isMisaligned(now: 1_800_000_007.5, period: 15))
    }

    func testWSPRDecodeRespectsDeadline() {
        // A band-noise slot with an already-expired deadline must return
        // promptly instead of grinding through the candidate list
        var noise = [Float](repeating: 0, count: 12000 * 111)
        var seed: UInt64 = 0x5EED
        for i in noise.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            noise[i] = Float(Int64(bitPattern: seed) >> 40) / Float(1 << 23)
        }
        let start = Date()
        let results = WSPRDecoder.decode(noise, deadline: start)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(results.isEmpty)
        // Downconvert + FFT bank + alignment still run (bounded); only the
        // open-ended stack decoding is skipped
        XCTAssertLessThan(elapsed, 20)
    }
}
