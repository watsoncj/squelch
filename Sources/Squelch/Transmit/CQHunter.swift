import Foundation

/// Scans a receive slot's CQ calls for "new ones" — DX, unworked US states,
/// unworked countries, contest CQs — so hunt mode can arm a countdown-
/// gated reply. Pure logic, no I/O: the app supplies the worked sets and
/// a state lookup.
enum CQHunter {
    struct Flags: Equatable {
        var dx = false
        var newStates = false
        var newCountries = false
        /// "CQ WW" — the directed CQ WSJT-X sends in WW Digi contest mode.
        var ww = false

        var any: Bool { dx || newStates || newCountries || ww }
    }

    /// Why a CQ matched, best reason wins: a country you've never worked
    /// beats a new state beats plain DX beats a contest CQ. (DX outranks
    /// the contest CQ because distance is what scores in WW Digi — a DX
    /// station calling "CQ WW" matches both and takes the DX rank.)
    enum Reason: Equatable {
        case newCountry(String)
        case newState(String)
        case dx(String)
        case contestCQ(String)

        var label: String {
            switch self {
            case .newCountry(let name): return "New country: \(name)"
            case .newState(let state): return "New state: \(state)"
            case .dx(let name): return "DX: \(name)"
            case .contestCQ(let modifier): return "Contest: CQ \(modifier)"
            }
        }

        /// Selection priority (lower wins). SNR breaks ties.
        var rank: Int {
            switch self {
            case .newCountry: return 0
            case .newState: return 1
            case .dx: return 2
            case .contestCQ: return 3
            }
        }
    }

    struct Candidate: Equatable {
        let call: String
        let grid: String?
        let snr: Float
        let reason: Reason
    }

    /// Continent-directed CQ modifiers ("CQ EU …") we respect.
    private static let continentCodes: Set<String> = ["NA", "SA", "EU", "AF", "AS", "OC", "AN"]

    /// The best huntable CQ in a slot's decodes, or nil to stay quiet.
    static func pick(
        decodes: [(text: String, snr: Float)],
        myCall: String,
        flags: Flags,
        workedCalls: Set<String>,
        workedStates: Set<String>,
        workedCountries: Set<String>,
        passedCalls: Set<String> = [],
        stateForGrid: (String) -> String?
    ) -> Candidate? {
        guard flags.any, !myCall.isEmpty else { return nil }
        let myCountry = CallsignCountry.lookup(myCall)?.name
        var best: Candidate?

        for decode in decodes {
            let parsed = FT8MessageParser.parse(decode.text)
            guard parsed.isCQ, let call = parsed.sender,
                  call != myCall.uppercased(),
                  !workedCalls.contains(call),
                  !passedCalls.contains(call),
                  answersDirectedCQ(text: decode.text, sender: call, myCountry: myCountry)
            else { continue }

            guard let reason = matchReason(
                call: call, grid: parsed.grid, modifier: cqModifier(text: decode.text, sender: call),
                flags: flags, myCountry: myCountry,
                workedStates: workedStates, workedCountries: workedCountries,
                stateForGrid: stateForGrid
            ) else { continue }

            let candidate = Candidate(call: call, grid: parsed.grid, snr: decode.snr, reason: reason)
            if let current = best {
                if (reason.rank, -candidate.snr) < (current.reason.rank, -current.snr) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }
        return best
    }

    private static func matchReason(
        call: String,
        grid: String?,
        modifier: String?,
        flags: Flags,
        myCountry: String?,
        workedStates: Set<String>,
        workedCountries: Set<String>,
        stateForGrid: (String) -> String?
    ) -> Reason? {
        let country = CallsignCountry.lookup(call)?.name

        // Own country never counts as a "new country" — that hunt is for
        // the log's gaps abroad; domestic coverage is the states hunt.
        if flags.newCountries, let country, country != myCountry,
           !workedCountries.contains(country) {
            return .newCountry(country)
        }
        // States only make sense for US stations, and only once the grid's
        // state has actually resolved — an unresolved grid is enqueued by
        // the lookup and may match on a later CQ.
        if flags.newStates, FT8MessageParser.isUSCallsign(call),
           let grid, let state = stateForGrid(grid),
           !workedStates.contains(state) {
            return .newState(state)
        }
        if flags.dx, let myCountry, country != myCountry {
            return .dx(country ?? "unknown prefix")
        }
        if flags.ww, modifier == "WW" {
            return .contestCQ("WW")
        }
        return nil
    }

    /// The directed-CQ modifier ("DX", "WW", "POTA"), or nil for a plain CQ.
    static func cqModifier(text: String, sender: String) -> String? {
        let tokens = text.uppercased().split(separator: " ").map(String.init)
        guard tokens.count >= 3, tokens[0] == "CQ", tokens[1] != sender else { return nil }
        return tokens[1]
    }

    /// Whether we're in the audience of a directed CQ: "CQ DX …" from our
    /// own country excludes us, "CQ EU …" excludes non-Europeans. Modifiers
    /// we don't recognize (POTA, contest exchanges) stay answerable.
    static func answersDirectedCQ(text: String, sender: String, myCountry: String?) -> Bool {
        let tokens = text.uppercased().split(separator: " ").map(String.init)
        guard tokens.count >= 2, tokens[0] == "CQ", tokens[1] != sender else { return true }
        let modifier = tokens[1]
        if modifier == "DX" {
            return CallsignCountry.lookup(sender)?.name != myCountry
        }
        if continentCodes.contains(modifier) {
            return modifier == continent(ofCountry: myCountry)
        }
        return true
    }

    /// Our own continent, for continent-directed CQs. Deliberately minimal:
    /// unknown → nil → we skip such CQs rather than barge in.
    private static func continent(ofCountry name: String?) -> String? {
        switch name {
        case "USA", "Alaska", "Canada", "Mexico", "Puerto Rico/USVI": return "NA"
        case "Hawaii", "Hawaii/US Pacific": return "OC"
        default: return nil
        }
    }

    /// Calls that count as already-worked for the hunt: same band and same
    /// contest context as the current session. A 20 m contact doesn't block
    /// hunting that station on 40 m, and during a contest only that
    /// contest's QSOs are dupes (contests expect re-working stations).
    static func dupeCalls(
        records: [QSORecord],
        dialMHz: Double,
        contest: String?
    ) -> Set<String> {
        let band = bandName(forMHz: dialMHz)
        return Set(records.lazy
            .filter { bandName(forMHz: $0.dialFrequencyMHz) == band && $0.contest == contest }
            .map { $0.partner.uppercased() })
    }

    /// Worked states/countries from the QSO log. States count only for US
    /// contacts (mirroring the log's WAS summary); countries come from the
    /// callsign prefix so the names match the hunter's own lookups, with
    /// the record's license-lookup country as fallback.
    static func workedSets(
        records: [QSORecord],
        stateForGrid: (String) -> String?
    ) -> (states: Set<String>, countries: Set<String>) {
        var states = Set<String>()
        var countries = Set<String>()
        for record in records {
            if let state = record.state {
                if record.country == nil || record.country == "United States" {
                    states.insert(state)
                }
            } else if FT8MessageParser.isUSCallsign(record.partner),
                      let grid = record.partnerGrid,
                      let state = stateForGrid(grid) {
                states.insert(state)
            }
            if let country = CallsignCountry.lookup(record.partner)?.name {
                countries.insert(country)
            } else if let country = record.country {
                countries.insert(country == "United States" ? "USA" : country)
            }
        }
        return (states, countries)
    }
}
