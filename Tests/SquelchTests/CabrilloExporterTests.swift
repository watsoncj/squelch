import XCTest
@testable import Squelch

final class CabrilloExporterTests: XCTestCase {
    private func record(
        mode: String = "FT8",
        mhz: Double = 14.074,
        grid: String? = "FN31PR",
        state: String? = nil,
        start: Date = Date(timeIntervalSince1970: 1_752_950_400) // 2025-07-19 18:40 UTC
    ) -> QSORecord {
        QSORecord(
            id: UUID(), partner: "K1ABC", partnerGrid: grid,
            reportSent: "-07", reportReceived: "-12",
            start: start, end: start.addingTimeInterval(90),
            dialFrequencyMHz: mhz, mode: mode, state: state
        )
    }

    func testModeCodes() {
        XCTAssertEqual(CabrilloExporter.modeCode("FT8"), "DG")
        XCTAssertEqual(CabrilloExporter.modeCode("FT4"), "DG")
        XCTAssertEqual(CabrilloExporter.modeCode("SSB"), "PH")
        XCTAssertEqual(CabrilloExporter.modeCode("AM"), "PH")
        XCTAssertEqual(CabrilloExporter.modeCode("FM"), "FM")
        XCTAssertEqual(CabrilloExporter.modeCode("CW"), "CW")
        XCTAssertEqual(CabrilloExporter.modeCode("RTTY"), "RY")
    }

    func testFreqField() {
        XCTAssertEqual(CabrilloExporter.freqField(14.074), "14074")
        XCTAssertEqual(CabrilloExporter.freqField(28.1246), "28125") // rounds
        XCTAssertEqual(CabrilloExporter.freqField(144.174), "144")   // VHF band designator
        XCTAssertEqual(CabrilloExporter.freqField(432.3), "432")
        XCTAssertEqual(CabrilloExporter.freqField(0), "0")
    }

    /// WW Digi's line: no reports, grids alone, trailing transmitter id.
    func testWWDigiLineIsGridOnly() {
        XCTAssertEqual(CabrilloExporter.exchangeStyle(for: "WW-DIGI"), .gridOnly)
        XCTAssertEqual(CabrilloExporter.exchangeStyle(for: "ww digi"), .gridOnly)
        XCTAssertEqual(CabrilloExporter.exchangeStyle(for: "ARRL-VHF-SEP"), .gridOnly)
        XCTAssertEqual(CabrilloExporter.exchangeStyle(for: "ARRL-FD"), .reportAndGrid)
        XCTAssertEqual(CabrilloExporter.exchangeStyle(for: nil), .reportAndGrid)

        let line = CabrilloExporter.qsoLine(
            for: record(grid: "en52xx"), stationCallsign: "W0CJW", myGrid4: "DM79", style: .gridOnly
        )
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        XCTAssertEqual(fields, ["QSO:", "14074", "DG", "2025-07-19", "1840",
                                "W0CJW", "DM79", "K1ABC", "EN52", "0"])
    }

    func testContestNameCanonicalized() {
        XCTAssertEqual(CabrilloExporter.canonicalContest("WW Digi"), "WW-DIGI")
        XCTAssertEqual(CabrilloExporter.canonicalContest("wwdigi"), "WW-DIGI")
        XCTAssertEqual(CabrilloExporter.canonicalContest("WW-DIGI"), "WW-DIGI")
        XCTAssertEqual(CabrilloExporter.canonicalContest(" ARRL-FD "), "ARRL-FD")
        XCTAssertNil(CabrilloExporter.canonicalContest(""))
        XCTAssertNil(CabrilloExporter.canonicalContest(nil))
    }

    /// Every header WW Digi's spec lists as required, in a full log.
    func testWWDigiHeaders() {
        var r = record(mhz: 14.074)
        r.txPowerWatts = 100
        let log = CabrilloExporter.log(
            records: [r, record(mhz: 7.074)], stationCallsign: "W0CJW", myGrid: "DM79LB",
            contest: "WW Digi", location: "CO"
        )
        for header in ["START-OF-LOG: 3.0", "CONTEST: WW-DIGI", "CALLSIGN: W0CJW",
                       "CATEGORY-OPERATOR: SINGLE-OP", "CATEGORY-BAND: ALL", "CATEGORY-MODE: DIGI",
                       "CATEGORY-POWER: LOW", "CATEGORY-TRANSMITTER: ONE", "CATEGORY-STATION: FIXED",
                       "LOCATION: CO", "GRID-LOCATOR: DM79", "CREATED-BY: Squelch", "END-OF-LOG:"] {
            XCTAssertTrue(log.contains(header + "\n"), "missing \(header)")
        }
        XCTAssertTrue(log.contains("QSO: 14074 DG 2025-07-19 1840 W0CJW         DM79   K1ABC         FN31   0\n"),
                      "grid-only QSO line with txid")
        XCTAssertFalse(log.contains(" -12 "), "no reports in a WW Digi log")
    }

    func testCategoryDerivation() {
        XCTAssertEqual(CabrilloExporter.categoryBand([record(mhz: 14.074), record(mhz: 14.080)]), "20M")
        XCTAssertEqual(CabrilloExporter.categoryBand([record(mhz: 14.074), record(mhz: 7.074)]), "ALL")
        XCTAssertEqual(CabrilloExporter.categoryBand([record(mhz: 144.174)]), "2M")
        XCTAssertEqual(CabrilloExporter.categoryBand([]), "ALL")

        XCTAssertEqual(CabrilloExporter.categoryMode([record(mode: "FT8"), record(mode: "FT4")]), "DIGI")
        XCTAssertEqual(CabrilloExporter.categoryMode([record(mode: "SSB")]), "SSB")
        XCTAssertEqual(CabrilloExporter.categoryMode([record(mode: "CW"), record(mode: "FT8")]), "MIXED")
        XCTAssertEqual(CabrilloExporter.categoryMode([]), "DIGI")

        var qrp = record(); qrp.txPowerWatts = 5
        var low = record(); low.txPowerWatts = 100
        var high = record(); high.txPowerWatts = 500
        XCTAssertEqual(CabrilloExporter.categoryPower([qrp]), "QRP")
        XCTAssertEqual(CabrilloExporter.categoryPower([qrp, low]), "LOW")
        XCTAssertEqual(CabrilloExporter.categoryPower([low, high]), "HIGH")
        XCTAssertEqual(CabrilloExporter.categoryPower([record()]), "LOW")
    }

    func testLocationDefaults() {
        XCTAssertEqual(CabrilloExporter.locationField(" co ", stationCallsign: "W0CJW"), "CO")
        XCTAssertEqual(CabrilloExporter.locationField(nil, stationCallsign: "W0CJW"), "", "US station must fill in a section")
        XCTAssertEqual(CabrilloExporter.locationField("", stationCallsign: "VE3ABC"), "")
        XCTAssertEqual(CabrilloExporter.locationField(nil, stationCallsign: "G4ABC"), "DX")
        XCTAssertEqual(CabrilloExporter.locationField(nil, stationCallsign: "JA1ABC"), "DX")
    }

    /// The received grid is the exchange in a grid-only contest: never
    /// filled from a license lookup, and flagged when missing.
    func testGridOnlyContestKeepsMissingGridMissing() {
        let entry = CallsignDirectory.Entry(
            name: "Jimmy", city: nil, state: "IN", country: "United States", grid: "EM69WQ", licenseClass: nil
        )
        var contestQSO = record(grid: nil)
        contestQSO.contest = "WW-DIGI"
        XCTAssertTrue(contestQSO.merge(entry))
        XCTAssertNil(contestQSO.partnerGrid, "license grid must not pose as the received exchange")
        XCTAssertEqual(contestQSO.name, "Jimmy")
        XCTAssertEqual(contestQSO.state, "IN")

        var heard4 = record(grid: "EM69")
        heard4.contest = "WW-DIGI"
        _ = heard4.merge(entry)
        XCTAssertEqual(heard4.partnerGrid, "EM69WQ", "a heard grid may still extend to the license's 6-char square")

        var casual = record(grid: nil)
        XCTAssertTrue(casual.merge(entry))
        XCTAssertEqual(casual.partnerGrid, "EM69WQ", "casual QSOs keep the backfill")

        XCTAssertEqual(CabrilloExporter.missingExchange(records: [contestQSO, heard4], contest: "WW-DIGI").map(\.partner),
                       [contestQSO.partner])
        XCTAssertTrue(CabrilloExporter.missingExchange(records: [casual], contest: "ARRL-FD").isEmpty,
                      "only grid-only contests are checked")
    }

    func testQSOLineFieldsInOrder() {
        let line = CabrilloExporter.qsoLine(
            for: record(), stationCallsign: "W0CJW", myGrid4: "DM79"
        )
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        XCTAssertEqual(fields, ["QSO:", "14074", "DG", "2025-07-19", "1840",
                                "W0CJW", "-07", "DM79", "K1ABC", "-12", "FN31"])
        XCTAssertTrue(line.hasSuffix("\n"))
    }

    func testExchangeFallsBackToStateThenDashes() {
        let stateLine = CabrilloExporter.qsoLine(
            for: record(grid: nil, state: "CT"), stationCallsign: "W0CJW", myGrid4: "DM79"
        )
        XCTAssertTrue(stateLine.split(whereSeparator: \.isWhitespace).map(String.init).contains("CT"))

        let bareLine = CabrilloExporter.qsoLine(
            for: record(grid: nil), stationCallsign: "W0CJW", myGrid4: ""
        )
        let fields = bareLine.split(whereSeparator: \.isWhitespace).map(String.init)
        XCTAssertEqual(fields.filter { $0 == "----" }.count, 2) // both exchanges unknown
    }

    func testFullLogShape() {
        let older = record(start: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = record()
        let log = CabrilloExporter.log(
            records: [newer, older], stationCallsign: "W0CJW", myGrid: "DM79LB"
        )
        XCTAssertTrue(log.hasPrefix("START-OF-LOG: 3.0\n"))
        XCTAssertTrue(log.contains("CALLSIGN: W0CJW\n"))
        XCTAssertTrue(log.contains("GRID-LOCATOR: DM79\n")) // 6-char trimmed to 4
        XCTAssertTrue(log.contains("CONTEST: \n"))
        let contested = CabrilloExporter.log(
            records: [newer], stationCallsign: "W0CJW", myGrid: "DM79LB",
            contest: "ARRL-VHF"
        )
        XCTAssertTrue(contested.contains("CONTEST: ARRL-VHF\n"))
        XCTAssertTrue(log.contains("CREATED-BY: Squelch\n"))
        XCTAssertTrue(log.hasSuffix("END-OF-LOG:\n"))
        XCTAssertEqual(log.components(separatedBy: "QSO:").count - 1, 2)
        // Oldest first
        let first = log.range(of: "2023-11-14")!
        let second = log.range(of: "2025-07-19")!
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
    }
}
