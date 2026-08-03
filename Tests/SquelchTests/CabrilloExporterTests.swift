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
