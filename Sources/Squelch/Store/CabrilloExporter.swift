import Foundation

/// Cabrillo 3.0 (.log) generation — the contest-submission format. The
/// exchange columns follow the common RST + grid convention (what WSJT-X
/// emits); the CONTEST/CATEGORY header lines are left for the operator to
/// fill in, since they differ per contest. Pure functions, no I/O.
enum CabrilloExporter {
    static func log(records: [QSORecord], stationCallsign: String, myGrid: String?,
                    contest: String? = nil) -> String {
        let myGrid4 = String((myGrid ?? "").prefix(4)).uppercased()
        var out = "START-OF-LOG: 3.0\n"
        out += "CALLSIGN: \(stationCallsign)\n"
        if !myGrid4.isEmpty {
            out += "GRID-LOCATOR: \(myGrid4)\n"
        }
        out += "CONTEST: \(contest ?? "")\n" // robots want the official name — check the rules
        out += "CATEGORY-OPERATOR: SINGLE-OP\n"
        out += "CATEGORY-TRANSMITTER: ONE\n"
        out += "CATEGORY-POWER: LOW\n"
        out += "OPERATORS: \(stationCallsign)\n"
        out += "CREATED-BY: Squelch\n"
        for record in records.sorted(by: { $0.start < $1.start }) {
            out += qsoLine(for: record, stationCallsign: stationCallsign, myGrid4: myGrid4)
        }
        return out + "END-OF-LOG:\n"
    }

    /// "QSO: freq mo date time mycall rst exch call rst exch" — whitespace-
    /// delimited per spec, padded into columns for readability.
    static func qsoLine(for record: QSORecord, stationCallsign: String, myGrid4: String) -> String {
        let exchRcvd = record.partnerGrid.map { String($0.prefix(4)) }
            ?? record.state
            ?? "----"
        let fields = [
            "QSO:",
            pad(freqField(record.dialFrequencyMHz), 5, right: true),
            modeCode(record.mode),
            dateFormatter.string(from: record.start),
            timeFormatter.string(from: record.start),
            pad(stationCallsign, 13),
            pad(record.reportSent.isEmpty ? "---" : record.reportSent, 3),
            pad(myGrid4.isEmpty ? "----" : myGrid4, 6),
            pad(record.partner, 13),
            pad(record.reportReceived ?? "---", 3),
            pad(exchRcvd, 6),
        ]
        var line = fields.joined(separator: " ")
        while line.hasSuffix(" ") {
            line.removeLast()
        }
        return line + "\n"
    }

    /// kHz below 50 MHz ("14074"); the band designator above ("144").
    static func freqField(_ mhz: Double) -> String {
        guard mhz > 0 else { return "0" }
        return mhz < 50 ? String(Int((mhz * 1000).rounded())) : String(Int(mhz))
    }

    /// Cabrillo two-letter mode column: CW, PH, FM, RY, DG.
    static func modeCode(_ mode: String) -> String {
        switch mode.uppercased() {
        case "CW": return "CW"
        case "SSB", "AM": return "PH"
        case "FM": return "FM"
        case "RTTY": return "RY"
        default: return "DG" // FT8, FT4, and other digital
        }
    }

    private static func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
        let fill = String(repeating: " ", count: max(0, width - s.count))
        return right ? fill + s : s + fill
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmm"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
