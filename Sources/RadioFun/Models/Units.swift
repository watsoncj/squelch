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

    static let utcDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static let localDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Date must ride the same zone as the time — a 20:00 local QSO is
    /// "tomorrow" in UTC, and mixing zones between columns misleads.
    var dateFormatter: DateFormatter {
        self == .utc ? Self.utcDateFormatter : Self.localDateFormatter
    }

    static func current(_ raw: String) -> TimeDisplay {
        TimeDisplay(rawValue: raw) ?? .utc
    }
}

/// Dial frequency for display: up to 4 decimals, trailing zeros trimmed
/// (28.074 stays "28.074", 28.1246 stays "28.1246" — never rounded to
/// 3 places).
func mhzText(_ mhz: Double) -> String {
    var s = String(format: "%.4f", mhz)
    while s.hasSuffix("0") {
        s.removeLast()
    }
    if s.hasSuffix(".") {
        s += "0"
    }
    return s
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
