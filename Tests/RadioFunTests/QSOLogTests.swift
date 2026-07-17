import XCTest
@testable import RadioFun

final class QSOLogTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qsolog-test-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
    }

    private func record(_ call: String, mode: String = "FT8") -> QSORecord {
        QSORecord(
            id: UUID(), partner: call, partnerGrid: "EN34",
            reportSent: "-07", reportReceived: "-12",
            start: Date(timeIntervalSince1970: 1_000_000),
            end: Date(timeIntervalSince1970: 1_000_090),
            dialFrequencyMHz: 28.074, mode: mode
        )
    }

    func testAppendPersistsAcrossReload() {
        let log = QSOLog(fileURL: tempURL)
        log.append(record("K1ABC"))
        log.append(record("N5CAR", mode: "SSB")) // manual-entry shape

        let reloaded = QSOLog(fileURL: tempURL)
        XCTAssertEqual(reloaded.records.count, 2)
        XCTAssertEqual(reloaded.records.first?.partner, "N5CAR") // newest first
        XCTAssertEqual(reloaded.records.first?.mode, "SSB")
        XCTAssertEqual(reloaded.records.last?.partner, "K1ABC")
    }

    func testUpdatePreservesPositionAndPersists() {
        let log = QSOLog(fileURL: tempURL)
        let original = record("K1ABC")
        log.append(original)
        log.append(record("N5CAR"))

        var edited = original
        edited = QSORecord(
            id: original.id, partner: "K1ABC", partnerGrid: "EN52",
            reportSent: "-05", reportReceived: original.reportReceived,
            start: original.start, end: original.end,
            dialFrequencyMHz: original.dialFrequencyMHz, mode: "FT4"
        )
        log.update(edited)

        XCTAssertEqual(log.records.map(\.partner), ["N5CAR", "K1ABC"]) // position kept
        XCTAssertEqual(log.records.last?.partnerGrid, "EN52")

        let reloaded = QSOLog(fileURL: tempURL)
        XCTAssertEqual(reloaded.records.last?.mode, "FT4")
        XCTAssertEqual(reloaded.records.last?.reportSent, "-05")
    }

    func testDeleteRewritesFile() {
        let log = QSOLog(fileURL: tempURL)
        let keep = record("K1ABC")
        let drop = record("N5CAR")
        log.append(keep)
        log.append(drop)

        log.delete([drop.id])
        XCTAssertEqual(log.records.map(\.partner), ["K1ABC"])

        let reloaded = QSOLog(fileURL: tempURL)
        XCTAssertEqual(reloaded.records.map(\.partner), ["K1ABC"])
    }
}
