import Foundation
import CoreLocation

/// Holds the decode log and the per-callsign station list, and persists
/// decodes to a JSONL file in Application Support.
final class DecodeStore: ObservableObject {
    @Published private(set) var messages: [DecodedMessage] = [] // newest first
    @Published private(set) var stations: [String: Station] = [:]
    @Published private(set) var totalDecodes = 0

    /// Off in --demo mode so fake decodes never reach the real log file.
    var persistToDisk = true

    private static let maxMessagesInMemory = 5000
    private let fileURL: URL
    private var fileHandle: FileHandle?
    private let encoder = JSONEncoder()

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = squelchSupportDirectory()
            self.fileURL = dir.appendingPathComponent("decodes.jsonl")
        }
        encoder.dateEncodingStrategy = .iso8601
        loadFromDisk()
    }

    var logFileURL: URL { fileURL }

    func ingest(results: [FT8Result], slotStart: Date, myCoordinate: CLLocationCoordinate2D?, dialFrequencyMHz: Double) {
        var newMessages: [DecodedMessage] = []
        for r in results {
            let parsed = FT8MessageParser.parse(r.text)

            // Prefer a grid in this message; otherwise reuse the last grid we
            // heard from this station so reports/73s still land on the map.
            var grid = parsed.grid
            if grid == nil, let call = parsed.sender {
                grid = stations[call]?.grid
            }

            var latitude: Double?
            var longitude: Double?
            var distanceKm: Double?
            if let grid, let coord = Maidenhead.coordinate(forGrid: grid) {
                latitude = coord.latitude
                longitude = coord.longitude
                if let myCoordinate {
                    let a = CLLocation(latitude: myCoordinate.latitude, longitude: myCoordinate.longitude)
                    let b = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    distanceKm = a.distance(from: b) / 1000.0
                }
            }

            let message = DecodedMessage(
                id: UUID(),
                slotStart: slotStart,
                snr: r.snr,
                timeOffset: r.timeOffset,
                audioFrequency: r.freqHz,
                dialFrequencyMHz: dialFrequencyMHz,
                text: r.text,
                callsign: parsed.sender,
                grid: grid,
                latitude: latitude,
                longitude: longitude,
                distanceKm: distanceKm
            )

            newMessages.append(message)
            totalDecodes += 1
            updateStation(from: message)
            appendToDisk(message)
        }
        // One array mutation (and one @Published emission) per slot
        messages.insert(contentsOf: newMessages.reversed(), at: 0)
        if messages.count > Self.maxMessagesInMemory {
            messages.removeLast(messages.count - Self.maxMessagesInMemory)
        }
    }

    func clearLog() {
        messages.removeAll()
        stations.removeAll()
        totalDecodes = 0
        try? fileHandle?.close()
        fileHandle = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func updateStation(from message: DecodedMessage) {
        guard let call = message.callsign, let coord = message.coordinate, let grid = message.grid else { return }
        // Our own loopback decodes stay in the log (TX confirmation) but
        // must not appear as a heard station — every CQ would update the
        // map and trigger a polygon rebuild + camera refit
        let myCall = (UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? "").uppercased()
        guard call.uppercased() != myCall else { return }
        if var station = stations[call] {
            station.grid = grid
            station.coordinate = coord
            station.lastHeard = message.slotStart
            station.lastSNR = message.snr
            station.heardCount += 1
            if message.distanceKm != nil { station.distanceKm = message.distanceKm }
            stations[call] = station
        } else {
            stations[call] = Station(
                callsign: call,
                grid: grid,
                coordinate: coord,
                firstHeard: message.slotStart,
                lastHeard: message.slotStart,
                lastSNR: message.snr,
                heardCount: 1,
                distanceKm: message.distanceKm
            )
        }
    }

    private func appendToDisk(_ message: DecodedMessage) {
        guard persistToDisk else { return }
        guard var data = try? encoder.encode(message) else { return }
        data.append(0x0A)
        if fileHandle == nil {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            fileHandle = try? FileHandle(forWritingTo: fileURL)
            _ = try? fileHandle?.seekToEnd()
        }
        try? fileHandle?.write(contentsOf: data)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [DecodedMessage] = []
        for line in content.split(separator: "\n").suffix(Self.maxMessagesInMemory) {
            if let msg = try? decoder.decode(DecodedMessage.self, from: Data(line.utf8)) {
                loaded.append(msg)
            }
        }
        messages = loaded.reversed()
        totalDecodes = loaded.count
        // Rebuild stations oldest → newest so the latest grid wins
        for msg in loaded {
            updateStation(from: msg)
        }
    }
}
