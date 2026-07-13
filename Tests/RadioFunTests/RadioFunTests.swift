import XCTest
import CoreLocation
@testable import RadioFun

final class FT8DecoderTests: XCTestCase {
    func testDecodesGeneratedWav() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cq_w0cjw_en35", withExtension: "wav", subdirectory: "Fixtures"))
        let samples = try loadMono16WAV(url)
        XCTAssertGreaterThan(samples.count, 12 * FT8Decoder.sampleRate)

        let decoder = try XCTUnwrap(FT8Decoder())
        let results = decoder.decodeSlot(samples)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.text, "CQ W0CJW EN35")
        XCTAssertEqual(results.first?.freqHz ?? 0, 1000, accuracy: 5)

        // Decoder resets between slots: silence must not re-decode the old slot
        let silence = [Float](repeating: 0, count: 15 * FT8Decoder.sampleRate)
        XCTAssertEqual(decoder.decodeSlot(silence).count, 0)
    }

    /// Minimal 16-bit mono PCM WAV reader for fixtures (44-byte canonical header).
    private func loadMono16WAV(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let body = data.dropFirst(44)
        var samples = [Float]()
        samples.reserveCapacity(body.count / 2)
        var index = body.startIndex
        while index + 1 < body.endIndex {
            let lo = UInt16(body[index])
            let hi = UInt16(body[index + 1])
            let value = Int16(bitPattern: (hi << 8) | lo)
            samples.append(Float(value) / 32768.0)
            index += 2
        }
        return samples
    }
}

final class FT8MessageParserTests: XCTestCase {
    func testCQWithGrid() {
        let p = FT8MessageParser.parse("CQ W0CJW EN35")
        XCTAssertEqual(p.sender, "W0CJW")
        XCTAssertEqual(p.grid, "EN35")
        XCTAssertTrue(p.isCQ)
    }

    func testCQWithModifier() {
        let p = FT8MessageParser.parse("CQ POTA K1ABC FN42")
        XCTAssertEqual(p.sender, "K1ABC")
        XCTAssertEqual(p.grid, "FN42")
    }

    func testCQWithoutGrid() {
        let p = FT8MessageParser.parse("CQ K1ABC")
        XCTAssertEqual(p.sender, "K1ABC")
        XCTAssertNil(p.grid)
    }

    func testReplyWithGrid() {
        let p = FT8MessageParser.parse("W0CJW K1ABC FN42")
        XCTAssertEqual(p.sender, "K1ABC")
        XCTAssertEqual(p.addressee, "W0CJW")
        XCTAssertEqual(p.grid, "FN42")
        XCTAssertFalse(p.isCQ)
    }

    func testCQHasNoAddressee() {
        XCTAssertNil(FT8MessageParser.parse("CQ K1ABC FN42").addressee)
    }

    func testHashedAddressee() {
        let p = FT8MessageParser.parse("<PJ4/K1ABC> W0CJW RR73")
        XCTAssertEqual(p.addressee, "PJ4/K1ABC")
        XCTAssertEqual(p.sender, "W0CJW")
    }

    func testSignalReportIsNotAGrid() {
        let p = FT8MessageParser.parse("K1ABC W0CJW -07")
        XCTAssertEqual(p.sender, "W0CJW")
        XCTAssertNil(p.grid)
    }

    func testRR73IsNotAGrid() {
        let p = FT8MessageParser.parse("K1ABC W0CJW RR73")
        XCTAssertEqual(p.sender, "W0CJW")
        XCTAssertNil(p.grid)
    }

    func testHashedCallsign() {
        let p = FT8MessageParser.parse("<PJ4/K1ABC> W0CJW")
        XCTAssertEqual(p.sender, "W0CJW")
    }

    func testFreeTextHasNoSender() {
        let p = FT8MessageParser.parse("TNX BOB 73 GL")
        XCTAssertNil(p.sender)
        XCTAssertNil(p.grid)
    }
}

final class MaidenheadTests: XCTestCase {
    func testEN35Center() throws {
        let c = try XCTUnwrap(Maidenhead.coordinate(forGrid: "EN35"))
        XCTAssertEqual(c.latitude, 45.5, accuracy: 0.01)   // EN35: lat 45–46
        XCTAssertEqual(c.longitude, -93.0, accuracy: 0.01) // lon -94…-92
    }

    func testSixCharGrid() throws {
        let c = try XCTUnwrap(Maidenhead.coordinate(forGrid: "EN35fd"))
        XCTAssertEqual(c.latitude, 45.146, accuracy: 0.01)
        XCTAssertEqual(c.longitude, -93.542, accuracy: 0.01)
    }

    func testRoundTrip() throws {
        let minneapolis = CLLocationCoordinate2D(latitude: 44.9778, longitude: -93.2650)
        let grid = Maidenhead.grid(for: minneapolis)
        XCTAssertEqual(String(grid.prefix(4)), "EN34")
        let back = try XCTUnwrap(Maidenhead.coordinate(forGrid: grid))
        XCTAssertEqual(back.latitude, minneapolis.latitude, accuracy: 0.05)
        XCTAssertEqual(back.longitude, minneapolis.longitude, accuracy: 0.05)
    }

    func testInvalidGrids() {
        XCTAssertNil(Maidenhead.coordinate(forGrid: "ZZ99"))
        XCTAssertNil(Maidenhead.coordinate(forGrid: "E3"))
        XCTAssertFalse(Maidenhead.isValidGrid("RR73"))
        XCTAssertTrue(Maidenhead.isValidGrid("EN35"))
    }
}
