import Foundation

/// One WSPRnet reception report of OUR beacon — the reverse direction of
/// everything else in the app: a station that heard us, not one we heard.
struct BeaconReport: Identifiable, Equatable {
    let time: Date
    let reporter: String
    let reporterGrid: String
    let snr: Int
    let frequencyHz: Double
    let distanceKm: Double
    let powerDBm: Int

    var id: String { "\(reporter)-\(time.timeIntervalSince1970)" }
}

/// Per-reporter rollup for the card: one row per station that heard us.
struct BeaconReporter: Identifiable, Equatable {
    let callsign: String
    let grid: String
    let lastHeard: Date
    let lastSNR: Int
    let bestSNR: Int
    let spotCount: Int
    let distanceKm: Double

    var id: String { callsign }
}

/// WSPRnet integration: uploads our received spots (opt-in) and polls for
/// reports of our own beacon while it's active (plus a grace window after,
/// since spots trickle in for a while).
///
/// Uploads go to wsprnet.org's classic per-spot endpoint (the same one
/// WSJT-X uses). Report queries go to wspr.live, the public ClickHouse
/// mirror of the WSPRnet database — keyless, JSON, and it doesn't load
/// wsprnet's aging Drupal frontend.
final class WSPRNetService: ObservableObject {
    @Published private(set) var reports: [BeaconReport] = [] // newest first
    @Published private(set) var lastFetch: Date?
    @Published private(set) var fetchError: String?
    @Published private(set) var uploadedCount = 0
    /// True while the beacon is on, and through the grace window after it
    /// stops — drives the reports card's visibility.
    @Published private(set) var reportsRelevant = false

    static let pollSeconds: TimeInterval = 240      // 2 WSPR windows
    static let graceSeconds: TimeInterval = 3600    // keep showing after beacon off
    static let queryHours = 6                       // one evening session

    private var pollTimer: Timer?
    private var beaconOn = false
    private var graceDeadline: Date?

    // MARK: - Beacon lifecycle

    func beaconStateChanged(enabled: Bool) {
        beaconOn = enabled
        if enabled {
            graceDeadline = nil
            reportsRelevant = true
            fetchNow()
            startPolling()
        } else {
            graceDeadline = Date().addingTimeInterval(Self.graceSeconds)
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
            self?.pollTick()
        }
    }

    private func pollTick() {
        if !beaconOn, let deadline = graceDeadline, Date() > deadline {
            pollTimer?.invalidate()
            pollTimer = nil
            reportsRelevant = false
            return
        }
        fetchNow()
    }

    // MARK: - Reports of our beacon (wspr.live)

    func fetchNow() {
        let call = UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? ""
        guard let url = Self.reportsQueryURL(call: call) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data, let parsed = Self.parseReports(data) {
                    if parsed != self.reports {
                        self.reports = parsed
                    }
                    self.lastFetch = Date()
                    self.fetchError = nil
                } else {
                    self.fetchError = error?.localizedDescription ?? "WSPRnet query failed"
                }
            }
        }.resume()
    }

    /// wspr.live SQL-over-HTTP. Frequency/distance cast to Float64 in the
    /// query: ClickHouse's JSON format quotes 64-bit integers as strings.
    static func reportsQueryURL(call: String, hours: Int = queryHours, limit: Int = 200) -> URL? {
        let sanitized = call.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "/" }
        guard !sanitized.isEmpty else { return nil }
        let sql = "SELECT time, rx_sign, rx_loc, snr, toFloat64(frequency) AS frequency, "
            + "toFloat64(distance) AS distance, power FROM wspr.rx "
            + "WHERE tx_sign = '\(sanitized)' AND time > subtractHours(now(), \(hours)) "
            + "ORDER BY time DESC LIMIT \(limit) FORMAT JSON"
        var components = URLComponents(string: "https://db1.wspr.live/")!
        components.queryItems = [URLQueryItem(name: "query", value: sql)]
        return components.url
    }

    private struct WSPRLiveResponse: Decodable {
        struct Row: Decodable {
            let time: String
            let rx_sign: String
            let rx_loc: String
            let snr: Int
            let frequency: Double
            let distance: Double
            let power: Int
        }
        let data: [Row]
    }

    private static let clickhouseTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func parseReports(_ data: Data) -> [BeaconReport]? {
        guard let response = try? JSONDecoder().decode(WSPRLiveResponse.self, from: data) else { return nil }
        return response.data.compactMap { row in
            guard let time = clickhouseTime.date(from: row.time) else { return nil }
            return BeaconReport(
                time: time,
                reporter: row.rx_sign.uppercased(),
                reporterGrid: row.rx_loc.uppercased(),
                snr: row.snr,
                frequencyHz: row.frequency,
                distanceKm: row.distance,
                powerDBm: row.power
            )
        }
    }

    /// One row per reporter, newest activity first.
    static func aggregate(_ reports: [BeaconReport]) -> [BeaconReporter] {
        var byCall: [String: [BeaconReport]] = [:]
        for report in reports {
            byCall[report.reporter, default: []].append(report)
        }
        return byCall.map { call, spots in
            let newest = spots.max { $0.time < $1.time }!
            return BeaconReporter(
                callsign: call,
                grid: newest.reporterGrid,
                lastHeard: newest.time,
                lastSNR: newest.snr,
                bestSNR: spots.map(\.snr).max() ?? newest.snr,
                spotCount: spots.count,
                distanceKm: spots.map(\.distanceKm).max() ?? newest.distanceKm
            )
        }
        .sorted { $0.lastHeard > $1.lastHeard }
    }

    // MARK: - Spot uploads (wsprnet.org)

    /// Upload every WSPR decode from a slot. Reporter identity comes from
    /// Settings; spots of our own beacon (monitor loopback) are skipped.
    func uploadSpots(results: [FT8Result], slotStart: Date, dialMHz: Double) {
        let defaults = UserDefaults.standard
        let rcall = (defaults.string(forKey: SettingsKeys.myCallsign) ?? "").uppercased()
        let rgrid = String((defaults.string(forKey: SettingsKeys.myGrid) ?? "").prefix(6)).uppercased()
        guard !rcall.isEmpty, Maidenhead.isValidGrid(rgrid) else { return }
        for result in results {
            guard let url = Self.uploadURL(
                resultText: result.text,
                snr: result.snr,
                dt: result.timeOffset,
                audioFreqHz: Double(result.freqHz),
                slotStart: slotStart,
                dialMHz: dialMHz,
                rcall: rcall,
                rgrid: rgrid
            ) else { continue }
            URLSession.shared.dataTask(with: url) { [weak self] _, response, _ in
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
                DispatchQueue.main.async { self?.uploadedCount += 1 }
            }.resume()
        }
    }

    private static let spotDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMdd"
        return formatter
    }()

    private static let spotTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HHmm"
        return formatter
    }()

    /// The classic wsprnet.org per-spot GET (WSJT-X's format). Input is the
    /// decoder's feed text ("WSPR CALL GRID 37dBm") plus the slot metadata.
    /// Returns nil for non-WSPR rows and for spots of our own callsign.
    static func uploadURL(
        resultText: String,
        snr: Float,
        dt: Float,
        audioFreqHz: Double,
        slotStart: Date,
        dialMHz: Double,
        rcall: String,
        rgrid: String
    ) -> URL? {
        let tokens = resultText.uppercased().split(separator: " ").map(String.init)
        guard tokens.count >= 4, tokens[0] == "WSPR" else { return nil }
        let tcall = tokens[1]
        let tgrid = tokens[2]
        guard let dbm = Int(tokens[3].replacingOccurrences(of: "DBM", with: "")) else { return nil }
        guard tcall != rcall.uppercased() else { return nil } // own beacon loopback

        let version = "Squelch " + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev")
        var components = URLComponents(string: "https://wsprnet.org/post")!
        components.queryItems = [
            URLQueryItem(name: "function", value: "wspr"),
            URLQueryItem(name: "rcall", value: rcall),
            URLQueryItem(name: "rgrid", value: rgrid),
            URLQueryItem(name: "rqrg", value: String(format: "%.6f", dialMHz)),
            URLQueryItem(name: "date", value: spotDate.string(from: slotStart)),
            URLQueryItem(name: "time", value: spotTime.string(from: slotStart)),
            URLQueryItem(name: "sig", value: String(format: "%.0f", snr)),
            URLQueryItem(name: "dt", value: String(format: "%.1f", dt)),
            URLQueryItem(name: "drift", value: "0"),
            URLQueryItem(name: "tqrg", value: String(format: "%.6f", dialMHz + audioFreqHz / 1_000_000)),
            URLQueryItem(name: "tcall", value: tcall),
            URLQueryItem(name: "tgrid", value: tgrid),
            URLQueryItem(name: "dbm", value: String(dbm)),
            URLQueryItem(name: "version", value: version),
            URLQueryItem(name: "mode", value: "2"),
        ]
        return components.url
    }
}
