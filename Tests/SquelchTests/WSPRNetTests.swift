import XCTest
@testable import Squelch

final class WSPRNetTests: XCTestCase {

    // MARK: - Reports query

    func testReportsQueryURLTargetsWSPRLive() throws {
        let url = try XCTUnwrap(WSPRNetService.reportsQueryURL(call: "W0CJW"))
        XCTAssertEqual(url.host, "db1.wspr.live")
        let query = try XCTUnwrap(url.query?.removingPercentEncoding)
        XCTAssertTrue(query.contains("tx_sign = 'W0CJW'"))
        XCTAssertTrue(query.contains("FORMAT JSON"))
    }

    func testReportsQueryURLSanitizesCallsign() throws {
        // Injection attempt collapses to the legal characters only
        let url = try XCTUnwrap(WSPRNetService.reportsQueryURL(call: "w0'; DROP TABLE--cjw"))
        let query = try XCTUnwrap(url.query?.removingPercentEncoding)
        XCTAssertTrue(query.contains("tx_sign = 'W0DROPTABLECJW'"))
        XCTAssertFalse(query.contains("';"))
        XCTAssertNil(WSPRNetService.reportsQueryURL(call: "'"))
        XCTAssertNil(WSPRNetService.reportsQueryURL(call: ""))
    }

    func testParseReportsReadsClickHouseJSON() throws {
        let json = """
        {"meta":[{"name":"time","type":"DateTime"}],
         "data":[
           {"time":"2026-07-24 21:44:00","rx_sign":"kx4az","rx_loc":"em73tr","snr":-21,
            "frequency":28126112.0,"distance":1917.0,"power":40},
           {"time":"2026-07-24 21:44:00","rx_sign":"VE6JY","rx_loc":"DO33or","snr":-8,
            "frequency":28126110.0,"distance":1560.0,"power":40}
         ],
         "rows":2}
        """
        let reports = try XCTUnwrap(WSPRNetService.parseReports(Data(json.utf8)))
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports[0].reporter, "KX4AZ") // normalized to uppercase
        XCTAssertEqual(reports[0].reporterGrid, "EM73TR")
        XCTAssertEqual(reports[0].snr, -21)
        XCTAssertEqual(reports[0].distanceKm, 1917, accuracy: 0.1)
        // ClickHouse timestamps are UTC
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: reports[0].time)
        XCTAssertEqual(components.hour, 21)
        XCTAssertEqual(components.minute, 44)
    }

    func testParseReportsRejectsGarbage() {
        XCTAssertNil(WSPRNetService.parseReports(Data("<html>rate limited</html>".utf8)))
    }

    // MARK: - Per-reporter rollup

    func testAggregateRollsUpPerReporter() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let reports = [
            BeaconReport(time: base.addingTimeInterval(240), reporter: "VE6JY", reporterGrid: "DO33",
                         snr: -8, frequencyHz: 28_126_110, distanceKm: 1560, powerDBm: 40),
            BeaconReport(time: base, reporter: "VE6JY", reporterGrid: "DO33",
                         snr: -15, frequencyHz: 28_126_110, distanceKm: 1560, powerDBm: 40),
            BeaconReport(time: base, reporter: "KX4AZ", reporterGrid: "EM73",
                         snr: -21, frequencyHz: 28_126_112, distanceKm: 1917, powerDBm: 40),
        ]
        let rollup = WSPRNetService.aggregate(reports)
        XCTAssertEqual(rollup.count, 2)
        XCTAssertEqual(rollup[0].callsign, "VE6JY") // newest activity first
        XCTAssertEqual(rollup[0].spotCount, 2)
        XCTAssertEqual(rollup[0].lastSNR, -8)  // from the newest spot
        XCTAssertEqual(rollup[0].bestSNR, -8)
        XCTAssertEqual(rollup[1].callsign, "KX4AZ")
        XCTAssertEqual(rollup[1].spotCount, 1)
    }

    // MARK: - Spot upload

    private func queryItems(_ url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
    }

    func testUploadURLCarriesTheClassicWSPRnetParameters() throws {
        let slot = Date(timeIntervalSince1970: 1_784_244_240) // 2026-07-16 23:24 UTC
        let url = try XCTUnwrap(WSPRNetService.uploadURL(
            resultText: "WSPR KX4AZ EM73 40dBm",
            snr: -19, dt: 0.4, audioFreqHz: 1512,
            slotStart: slot, dialMHz: 28.1246,
            rcall: "W0CJW", rgrid: "DM79"
        ))
        XCTAssertEqual(url.host, "wsprnet.org")
        let params = queryItems(url)
        XCTAssertEqual(params["function"], "wspr")
        XCTAssertEqual(params["rcall"], "W0CJW")
        XCTAssertEqual(params["rgrid"], "DM79")
        XCTAssertEqual(params["tcall"], "KX4AZ")
        XCTAssertEqual(params["tgrid"], "EM73")
        XCTAssertEqual(params["dbm"], "40")
        XCTAssertEqual(params["sig"], "-19")
        XCTAssertEqual(params["dt"], "0.4")
        XCTAssertEqual(params["mode"], "2")
        XCTAssertEqual(params["rqrg"], "28.124600")
        XCTAssertEqual(params["tqrg"], "28.126112") // dial + audio offset
        XCTAssertEqual(params["date"], "260716")
        XCTAssertEqual(params["time"], "2324")
        XCTAssertTrue(params["version"]?.hasPrefix("Squelch") == true)
    }

    func testUploadURLSkipsOwnBeaconAndNonWSPRRows() {
        // Our own beacon heard via RF loopback — self-spots are noise
        XCTAssertNil(WSPRNetService.uploadURL(
            resultText: "WSPR W0CJW DM79 37dBm",
            snr: -5, dt: 0, audioFreqHz: 1500,
            slotStart: Date(timeIntervalSince1970: 0), dialMHz: 28.1246,
            rcall: "W0CJW", rgrid: "DM79"
        ))
        // FT8 text must never reach the WSPR endpoint
        XCTAssertNil(WSPRNetService.uploadURL(
            resultText: "CQ K1ABC FN42",
            snr: -5, dt: 0, audioFreqHz: 1500,
            slotStart: Date(timeIntervalSince1970: 0), dialMHz: 28.074,
            rcall: "W0CJW", rgrid: "DM79"
        ))
    }
}
