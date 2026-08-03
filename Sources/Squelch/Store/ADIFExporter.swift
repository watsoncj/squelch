import Foundation

/// ADIF 3.1 (.adi) generation — the interchange format every logger and
/// award program (LoTW, QRZ Logbook, eQSL, POTA) imports. Pure functions,
/// no I/O; the view layer handles the actual file save.
enum ADIFExporter {
    /// Full .adi file: header, then one record per line (oldest first).
    static func adi(records: [QSORecord], stationCallsign: String, myGrid: String?,
                    now: Date = Date()) -> String {
        var out = "Squelch ADIF export\n"
        out += field("ADIF_VER", "3.1.4")
        out += field("PROGRAMID", "Squelch")
        out += field("CREATED_TIMESTAMP", timestampFormatter.string(from: now))
        out += "<EOH>\n"
        for record in records.sorted(by: { $0.start < $1.start }) {
            out += line(for: record, stationCallsign: stationCallsign, myGrid: myGrid)
        }
        return out
    }

    static func line(for record: QSORecord, stationCallsign: String, myGrid: String?) -> String {
        let (mode, submode) = modeFields(record.mode)
        let band = bandName(forMHz: record.dialFrequencyMHz)
        var s = field("CALL", record.partner)
        s += field("GRIDSQUARE", record.partnerGrid)
        s += field("MODE", mode)
        s += field("SUBMODE", submode)
        s += field("QSO_DATE", dateFormatter.string(from: record.start))
        s += field("TIME_ON", timeFormatter.string(from: record.start))
        s += field("QSO_DATE_OFF", dateFormatter.string(from: record.end))
        s += field("TIME_OFF", timeFormatter.string(from: record.end))
        s += field("BAND", band == "?" ? nil : band)
        s += field("FREQ", record.dialFrequencyMHz > 0 ? mhzText(record.dialFrequencyMHz) : nil)
        s += field("RST_SENT", record.reportSent)
        s += field("RST_RCVD", record.reportReceived)
        s += field("NAME", record.name)
        s += field("COMMENT", record.notes.map {
            $0.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "; ")
        })
        s += field("STATE", record.state)
        s += field("COUNTRY", record.country)
        s += field("CONTEST_ID", record.contest)
        s += field("MY_GRIDSQUARE", myGrid)
        s += field("STATION_CALLSIGN", stationCallsign)
        s += field("OPERATOR", stationCallsign)
        return s + "<EOR>\n"
    }

    /// "<TAG:n>value " with n the UTF-8 byte count (ADIF has no escaping —
    /// the length prefix is what makes "<" legal inside values).
    static func field(_ tag: String, _ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return "<\(tag):\(value.utf8.count)>\(value) "
    }

    /// FT8 is a top-level ADIF mode; FT4 rides as a submode of MFSK.
    static func modeFields(_ mode: String) -> (mode: String, submode: String?) {
        mode == "FT4" ? ("MFSK", "FT4") : (mode, nil)
    }

    private static let dateFormatter = utcFormatter("yyyyMMdd")
    private static let timeFormatter = utcFormatter("HHmmss")
    private static let timestampFormatter = utcFormatter("yyyyMMdd HHmmss")

    private static func utcFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }
}
