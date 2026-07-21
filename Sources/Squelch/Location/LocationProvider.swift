import Foundation
import CoreLocation

/// My station's location: CoreLocation when authorized, otherwise the grid
/// square entered in Settings.
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var systemCoordinate: CLLocationCoordinate2D?
    @Published var authorizationDenied = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestLocation() {
        manager.requestWhenInUseAuthorization()
        if isAuthorized(manager.authorizationStatus) {
            manager.startUpdatingLocation()
        }
    }

    /// System location if we have it, else the manual grid from Settings.
    func effectiveCoordinate() -> CLLocationCoordinate2D? {
        if let systemCoordinate { return systemCoordinate }
        let grid = UserDefaults.standard.string(forKey: SettingsKeys.myGrid) ?? ""
        return Maidenhead.coordinate(forGrid: grid)
    }

    var effectiveGrid: String? {
        if let systemCoordinate { return Maidenhead.grid(for: systemCoordinate) }
        let grid = UserDefaults.standard.string(forKey: SettingsKeys.myGrid) ?? ""
        return Maidenhead.isValidGrid(grid) ? grid.uppercased() : nil
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if isAuthorized(manager.authorizationStatus) {
            authorizationDenied = false
            manager.startUpdatingLocation()
        } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            authorizationDenied = true
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        systemCoordinate = latest.coordinate
        manager.stopUpdatingLocation() // one fix is plenty for a fixed station

        // Initialize the manual grid setting from the fix so the station
        // still has a position when Location Services is unavailable later.
        // Never overwrites a grid the user typed themselves.
        let stored = UserDefaults.standard.string(forKey: SettingsKeys.myGrid) ?? ""
        if stored.isEmpty {
            UserDefaults.standard.set(Maidenhead.grid(for: latest.coordinate), forKey: SettingsKeys.myGrid)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Fall back to the manual grid; nothing to do.
    }

    private func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways || status == .authorized
    }
}

enum SettingsKeys {
    static let myCallsign = "myCallsign"
    static let licenseClass = "licenseClass"
    static let myGrid = "myGrid"
    static let dialFrequencyMHz = "dialFrequencyMHz"
    static let audioDeviceUID = "audioDeviceUID"
    static let audioOutputUID = "audioOutputUID"
    static let pttPortPath = "pttPortPath"
    static let txOffsetHz = "txOffsetHz"
    static let digiMode = "digiMode"
    static let catPortPath = "catPortPath"
    static let catBaud = "catBaud"
    static let mapStyle = "mapStyle"
    static let showGridCells = "showGridCells"
    static let autoAnswer = "autoAnswer"
    static let showWaterfall = "showWaterfall"
    static let timeDisplay = "timeDisplay"
    static let distanceUnit = "distanceUnit"
    static let lastCQParity = "lastCQParity"
    static let wsprPowerDBm = "wsprPowerDBm"
    static let wsprDutyPct = "wsprDutyPct"
}
