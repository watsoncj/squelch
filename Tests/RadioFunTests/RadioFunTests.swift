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

    func testUSCallsignClassification() {
        XCTAssertTrue(FT8MessageParser.isUSCallsign("W0CJW"))
        XCTAssertTrue(FT8MessageParser.isUSCallsign("K1ABC"))
        XCTAssertTrue(FT8MessageParser.isUSCallsign("N4NJJ"))
        XCTAssertTrue(FT8MessageParser.isUSCallsign("AL5G"))   // AA–AL block
        XCTAssertTrue(FT8MessageParser.isUSCallsign("KH6PQR")) // Hawaii
        XCTAssertTrue(FT8MessageParser.isUSCallsign("K1ABC/7")) // portable, still US

        XCTAssertFalse(FT8MessageParser.isUSCallsign("VE3XYZ"))    // Canada
        XCTAssertFalse(FT8MessageParser.isUSCallsign("JA1UQA"))    // Japan
        XCTAssertFalse(FT8MessageParser.isUSCallsign("G4JKL"))     // England
        XCTAssertFalse(FT8MessageParser.isUSCallsign("AM1X"))      // Spain (AM–AO)
        XCTAssertFalse(FT8MessageParser.isUSCallsign("PJ4/K1ABC")) // US op abroad
        XCTAssertFalse(FT8MessageParser.isUSCallsign("SU9GA"))     // Egypt
    }
}

final class CallsignCountryTests: XCTestCase {
    private func name(_ call: String) -> String? {
        CallsignCountry.lookup(call)?.name
    }

    func testCommonPrefixes() {
        XCTAssertEqual(name("W0CJW"), "USA")
        XCTAssertEqual(name("VE3MNO"), "Canada")
        XCTAssertEqual(name("JA1UQA"), "Japan")
        XCTAssertEqual(name("G4JKL"), "England")
        XCTAssertEqual(name("DL2ABC"), "Germany")
        XCTAssertEqual(name("SU9GA"), "Egypt")
        XCTAssertEqual(name("ZB2FTY"), "Gibraltar")
        XCTAssertEqual(name("V31MA"), "Belize")
        XCTAssertEqual(name("XE1ABC"), "Mexico")
        XCTAssertEqual(name("HK3C"), "Colombia")
        XCTAssertEqual(name("XQ3SK"), "Chile") // XQ/XR blocks, not just CA–CE
        XCTAssertEqual(name("CE2ABC"), "Chile")
    }

    func testLongestPrefixWins() {
        XCTAssertEqual(name("DU1PH"), "Philippines") // not Germany's D block
        XCTAssertEqual(name("DS5KOR"), "South Korea")
        XCTAssertEqual(name("UR5UKR"), "Ukraine")    // not Russia's U block
        XCTAssertEqual(name("UA3RUS"), "Russia")
        XCTAssertEqual(name("EA8CAN"), "Canary Is.") // not mainland Spain
        XCTAssertEqual(name("EA3ESP"), "Spain")
        XCTAssertEqual(name("KH6HI"), "Hawaii")
        XCTAssertEqual(name("MW1WAL"), "Wales")
    }

    func testCompoundCallsUseLocationPrefix() {
        XCTAssertEqual(name("PJ4/K1ABC"), "Curaçao/Bonaire")
        XCTAssertEqual(name("K1ABC/7"), "USA")
    }

    func testDXpeditionFavorites() {
        XCTAssertEqual(name("D4C"), "Cape Verde")
        XCTAssertEqual(name("V51WH"), "Namibia")
        XCTAssertEqual(name("T88AB"), "Palau")
        XCTAssertEqual(name("4O3X"), "Montenegro")
        XCTAssertEqual(name("FO/W0CJW"), "French Polynesia")
        XCTAssertEqual(name("CU2AB"), "Azores")
        XCTAssertEqual(name("CT1AB"), "Portugal")
        XCTAssertEqual(name("3A2MW"), "Monaco")
    }

    func testDistanceUnits() {
        XCTAssertEqual(DistanceUnit.miles.text(fromKm: 100), "62 mi")
        XCTAssertEqual(DistanceUnit.kilometers.text(fromKm: 100), "100 km")
        XCTAssertEqual(DistanceUnit.current("Kilometers"), .kilometers)
        XCTAssertEqual(DistanceUnit.current("bogus"), .miles) // default
        XCTAssertEqual(TimeDisplay.current("Local"), .local)
        XCTAssertEqual(TimeDisplay.current(""), .utc) // default
        XCTAssertEqual(TimeDisplay.utc.formatter.timeZone.secondsFromGMT(), 0)
    }

    func testUnknownPrefix() {
        XCTAssertNil(CallsignCountry.lookup("S01WS")) // Western Sahara: not in the table
        XCTAssertNil(CallsignCountry.lookup(""))
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
