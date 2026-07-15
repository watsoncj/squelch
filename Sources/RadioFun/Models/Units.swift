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
