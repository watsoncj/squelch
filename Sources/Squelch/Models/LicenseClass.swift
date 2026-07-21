import Foundation

/// US amateur license classes and where each may transmit data modes.
/// Drives the hard TX lock and the frequency menu's transmit/receive-only
/// split. Advanced-class holders: pick General (data privileges match).
/// "None" is for unlicensed listeners (SWL): everything works except TX.
enum LicenseClass: String, CaseIterable, Identifiable {
    case unlicensed = "None (receive only)"
    case technician = "Technician"
    case general = "General"
    case extra = "Amateur Extra"

    var id: String { rawValue }

    /// MHz segments where this class may transmit data (FT8/FT4/WSPR).
    /// HF ranges are the CW/RTTY/data segments from FCC Part 97.301;
    /// VHF/UHF all-mode allocations are common to every class.
    var dataSegmentsMHz: [ClosedRange<Double>] {
        let vhfUp: [ClosedRange<Double>] = [
            50.0...54.0,      // 6 m
            144.0...148.0,    // 2 m
            222.0...225.0,    // 1.25 m
            420.0...450.0,    // 70 cm
        ]
        switch self {
        case .unlicensed:
            return []
        case .technician:
            return [28.000...28.300] + vhfUp
        case .general:
            return [
                1.800...2.000,    // 160 m
                3.525...3.600,    // 80 m
                7.025...7.125,    // 40 m
                10.100...10.150,  // 30 m
                14.025...14.150,  // 20 m
                18.068...18.110,  // 17 m
                21.025...21.200,  // 15 m
                24.890...24.930,  // 12 m
                28.000...28.300,  // 10 m
            ] + vhfUp
        case .extra:
            return [
                1.800...2.000,
                3.500...3.600,
                7.000...7.125,
                10.100...10.150,
                14.000...14.150,
                18.068...18.110,
                21.000...21.200,
                24.890...24.930,
                28.000...28.300,
            ] + vhfUp
        }
    }

    func canTransmitData(mhz: Double) -> Bool {
        dataSegmentsMHz.contains { $0.contains(mhz) }
    }

    /// The class saved in Settings. Defaults to Technician — the most
    /// restrictive — so the TX lock stays safe if never configured.
    static var current: LicenseClass {
        LicenseClass(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.licenseClass) ?? "")
            ?? .technician
    }
}
