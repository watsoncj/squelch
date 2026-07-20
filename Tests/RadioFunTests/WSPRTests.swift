import XCTest
@testable import RadioFun

final class WSPRTests: XCTestCase {
    /// Full round trip through the Swift wrappers and the vendored decoder.
    func testEncodeDecodeLoopback() throws {
        var audio = try XCTUnwrap(
            WSPREncoder.encode(call: "W0CJW", grid4: "DM79", dbm: 37, frequencyHz: 1507.3),
            "encode failed"
        )
        XCTAssertEqual(Double(audio.count) / 12000.0, 111.6, accuracy: 0.5)

        // Pad to a full 2-minute slot's worth of capture
        audio.append(contentsOf: [Float](repeating: 0, count: 119 * FT8Decoder.sampleRate - audio.count))

        let spots = WSPRDecoderEngine.decodeSlot(audio, rcall: "W0CJW", rgrid: "DM79", dialHz: 28_124_600)
        XCTAssertEqual(spots.count, 1)
        let spot = try XCTUnwrap(spots.first)
        XCTAssertEqual(spot.call, "W0CJW")
        XCTAssertEqual(spot.grid, "DM79")
        XCTAssertEqual(spot.powerDBm, 37)
        // Absolute RF frequency: dial + audio offset
        XCTAssertEqual(spot.frequencyHz, 28_124_600 + 1507.3, accuracy: 3)
    }

    func testShortCallAndDifferentGrid() throws {
        var audio = try XCTUnwrap(
            WSPREncoder.encode(call: "K1AB", grid4: "FN42", dbm: 30, frequencyHz: 1450)
        )
        audio.append(contentsOf: [Float](repeating: 0, count: 119 * FT8Decoder.sampleRate - audio.count))
        let spots = WSPRDecoderEngine.decodeSlot(audio, rcall: "W0CJW", rgrid: "DM79", dialHz: 28_124_600)
        XCTAssertEqual(spots.first?.call, "K1AB")
        XCTAssertEqual(spots.first?.grid, "FN42")
        XCTAssertEqual(spots.first?.powerDBm, 30)
    }

    /// Regression: wsprd's stack frames (hashtab/loctab, subtraction
    /// buffers) overflowed the 512 KB dispatch-queue stack in live use —
    /// the CLI harness passed only because main threads get 8 MB.
    func testDecodeOnDispatchQueueStack() throws {
        var audio = try XCTUnwrap(
            WSPREncoder.encode(call: "W0CJW", grid4: "DM79", dbm: 37, frequencyHz: 1500)
        )
        audio.append(contentsOf: [Float](repeating: 0, count: 119 * FT8Decoder.sampleRate - audio.count))

        let expectation = expectation(description: "decode on worker stack")
        var spots: [WSPRSpot] = []
        DispatchQueue(label: "test.wspr.decode", qos: .userInitiated).async {
            spots = WSPRDecoderEngine.decodeSlot(audio, rcall: "W0CJW", rgrid: "DM79", dialHz: 28_124_600)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 20)
        XCTAssertEqual(spots.first?.call, "W0CJW")
    }

    func testEncodeRejectsInvalidInput() {
        XCTAssertNil(WSPREncoder.encode(call: "NODIGITS", grid4: "DM79", dbm: 37, frequencyHz: 1500))
        XCTAssertNil(WSPREncoder.encode(call: "W0CJW", grid4: "ZZ99", dbm: 37, frequencyHz: 1500))
    }

    /// The synthesized log row parses like any other message: sender + grid.
    func testSpotRowParsesForMapAndLog() {
        let parsed = FT8MessageParser.parse("WSPR K1ABC EN52 37dBm")
        XCTAssertEqual(parsed.sender, "K1ABC")
        XCTAssertEqual(parsed.grid, "EN52")
        XCTAssertFalse(parsed.isCQ)
        XCTAssertNil(parsed.addressee) // "WSPR" is not a callsign
    }

    /// The synthetic TX row must stay display-only: no sender, no grid,
    /// no addressee — it can't become a station or map cell.
    func testBeaconTXRowIsInert() {
        let parsed = FT8MessageParser.parse("TX WSPR W0CJW DM79 37dBm")
        XCTAssertNil(parsed.sender)
        XCTAssertNil(parsed.grid)
        XCTAssertNil(parsed.addressee)
        XCTAssertFalse(parsed.isCQ)
    }

    func testWSPRModeProperties() {
        XCTAssertEqual(DigiMode.wspr.slotSeconds, 120)
        XCTAssertFalse(DigiMode.wspr.supportsQSO)
        XCTAssertTrue(DigiMode.ft8.supportsQSO)
    }
}
