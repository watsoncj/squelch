import XCTest
@testable import Squelch

/// The feed's worked seal: filled for a dupe (same band, same contest
/// context), outline for a station known from elsewhere in the log.
final class WorkedBadgeTests: XCTestCase {
    private func record(_ call: String, mhz: Double, contest: String? = nil) -> QSORecord {
        QSORecord(
            id: UUID(), partner: call, partnerGrid: nil, reportSent: "-05", reportReceived: nil,
            start: Date(), end: Date(), dialFrequencyMHz: mhz, mode: "FT8", contest: contest
        )
    }

    func testDupesAreScopedToBandAndContest() {
        let records = [
            record("K1ABC", mhz: 14.074),                        // casual, 20 m
            record("W9XYZ", mhz: 14.074, contest: "WW-DIGI"),    // contest, 20 m
            record("N0FW", mhz: 7.074, contest: "WW-DIGI"),      // contest, 40 m
        ]
        // Contest on 20 m: only the contest QSO on 20 m is a dupe
        XCTAssertEqual(CQHunter.dupeCalls(records: records, dialMHz: 14.074, contest: "WW-DIGI"), ["W9XYZ"])
        // Contest on 40 m: N0FW is the dupe; W9XYZ is workable again
        XCTAssertEqual(CQHunter.dupeCalls(records: records, dialMHz: 7.074, contest: "WW-DIGI"), ["N0FW"])
        // No contest on 20 m: the casual contact is the dupe, not the contest one
        XCTAssertEqual(CQHunter.dupeCalls(records: records, dialMHz: 14.074, contest: nil), ["K1ABC"])
        // Same band, different dial frequency (FT4 sub-band) still counts
        XCTAssertEqual(CQHunter.dupeCalls(records: records, dialMHz: 14.080, contest: nil), ["K1ABC"])
    }

    func testWorkedStateClassification() {
        let worked: Set<String> = ["K1ABC", "W9XYZ"]
        let dupes: Set<String> = ["W9XYZ"]
        XCTAssertEqual(WorkedState.of("W9XYZ", dupes: dupes, worked: worked), .dupe)
        XCTAssertEqual(WorkedState.of("k1abc", dupes: dupes, worked: worked), .elsewhere, "case-insensitive")
        XCTAssertEqual(WorkedState.of("N0FW", dupes: dupes, worked: worked), .no)
        XCTAssertEqual(WorkedState.of(nil, dupes: dupes, worked: worked), .no)
    }

    func testHelpWordingNamesTheContest() {
        XCTAssertTrue(WorkedState.dupe.help(contestName: "WW-DIGI").hasPrefix("Dupe — worked in WW-DIGI"))
        XCTAssertTrue(WorkedState.elsewhere.help(contestName: "WW-DIGI").contains("still workable"))
        XCTAssertEqual(WorkedState.dupe.help(contestName: nil), "Worked before on this band")
        XCTAssertEqual(WorkedState.no.help(contestName: nil), "")
    }
}
