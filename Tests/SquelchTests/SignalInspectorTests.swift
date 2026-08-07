import XCTest
@testable import Squelch

final class SignalInspectorTests: XCTestCase {
    private func message(
        f: Float,
        slot: TimeInterval,
        dt: Float = 0.5,
        call: String? = "K1ABC",
        text: String = "CQ K1ABC EN52"
    ) -> DecodedMessage {
        DecodedMessage(
            id: UUID(),
            slotStart: Date(timeIntervalSince1970: slot),
            snr: -10,
            timeOffset: dt,
            audioFrequency: f,
            dialFrequencyMHz: 14.074,
            text: text,
            callsign: call,
            grid: nil,
            latitude: nil,
            longitude: nil,
            distanceKm: nil
        )
    }

    private func inspect(
        _ hz: Double, at t: TimeInterval, in messages: [DecodedMessage]
    ) -> SignalInspector.Result {
        SignalInspector.inspect(
            frequencyHz: hz,
            time: Date(timeIntervalSince1970: t),
            messages: messages,
            slotSeconds: 15,
            transmissionSeconds: 12.64
        )
    }

    func testClickInsideBoxHits() {
        let m = message(f: 1500, slot: 1005)
        guard case .hit(let hit) = inspect(1525, at: 1011, in: [m]) else {
            return XCTFail("expected hit")
        }
        XCTAssertEqual(hit.message.id, m.id)
        XCTAssertEqual(hit.alternates, 0)
    }

    func testEdgeToleranceStillHits() {
        // 8 Hz below the tone span's low edge — inside the 12 Hz tolerance
        let m = message(f: 1500, slot: 1005)
        guard case .hit = inspect(1492, at: 1011, in: [m]) else {
            return XCTFail("near-edge click should resolve to the box")
        }
    }

    func testMissReportsNearestInSlot() {
        let m = message(f: 1500, slot: 1005)
        guard case .miss(let miss) = inspect(1800, at: 1011, in: [m]) else {
            return XCTFail("expected miss")
        }
        XCTAssertEqual(miss.nearestInSlot?.id, m.id)
        XCTAssertEqual(miss.nearestHzAway ?? 0, 250, accuracy: 0.5) // 1800 − (1500+50)
    }

    func testDifferentSlotSameFrequencyMisses() {
        // Same frequency, but the transmission was two slots earlier
        let m = message(f: 1500, slot: 1005)
        guard case .miss(let miss) = inspect(1525, at: 1041, in: [m]) else {
            return XCTFail("stale transmission must not hit")
        }
        XCTAssertNil(miss.nearestInSlot, "decode from another slot is not 'nearest in slot'")
    }

    func testOverlappingBoxesPickNearestCenterAndCountAlternates() {
        let a = message(f: 1500, slot: 1005, call: "A1AA")
        let b = message(f: 1530, slot: 1005, call: "B2BB")
        // 1560 is inside both boxes (a: 1500–1550+tol, b: 1530–1580);
        // b's center (1555) is closer
        guard case .hit(let hit) = inspect(1560, at: 1011, in: [a, b]) else {
            return XCTFail("expected hit")
        }
        XCTAssertEqual(hit.message.callsign, "B2BB")
        XCTAssertEqual(hit.alternates, 1)
    }
}
