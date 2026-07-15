import Foundation
import CoreLocation

/// Resolves US grid squares to state names by reverse-geocoding the grid
/// center — once per distinct 4-char grid, rate-limited, cached to disk.
/// Lookups are best-effort: callers show "USA" until a state resolves.
final class StateResolver: ObservableObject {
    /// 4-char grid → state name ("" = resolved but not a US state).
    @Published private(set) var stateByGrid: [String: String] = [:]

    private var pending: [String] = []
    private var inFlight = false
    private var sessionFailures = Set<String>()
    private let geocoder = CLGeocoder()
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RadioFun", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("grid-states.json")
        }
        load()
    }

    /// Cached state for a grid. Unknown + US station → queues a lookup and
    /// returns nil for now; the published cache updating re-renders callers.
    func state(forGrid grid: String, isUS: Bool) -> String? {
        let key = String(grid.prefix(4)).uppercased()
        guard key.count == 4 else { return nil }
        if let cached = stateByGrid[key] {
            return cached.isEmpty ? nil : cached
        }
        if isUS {
            enqueue(key)
        }
        return nil
    }

    private func enqueue(_ key: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.stateByGrid[key] == nil,
                  !self.sessionFailures.contains(key),
                  !self.pending.contains(key) else { return }
            self.pending.append(key)
            self.pump()
        }
    }

    private func pump() {
        guard !inFlight, !pending.isEmpty else { return }
        let key = pending.removeFirst()
        guard let center = Maidenhead.coordinate(forGrid: key) else {
            sessionFailures.insert(key)
            return
        }
        inFlight = true
        let location = CLLocation(latitude: center.latitude, longitude: center.longitude)
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let placemark = placemarks?.first {
                    if placemark.isoCountryCode == "US", let state = placemark.administrativeArea {
                        self.stateByGrid[key] = state
                    } else {
                        self.stateByGrid[key] = "" // resolved: not a US state
                    }
                    self.save()
                } else if error != nil {
                    // Network/rate-limit hiccup: don't poison the cache,
                    // just skip for this session
                    self.sessionFailures.insert(key)
                }
                self.inFlight = false
                // Gentle pacing — CLGeocoder dislikes rapid-fire requests
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    self.pump()
                }
            }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        stateByGrid = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(stateByGrid) else { return }
        try? data.write(to: fileURL)
    }
}

/// How to label US stations in country columns and cards.
enum USDisplay: String, CaseIterable, Identifiable {
    case country = "USA"
    case state = "State"

    var id: String { rawValue }

    static func current(_ raw: String) -> USDisplay {
        USDisplay(rawValue: raw) ?? .country
    }
}
