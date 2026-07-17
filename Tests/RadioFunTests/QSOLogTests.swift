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
