import Foundation

/// Cabrillo 3.0 (.log) generation — the contest-submission format. Pure
/// functions, no I/O.
///
/// The exchange columns follow the contest: grid-only contests (WW Digi,
/// the ARRL VHF series) get `mycall grid theircall grid txid`, everything
/// else the common RST + grid layout WSJT-X emits. Category headers are
/// derived from the log where they can be (band, mode, power) and fixed
/// to the single-op defaults otherwise — the operator edits the header
/// if they entered differently.
enum CabrilloExporter {
    /// Layout of the QSO line's exchange columns.
    enum ExchangeStyle: Equatable {
        case reportAndGrid // "mycall rst grid theircall rst grid"
        case gridOnly      // "mycall grid theircall grid txid"
    }

    static func log(records: [QSORecord], stationCallsign: String, myGrid: String?,
                    contest: String? = nil, location: String? = nil) -> String {
        let myGrid4 = String((myGrid ?? "").prefix(4)).uppercased()
        let contestName = canonicalContest(contest) ?? ""
        let style = exchangeStyle(for: contest)
        let sorted = records.sorted(by: { $0.start < $1.start })
        var out = "START-OF-LOG: 3.0\n"
        out += "CONTEST: \(contestName)\n" // robots want the official name — check the rules
        out += "CALLSIGN: \(stationCallsign)\n"
        out += "CATEGORY-OPERATOR: SINGLE-OP\n"
        out += "CATEGORY-BAND: \(categoryBand(records))\n"
        out += "CATEGORY-MODE: \(categoryMode(records))\n"
        out += "CATEGORY-POWER: \(categoryPower(records))\n"
        out += "CATEGORY-TRANSMITTER: ONE\n"
        out += "CATEGORY-STATION: FIXED\n"
        out += "LOCATION: \(locationField(location, stationCallsign: stationCallsign))\n"
        if !myGrid4.isEmpty {
            out += "GRID-LOCATOR: \(myGrid4)\n"
        }
        out += "OPERATORS: \(stationCallsign)\n"
        out += "CREATED-BY: Squelch\n"
        for record in sorted {
            out += qsoLine(for: record, stationCallsign: stationCallsign, myGrid4: myGrid4, style: style)
        }
        return out + "END-OF-LOG:\n"
    }

    /// "QSO: freq mo date time mycall [rst] exch call [rst] exch [txid]" —
    /// whitespace-delimited per spec, padded into columns for readability.
    static func qsoLine(for record: QSORecord, stationCallsign: String, myGrid4: String,
                        style: ExchangeStyle = .reportAndGrid) -> String {
        let theirGrid = record.partnerGrid.map { String($0.prefix(4)).uppercased() }
        var fields = [
            "QSO:",
            pad(freqField(record.dialFrequencyMHz), 5, right: true),
            modeCode(record.mode),
            dateFormatter.string(from: record.start),
            timeFormatter.string(from: record.start),
            pad(stationCallsign, 13),
        ]
        switch style {
        case .reportAndGrid:
            fields += [
                pad(record.reportSent.isEmpty ? "---" : record.reportSent, 3),
                pad(myGrid4.isEmpty ? "----" : myGrid4, 6),
                pad(record.partner, 13),
                pad(record.reportReceived ?? "---", 3),
                pad(theirGrid ?? record.state ?? "----", 6),
            ]
        case .gridOnly:
            fields += [
                pad(myGrid4.isEmpty ? "----" : myGrid4, 6),
                pad(record.partner, 13),
                pad(theirGrid ?? "----", 6),
                "0", // transmitter id — single transmitter
            ]
        }
        var line = fields.joined(separator: " ")
        while line.hasSuffix(" ") {
            line.removeLast()
        }
        return line + "\n"
    }

    /// QSOs whose received exchange is missing — in a grid-only contest,
    /// no grid was copied from the partner. They export as "----" and the
    /// robot will throw them out; better to know before uploading.
    static func missingExchange(records: [QSORecord], contest: String?) -> [QSORecord] {
        guard exchangeStyle(for: contest) == .gridOnly else { return [] }
        return records.filter { $0.partnerGrid == nil }
    }

    // MARK: - Contest identity

    /// The lookup key for a user-typed contest name: "WW Digi", "ww-digi"
    /// and "WWDIGI" all mean the same entry.
    private static func contestKey(_ name: String?) -> String {
        (name ?? "").uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The official Cabrillo CONTEST: name where a common spelling is
    /// recognized; otherwise the name as typed (trimmed).
    static func canonicalContest(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        switch contestKey(trimmed) {
        case "WWDIGI", "WWDIGIDX", "WWDIGIDXCONTEST": return "WW-DIGI"
        default: return trimmed
        }
    }

    /// Grid-only exchange for WW Digi and the ARRL VHF-and-up contests
    /// (their Cabrillo lines carry grids alone); RST + grid otherwise.
    static func exchangeStyle(for contest: String?) -> ExchangeStyle {
        let key = contestKey(contest)
        guard !key.isEmpty else { return .reportAndGrid }
        if key.hasPrefix("WWDIGI") || key.contains("VHF") || key == "ARRL222" || key == "ARRL10GHZ" {
            return .gridOnly
        }
        return .reportAndGrid
    }

    // MARK: - Category headers

    /// Single band when every QSO sits on one, else ALL.
    static func categoryBand(_ records: [QSORecord]) -> String {
        let bands = Set(records.map { cabrilloBand(mhz: $0.dialFrequencyMHz) })
        guard bands.count == 1, let band = bands.first, band != "ALL" else { return "ALL" }
        return band
    }

    /// Cabrillo CATEGORY-BAND token for a dial frequency ("20M", "2M",
    /// "222", "432"); ALL when the band isn't recognized.
    static func cabrilloBand(mhz: Double) -> String {
        switch bandName(forMHz: mhz) {
        case "?": return "ALL"
        case "1.25m": return "222"
        case "70cm": return "432"
        case let name: return name.uppercased()
        }
    }

    /// DIGI / CW / SSB / RTTY / FM when the log is all one mode, MIXED
    /// otherwise; an empty log defaults to DIGI (this is a digital-mode app).
    static func categoryMode(_ records: [QSORecord]) -> String {
        let codes = Set(records.map { modeCode($0.mode) })
        guard codes.count <= 1 else { return "MIXED" }
        switch codes.first ?? "DG" {
        case "CW": return "CW"
        case "PH": return "SSB"
        case "RY": return "RTTY"
        case "FM": return "FM"
        default: return "DIGI"
        }
    }

    /// From the highest radio power setting recorded on the QSOs: QRP up
    /// to 5 W, LOW to 100 W, HIGH above. No power data → LOW.
    static func categoryPower(_ records: [QSORecord]) -> String {
        guard let watts = records.compactMap(\.txPowerWatts).max() else { return "LOW" }
        if watts <= 5 { return "QRP" }
        return watts <= 100 ? "LOW" : "HIGH"
    }

    /// ARRL/RAC section as given; DX for a station outside the US and
    /// Canada when none is set. A US/VE station with no section gets a
    /// blank the operator must fill — guessing one would be wrong more
    /// often than not.
    static func locationField(_ section: String?, stationCallsign: String) -> String {
        let given = (section ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        if !given.isEmpty { return given }
        let call = stationCallsign.uppercased()
        let canadian = call.count >= 2 && call.hasPrefix("V") && "AEOY".contains(call[call.index(after: call.startIndex)])
        return FT8MessageParser.isUSCallsign(call) || canadian ? "" : "DX"
    }

    // MARK: - Fields

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
