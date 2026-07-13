import Foundation

/// Maps callsign prefixes to countries (a practical subset of the ITU/DXCC
/// allocations — the entities commonly heard on HF digital modes).
/// Compound calls use the leading segment as the location prefix, matching
/// FT8MessageParser.isUSCallsign.
enum CallsignCountry {
    struct Info: Equatable {
        let name: String
        let flag: String
    }

    static func lookup(_ callsign: String) -> Info? {
        let location = callsign.split(separator: "/").first.map(String.init) ?? callsign
        guard !location.isEmpty else { return nil }
        // Longest prefix wins: "DU" (Philippines) before "D" (Germany)
        for length in stride(from: min(3, location.count), through: 1, by: -1) {
            if let info = table[String(location.prefix(length)).uppercased()] {
                return info
            }
        }
        return nil
    }

    private static let table: [String: Info] = {
        var t: [String: Info] = [:]

        func add(_ prefixes: [String], _ name: String, _ flag: String) {
            let info = Info(name: name, flag: flag)
            for p in prefixes { t[p] = info }
        }
        // Every two-letter prefix from e.g. "JA" through "JS"
        func addRange(_ start: String, _ end: String, _ name: String, _ flag: String) {
            let first = start.first!
            guard let s = start.last?.asciiValue, let e = end.last?.asciiValue else { return }
            add((s...e).map { "\(first)\(Character(UnicodeScalar($0)))" }, name, flag)
        }

        // North America
        add(["K", "N", "W"], "USA", "🇺🇸")
        addRange("AA", "AL", "USA", "🇺🇸")
        add(["KL"], "Alaska", "🇺🇸")
        add(["KH"], "Hawaii/US Pacific", "🇺🇸")
        add(["KP", "NP", "WP"], "Puerto Rico/USVI", "🇵🇷")
        addRange("VA", "VG", "Canada", "🇨🇦")
        add(["VO", "VX", "VY", "CY"], "Canada", "🇨🇦")
        addRange("XA", "XI", "Mexico", "🇲🇽")
        addRange("4A", "4C", "Mexico", "🇲🇽")

        // Central America & Caribbean
        add(["TG"], "Guatemala", "🇬🇹")
        add(["TI"], "Costa Rica", "🇨🇷")
        add(["YS"], "El Salvador", "🇸🇻")
        add(["HR"], "Honduras", "🇭🇳")
        add(["YN"], "Nicaragua", "🇳🇮")
        add(["HP"], "Panama", "🇵🇦")
        add(["V3"], "Belize", "🇧🇿")
        add(["CM", "CO"], "Cuba", "🇨🇺")
        add(["HH"], "Haiti", "🇭🇹")
        add(["HI"], "Dominican Rep.", "🇩🇴")
        add(["6Y"], "Jamaica", "🇯🇲")
        add(["ZF"], "Cayman Is.", "🇰🇾")
        add(["C6"], "Bahamas", "🇧🇸")
        add(["8P"], "Barbados", "🇧🇧")
        add(["9Y", "9Z"], "Trinidad", "🇹🇹")
        add(["PJ"], "Curaçao/Bonaire", "🇧🇶")
        add(["P4"], "Aruba", "🇦🇼")
        add(["VP5"], "Turks & Caicos", "🇹🇨")
        add(["VP9"], "Bermuda", "🇧🇲")
        add(["FM"], "Martinique", "🇲🇶")
        add(["FG"], "Guadeloupe", "🇬🇵")

        // South America
        addRange("PP", "PY", "Brazil", "🇧🇷")
        addRange("ZV", "ZZ", "Brazil", "🇧🇷")
        add(["LU"], "Argentina", "🇦🇷")
        addRange("LO", "LW", "Argentina", "🇦🇷")
        addRange("CA", "CE", "Chile", "🇨🇱")
        add(["XQ", "XR", "3G"], "Chile", "🇨🇱")
        add(["HJ", "HK"], "Colombia", "🇨🇴")
        add(["HC", "HD"], "Ecuador", "🇪🇨")
        add(["OA", "OB", "OC"], "Peru", "🇵🇪")
        add(["CX"], "Uruguay", "🇺🇾")
        add(["ZP"], "Paraguay", "🇵🇾")
        add(["CP"], "Bolivia", "🇧🇴")
        addRange("YV", "YY", "Venezuela", "🇻🇪")
        add(["PZ"], "Suriname", "🇸🇷")
        add(["8R"], "Guyana", "🇬🇾")

        // Western Europe
        add(["G", "M"], "England", "🇬🇧")
        add(["GW", "MW"], "Wales", "🏴󠁧󠁢󠁷󠁬󠁳󠁿")
        add(["GM", "MM"], "Scotland", "🏴󠁧󠁢󠁳󠁣󠁴󠁿")
        add(["GI", "MI"], "N. Ireland", "🇬🇧")
        add(["EI", "EJ"], "Ireland", "🇮🇪")
        add(["F"], "France", "🇫🇷")
        add(["TK", "TM"], "France", "🇫🇷")
        addRange("DA", "DR", "Germany", "🇩🇪")
        addRange("EA", "EH", "Spain", "🇪🇸")
        add(["AM", "AN", "AO"], "Spain", "🇪🇸")
        add(["CT", "CU"], "Portugal", "🇵🇹")
        add(["I"], "Italy", "🇮🇹")
        addRange("PA", "PI", "Netherlands", "🇳🇱")
        addRange("ON", "OT", "Belgium", "🇧🇪")
        add(["LX"], "Luxembourg", "🇱🇺")
        add(["HB"], "Switzerland", "🇨🇭")
        add(["OE"], "Austria", "🇦🇹")
        add(["ZB"], "Gibraltar", "🇬🇮")
        add(["9H"], "Malta", "🇲🇹")

        // Nordics
        addRange("LA", "LN", "Norway", "🇳🇴")
        addRange("SA", "SM", "Sweden", "🇸🇪")
        add(["OZ", "OU", "OV", "OW", "5P", "5Q"], "Denmark", "🇩🇰")
        addRange("OF", "OJ", "Finland", "🇫🇮")
        add(["TF"], "Iceland", "🇮🇸")
        add(["OX"], "Greenland", "🇬🇱")
        add(["OY"], "Faroe Is.", "🇫🇴")

        // Central/Eastern Europe
        addRange("SN", "SR", "Poland", "🇵🇱")
        add(["SP", "HF", "3Z"], "Poland", "🇵🇱")
        add(["OK", "OL"], "Czechia", "🇨🇿")
        add(["OM"], "Slovakia", "🇸🇰")
        add(["HA", "HG"], "Hungary", "🇭🇺")
        addRange("YO", "YR", "Romania", "🇷🇴")
        add(["LZ"], "Bulgaria", "🇧🇬")
        add(["YT", "YU"], "Serbia", "🇷🇸")
        add(["9A"], "Croatia", "🇭🇷")
        add(["S5"], "Slovenia", "🇸🇮")
        add(["E7"], "Bosnia", "🇧🇦")
        add(["Z3"], "N. Macedonia", "🇲🇰")
        add(["ZA"], "Albania", "🇦🇱")
        add(["SV"], "Greece", "🇬🇷")
        add(["5B"], "Cyprus", "🇨🇾")
        add(["YL"], "Latvia", "🇱🇻")
        add(["LY"], "Lithuania", "🇱🇹")
        add(["ES"], "Estonia", "🇪🇪")

        // Russia & former USSR
        add(["R", "U"], "Russia", "🇷🇺")
        addRange("UR", "UZ", "Ukraine", "🇺🇦")
        add(["EM", "EN", "EO"], "Ukraine", "🇺🇦")
        add(["EU", "EV", "EW"], "Belarus", "🇧🇾")
        add(["UN", "UP", "UQ"], "Kazakhstan", "🇰🇿")
        add(["ER"], "Moldova", "🇲🇩")
        add(["4L"], "Georgia", "🇬🇪")
        add(["EK"], "Armenia", "🇦🇲")
        add(["4J", "4K"], "Azerbaijan", "🇦🇿")

        // Middle East & Africa
        add(["TA", "TB", "TC"], "Türkiye", "🇹🇷")
        add(["4X", "4Z"], "Israel", "🇮🇱")
        add(["JY"], "Jordan", "🇯🇴")
        add(["OD"], "Lebanon", "🇱🇧")
        add(["HZ", "7Z", "8Z"], "Saudi Arabia", "🇸🇦")
        add(["A4"], "Oman", "🇴🇲")
        add(["A6"], "UAE", "🇦🇪")
        add(["A7"], "Qatar", "🇶🇦")
        add(["A9"], "Bahrain", "🇧🇭")
        add(["9K"], "Kuwait", "🇰🇼")
        add(["SU"], "Egypt", "🇪🇬")
        add(["CN"], "Morocco", "🇲🇦")
        add(["7X"], "Algeria", "🇩🇿")
        add(["3V"], "Tunisia", "🇹🇳")
        addRange("ZR", "ZU", "South Africa", "🇿🇦")
        add(["5Z"], "Kenya", "🇰🇪")
        add(["9J"], "Zambia", "🇿🇲")
        add(["C9"], "Mozambique", "🇲🇿")
        add(["3B"], "Mauritius", "🇲🇺")
        add(["EA8"], "Canary Is.", "🇮🇨")

        // Asia
        addRange("JA", "JS", "Japan", "🇯🇵")
        addRange("7J", "7N", "Japan", "🇯🇵")
        addRange("8J", "8N", "Japan", "🇯🇵")
        add(["HL", "DS", "D7", "D8", "D9", "6K", "6L", "6M", "6N"], "South Korea", "🇰🇷")
        add(["B"], "China", "🇨🇳")
        add(["BV"], "Taiwan", "🇹🇼")
        add(["VR"], "Hong Kong", "🇭🇰")
        add(["VU"], "India", "🇮🇳")
        add(["AP"], "Pakistan", "🇵🇰")
        add(["HS", "E2"], "Thailand", "🇹🇭")
        addRange("YB", "YH", "Indonesia", "🇮🇩")
        add(["9M", "9W"], "Malaysia", "🇲🇾")
        add(["9V"], "Singapore", "🇸🇬")
        addRange("DU", "DZ", "Philippines", "🇵🇭")
        add(["XV", "3W"], "Vietnam", "🇻🇳")
        add(["XU"], "Cambodia", "🇰🇭")
        add(["4S"], "Sri Lanka", "🇱🇰")
        add(["JT", "JU", "JV"], "Mongolia", "🇲🇳")

        // Oceania
        add(["VK", "AX"], "Australia", "🇦🇺")
        add(["ZL", "ZM"], "New Zealand", "🇳🇿")
        add(["KH6"], "Hawaii", "🇺🇸")
        add(["FK"], "New Caledonia", "🇳🇨")
        add(["3D2"], "Fiji", "🇫🇯")
        add(["5W"], "Samoa", "🇼🇸")
        add(["V7"], "Marshall Is.", "🇲🇭")
        add(["V8"], "Brunei", "🇧🇳")
        add(["P2"], "Papua N.G.", "🇵🇬")

        return t
    }()
}
