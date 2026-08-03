import XCTest
@testable import Squelch

final class QSOBackfillerTests: XCTestCase {
    private func record(
        _ call: String = "K1ABC",
        grid: String? = nil,
        name: String? = nil,
        state: String? = nil
    ) -> QSORecord {
        QSORecord(
            id: UUID(), partner: call, partnerGrid: grid,
            reportSent: "-07", reportReceived: "-12",
            start: Date(timeIntervalSince1970: 1_000_000),
            end: Date(timeIntervalSince1970: 1_000_090),
            dialFrequencyMHz: 14.074, mode: "FT8",
            name: name, state: state
        )
    }

    private let entry = CallsignDirectory.Entry(
        name: "Jane Doe", city: "Newington", state: "CT",
        country: "United States", grid: "FN31PR", licenseClass: "General"
    )

    func testMergeFillsEmptyFields() {
        var r = record()
        XCTAssertTrue(r.merge(entry))
        XCTAssertEqual(r.name, "Jane Doe")
        XCTAssertEqual(r.partnerGrid, "FN31PR")
        XCTAssertEqual(r.state, "CT")
        XCTAssertEqual(r.country, "United States")
    }

    func testMergeNeverClobbersExistingName() {
        var r = record(name: "Joe")
        _ = r.merge(entry)
        XCTAssertEqual(r.name, "Joe")
        XCTAssertEqual(r.state, "CT") // other gaps still fill
    }

    func testMergeGridUpgradeOnlyWhenPrefixAgrees() {
        var matching = record(grid: "FN31")
        _ = matching.merge(entry)
        XCTAssertEqual(matching.partnerGrid, "FN31PR") // extends the heard square

        var portable = record(grid: "EM12")
        _ = portable.merge(entry)
        XCTAssertEqual(portable.partnerGrid, "EM12") // on-air grid wins

        var precise = record(grid: "FN31AA")
        _ = precise.merge(entry)
        XCTAssertEqual(precise.partnerGrid, "FN31AA") // 6-char never touched
    }

    func testMergeReportsNoChangeWhenComplete() {
        var r = record(grid: "FN31PR", name: "Jane Doe", state: "CT")
        r.country = "United States"
        XCTAssertFalse(r.merge(entry))
    }

    func testNeedsBackfillOnlyForUSCanadaWithGaps() {
        XCTAssertTrue(QSOBackfiller.needsBackfill(record("K1ABC")))
        XCTAssertTrue(QSOBackfiller.needsBackfill(record("VE3XYZ")))
        XCTAssertFalse(QSOBackfiller.needsBackfill(record("JA3XYZ"))) // HamDB won't have it
        var complete = record("K1ABC", name: "Jane Doe", state: "CT")
        XCTAssertFalse(QSOBackfiller.needsBackfill(complete))
        complete.state = nil
        XCTAssertTrue(QSOBackfiller.needsBackfill(complete)) // state gap alone qualifies
    }
}
