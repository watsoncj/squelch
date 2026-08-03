import XCTest
@testable import Squelch

final class DecodeStoreTests: XCTestCase {
    func testOwnLoopbackStaysInLogButNotStations() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("decodes-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        UserDefaults.standard.set("W0CJW", forKey: SettingsKeys.myCallsign)

        let store = DecodeStore(fileURL: tempURL)
        store.ingest(
            results: [
                FT8Result(snr: -8, timeOffset: 0.8, freqHz: 950, text: "CQ W0CJW DM79"),   // own loopback
                FT8Result(snr: -12, timeOffset: 0.7, freqHz: 1500, text: "CQ K1ABC FN42"),
            ],
            slotStart: Date(), myCoordinate: nil, dialFrequencyMHz: 28.074
        )

        XCTAssertEqual(store.messages.count, 2, "outgoing rows stay visible in the log")
        XCTAssertNil(store.stations["W0CJW"], "own call must not become a heard station")
        XCTAssertNotNil(store.stations["K1ABC"])
    }
}

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

    func testLegacyLineWithoutNewFieldsStillDecodes() {
        // A line written before name/notes/state/country existed
        let legacy = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","partner":"K1ABC","partnerGrid":"EN34","reportSent":"-07","reportReceived":"-12","start":"2024-01-01T00:00:00Z","end":"2024-01-01T00:01:30Z","dialFrequencyMHz":28.074,"mode":"FT8"}
        """
        try? (legacy + "\n").data(using: .utf8)?.write(to: tempURL)

        let log = QSOLog(fileURL: tempURL)
        XCTAssertEqual(log.records.count, 1)
        let loaded = log.records[0]
        XCTAssertEqual(loaded.partner, "K1ABC")
        XCTAssertNil(loaded.name)
        XCTAssertNil(loaded.notes)
        XCTAssertNil(loaded.state)
        XCTAssertNil(loaded.country)
    }

    func testEnrichedFieldsPersistAcrossReload() {
        let log = QSOLog(fileURL: tempURL)
        var enriched = record("K1ABC")
        enriched.name = "Joe Ham"
        enriched.notes = "POTA activation"
        enriched.state = "CT"
        enriched.country = "United States"
        log.append(enriched)

        let reloaded = QSOLog(fileURL: tempURL)
        XCTAssertEqual(reloaded.records.first?.name, "Joe Ham")
        XCTAssertEqual(reloaded.records.first?.notes, "POTA activation")
        XCTAssertEqual(reloaded.records.first?.state, "CT")
        XCTAssertEqual(reloaded.records.first?.country, "United States")
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
