import XCTest
@testable import Squelch

final class ADIFExporterTests: XCTestCase {
    private func record(
        mode: String = "FT8",
        start: Date = Date(timeIntervalSince1970: 1_752_950_400), // 2025-07-19 18:40:00 UTC
        name: String? = nil,
        notes: String? = nil,
        reportSent: String = "-07"
    ) -> QSORecord {
        QSORecord(
            id: UUID(), partner: "K1ABC", partnerGrid: "FN31PR",
            reportSent: reportSent, reportReceived: "-12",
            start: start, end: start.addingTimeInterval(90),
            dialFrequencyMHz: 14.074, mode: mode,
            name: name, notes: notes, state: "CT", country: "United States"
        )
    }

    func testFieldEncoding() {
        XCTAssertEqual(ADIFExporter.field("CALL", "K1ABC"), "<CALL:5>K1ABC ")
        XCTAssertEqual(ADIFExporter.field("NAME", nil), "")
        XCTAssertEqual(ADIFExporter.field("NAME", ""), "")
        // Length prefix is BYTES, not characters
        XCTAssertEqual(ADIFExporter.field("NAME", "José"), "<NAME:5>José ")
        // "<" needs no escaping — the length prefix covers it
        XCTAssertEqual(ADIFExporter.field("COMMENT", "a<b"), "<COMMENT:3>a<b ")
    }

    func testModeMapping() {
        XCTAssertEqual(ADIFExporter.modeFields("FT8").mode, "FT8")
        XCTAssertNil(ADIFExporter.modeFields("FT8").submode)
        XCTAssertEqual(ADIFExporter.modeFields("FT4").mode, "MFSK")
        XCTAssertEqual(ADIFExporter.modeFields("FT4").submode, "FT4")
        XCTAssertEqual(ADIFExporter.modeFields("SSB").mode, "SSB")
    }

    func testRecordLine() {
        let line = ADIFExporter.line(for: record(), stationCallsign: "W0CJW", myGrid: "DM79LB")
        XCTAssertTrue(line.contains("<CALL:5>K1ABC "))
        XCTAssertTrue(line.contains("<GRIDSQUARE:6>FN31PR "))
        XCTAssertTrue(line.contains("<MODE:3>FT8 "))
        XCTAssertFalse(line.contains("<SUBMODE"))
        XCTAssertTrue(line.contains("<QSO_DATE:8>20250719 "))
        XCTAssertTrue(line.contains("<TIME_ON:6>184000 "))
        XCTAssertTrue(line.contains("<TIME_OFF:6>184130 "))
        XCTAssertTrue(line.contains("<BAND:3>20m "))
        XCTAssertTrue(line.contains("<FREQ:6>14.074 "))
        XCTAssertTrue(line.contains("<RST_SENT:3>-07 "))
        XCTAssertTrue(line.contains("<RST_RCVD:3>-12 "))
        XCTAssertTrue(line.contains("<STATE:2>CT "))
        XCTAssertTrue(line.contains("<COUNTRY:13>United States "))
        XCTAssertTrue(line.contains("<MY_GRIDSQUARE:6>DM79LB "))
        XCTAssertTrue(line.contains("<STATION_CALLSIGN:5>W0CJW "))
        XCTAssertTrue(line.contains("<OPERATOR:5>W0CJW "))
        XCTAssertTrue(line.hasSuffix("<EOR>\n"))
    }

    func testUTCDateRollsPastLocalMidnight() {
        // 2025-07-19 23:30 UTC is still the 19th in UTC regardless of local zone
        let line = ADIFExporter.line(
            for: record(start: Date(timeIntervalSince1970: 1_752_967_800)),
            stationCallsign: "W0CJW", myGrid: nil
        )
        XCTAssertTrue(line.contains("<QSO_DATE:8>20250719 "))
        XCTAssertTrue(line.contains("<TIME_ON:6>233000 "))
    }

    func testFT4SubmodeAndMultilineNotes() {
        let line = ADIFExporter.line(
            for: record(mode: "FT4", name: "Jane", notes: "line one\nline two"),
            stationCallsign: "W0CJW", myGrid: nil
        )
        XCTAssertTrue(line.contains("<MODE:4>MFSK "))
        XCTAssertTrue(line.contains("<SUBMODE:3>FT4 "))
        XCTAssertTrue(line.contains("<NAME:4>Jane "))
        XCTAssertTrue(line.contains("<COMMENT:18>line one; line two "))
    }

    func testContestIDIncludedWhenTagged() {
        var tagged = record()
        tagged.contest = "ARRL-VHF"
        let line = ADIFExporter.line(for: tagged, stationCallsign: "W0CJW", myGrid: nil)
        XCTAssertTrue(line.contains("<CONTEST_ID:8>ARRL-VHF "))

        let untagged = ADIFExporter.line(for: record(), stationCallsign: "W0CJW", myGrid: nil)
        XCTAssertFalse(untagged.contains("<CONTEST_ID"))
    }

    func testEmptyReportAndZeroFrequencyOmitted() {
        var r = record(reportSent: "")
        r = QSORecord(
            id: r.id, partner: r.partner, partnerGrid: nil,
            reportSent: "", reportReceived: nil,
            start: r.start, end: r.end, dialFrequencyMHz: 0, mode: "SSB"
        )
        let line = ADIFExporter.line(for: r, stationCallsign: "W0CJW", myGrid: nil)
        XCTAssertFalse(line.contains("<RST_SENT"))
        XCTAssertFalse(line.contains("<RST_RCVD"))
        XCTAssertFalse(line.contains("<FREQ"))
        XCTAssertFalse(line.contains("<BAND"))
        XCTAssertFalse(line.contains("<GRIDSQUARE"))
    }

    func testFullFileShape() {
        let older = record(start: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = record(start: Date(timeIntervalSince1970: 1_752_950_400))
        // Log order is newest-first; the file must come out oldest-first
        let adi = ADIFExporter.adi(
            records: [newer, older], stationCallsign: "W0CJW", myGrid: "DM79",
            now: Date(timeIntervalSince1970: 1_752_950_400)
        )
        XCTAssertTrue(adi.contains("<ADIF_VER:5>3.1.4 "))
        XCTAssertTrue(adi.contains("<PROGRAMID:7>Squelch "))
        XCTAssertTrue(adi.contains("<CREATED_TIMESTAMP:15>20250719 184000 "))
        XCTAssertTrue(adi.contains("<EOH>\n"))
        XCTAssertEqual(adi.components(separatedBy: "<EOR>").count - 1, 2)
        let eohIndex = adi.range(of: "<EOH>")!.lowerBound
        XCTAssertFalse(adi[..<eohIndex].contains("<CALL"), "records only after header")
        let first = adi.range(of: "20231114")! // older record's UTC date
        let second = adi.range(of: "20250719 <TIME_ON")?.lowerBound ?? adi.range(of: "<QSO_DATE:8>20250719")!.lowerBound
        XCTAssertLessThan(first.lowerBound, second, "oldest first")
    }
}
