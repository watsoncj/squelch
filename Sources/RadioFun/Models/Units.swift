import Foundation

enum TimeDisplay: String, CaseIterable, Identifiable {
    case utc = "UTC"
    case local = "Local"

    var id: String { rawValue }

    static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var formatter: DateFormatter {
        self == .utc ? Self.utcFormatter : Self.localFormatter
    }

    static func current(_ raw: String) -> TimeDisplay {
        TimeDisplay(rawValue: raw) ?? .utc
    }
}

/// Ham band name for a dial frequency.
func bandName(forMHz mhz: Double) -> String {
    switch mhz {
    case 1.8..<2.1: return "160m"
    case 3.5..<4.0: return "80m"
    case 5.0..<5.5: return "60m"
    case 7.0..<7.3: return "40m"
    case 10.1..<10.15: return "30m"
    case 14.0..<14.35: return "20m"
    case 18.0..<18.2: return "17m"
    case 21.0..<21.45: return "15m"
    case 24.8..<25.0: return "12m"
    case 28.0..<29.7: return "10m"
    case 50.0..<54.0: return "6m"
    case 144.0..<148.0: return "2m"
    case 222.0..<225.0: return "1.25m"
    case 420.0..<450.0: return "70cm"
    default: return "?"
    }
}

enum DistanceUnit: String, CaseIterable, Identifiable {
    case miles = "Miles"
    case kilometers = "Kilometers"

    var id: String { rawValue }

    func text(fromKm km: Double) -> String {
        switch self {
        case .miles: return String(format: "%.0f mi", km * 0.621371)
        case .kilometers: return String(format: "%.0f km", km)
        }
    }

    static func current(_ raw: String) -> DistanceUnit {
        DistanceUnit(rawValue: raw) ?? .miles
    }
}
