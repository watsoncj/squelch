import Foundation
import CoreLocation

/// My station's position IS the grid square in Settings. Location Services
/// is only touched when the user clicks the Settings button that fills the
/// grid from a one-shot fix — never automatically at launch.
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var isQuerying = false
    @Published var queryError: String?

    private let manager = CLLocationManager()
    private var queryRequested = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// One-shot: authorize if needed, take a fix, write the grid square to
    /// Settings. Overwrites the stored grid — that's what the button is for.
    func queryGridFromLocation() {
        queryRequested = true
        isQuerying = true
        queryError = nil
        manager.requestWhenInUseAuthorization()
        if isAuthorized(manager.authorizationStatus) {
            manager.startUpdatingLocation()
        }
    }

    func effectiveCoordinate() -> CLLocationCoordinate2D? {
        let grid = UserDefaults.standard.string(forKey: SettingsKeys.myGrid) ?? ""
        return Maidenhead.coordinate(forGrid: grid)
    }

    var effectiveGrid: String? {
        let grid = UserDefaults.standard.string(forKey: SettingsKeys.myGrid) ?? ""
        return Maidenhead.isValidGrid(grid) ? grid.uppercased() : nil
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard queryRequested else { return } // no auto-start at launch
        if isAuthorized(manager.authorizationStatus) {
            manager.startUpdatingLocation()
        } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            isQuerying = false
            queryRequested = false
            queryError = "Location access denied — enable it in System Settings › Privacy, or type the grid manually"
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        manager.stopUpdatingLocation() // one fix is plenty for a fixed station
        guard queryRequested else { return }
        queryRequested = false
        isQuerying = false
        UserDefaults.standard.set(Maidenhead.grid(for: latest.coordinate), forKey: SettingsKeys.myGrid)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard queryRequested else { return }
        queryRequested = false
        isQuerying = false
        queryError = "Location fix failed: \(error.localizedDescription)"
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
    static let sidebarWidth = "sidebarWidth"
    static let showSidebar = "showSidebar"
    static let autoAnswer = "autoAnswer"
    static let showWaterfall = "showWaterfall"
    static let timeDisplay = "timeDisplay"
    static let distanceUnit = "distanceUnit"
    static let lastCQParity = "lastCQParity"
    static let wsprPowerDBm = "wsprPowerDBm"
    static let wsprDutyPct = "wsprDutyPct"
}
