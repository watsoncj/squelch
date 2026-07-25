import XCTest
@testable import Squelch

final class BeaconDecisionTests: XCTestCase {

    func testRollAgainstDuty() {
        // roll < duty transmits, roll >= duty stays quiet
        XCTAssertTrue(AppModel.beaconDecision(dutyPct: 10, windowsSinceTX: 3, justTransmitted: false, roll: 9.9))
        XCTAssertFalse(AppModel.beaconDecision(dutyPct: 10, windowsSinceTX: 3, justTransmitted: false, roll: 10.0))
        XCTAssertFalse(AppModel.beaconDecision(dutyPct: 10, windowsSinceTX: 3, justTransmitted: false, roll: 55))
    }

    func testListenAfterTransmit() {
        // Never two consecutive beacon windows, even on a winning roll
        XCTAssertFalse(AppModel.beaconDecision(dutyPct: 10, windowsSinceTX: 0, justTransmitted: true, roll: 0))
        XCTAssertFalse(AppModel.beaconDecision(dutyPct: 50, windowsSinceTX: 0, justTransmitted: true, roll: 0))
    }

    func testBoundedGapForcesTransmit() {
        // 10% duty → forced no later than the 20th quiet window
        XCTAssertFalse(AppModel.beaconDecision(dutyPct: 10, windowsSinceTX: 18, justTransmitted: false, roll: 99))
        XCTAssertTrue(AppModel.beaconDecision(dutyPct: 10, windowsSinceTX: 19, justTransmitted: false, roll: 99))
        // 20% duty → forced at 10 quiet windows
        XCTAssertTrue(AppModel.beaconDecision(dutyPct: 20, windowsSinceTX: 9, justTransmitted: false, roll: 99))
    }

    func testUnsetDutyDefendsWithFloor() {
        // A zero/unset duty clamps to 1%, never divide-by-zero
        XCTAssertFalse(AppModel.beaconDecision(dutyPct: 0, windowsSinceTX: 0, justTransmitted: false, roll: 50))
        XCTAssertTrue(AppModel.beaconDecision(dutyPct: 0, windowsSinceTX: 199, justTransmitted: false, roll: 99))
    }

    func testTenPercentDutyLongRunAverage() {
        // Simulate a long armed session with deterministic pseudo-rolls:
        // effective TX rate must land near 10% (bounded-gap slightly lifts it)
        var seed: UInt64 = 42
        func roll() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53) * 100
        }
        var quiet = 0
        var justTransmitted = false
        var txCount = 0
        let windows = 10_000
        for _ in 0..<windows {
            let tx = AppModel.beaconDecision(dutyPct: 10, windowsSinceTX: quiet, justTransmitted: justTransmitted, roll: roll())
            if tx {
                txCount += 1
                quiet = 0
                justTransmitted = true
            } else {
                quiet += 1
                justTransmitted = false
            }
        }
        let rate = Double(txCount) / Double(windows)
        XCTAssertGreaterThan(rate, 0.08)
        XCTAssertLessThan(rate, 0.14)
    }
}
