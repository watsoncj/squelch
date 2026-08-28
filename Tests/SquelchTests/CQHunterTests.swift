import XCTest
@testable import Squelch

final class CQHunterTests: XCTestCase {

    private let noStates: (String) -> String? = { _ in nil }

    private func pick(
        _ decodes: [(String, Float)],
        flags: CQHunter.Flags,
        myCall: String = "W0CJW",
        workedCalls: Set<String> = [],
        workedStates: Set<String> = [],
        workedCountries: Set<String> = [],
        passedCalls: Set<String> = [],
        stateForGrid: ((String) -> String?)? = nil
    ) -> CQHunter.Candidate? {
        CQHunter.pick(
            decodes: decodes.map { (text: $0.0, snr: $0.1) },
            myCall: myCall,
            flags: flags,
            workedCalls: workedCalls,
            workedStates: workedStates,
            workedCountries: workedCountries,
            passedCalls: passedCalls,
            stateForGrid: stateForGrid ?? noStates
        )
    }

    // MARK: - DX

    func testDXPicksForeignCQOnly() {
        let candidate = pick(
            [("CQ K1ABC FN42", -3), ("CQ JA3XYZ PM74", -11)],
            flags: CQHunter.Flags(dx: true)
        )
        XCTAssertEqual(candidate?.call, "JA3XYZ")
        XCTAssertEqual(candidate?.reason, .dx("Japan"))
        XCTAssertEqual(candidate?.grid, "PM74")
    }

    func testDXIgnoresDomesticAndNonCQTraffic() {
        XCTAssertNil(pick(
            [("CQ K1ABC FN42", -3), ("W0CJW JA3XYZ -12", -5), ("K1ABC G4JKL IO91", -8)],
            flags: CQHunter.Flags(dx: true)
        ))
    }

    func testWorkedAndPassedCallsAreSkipped() {
        let decodes: [(String, Float)] = [("CQ JA3XYZ PM74", -11), ("CQ DL1AAA JO31", -15)]
        let worked = pick(decodes, flags: CQHunter.Flags(dx: true), workedCalls: ["JA3XYZ"])
        XCTAssertEqual(worked?.call, "DL1AAA")
        let passed = pick(decodes, flags: CQHunter.Flags(dx: true), passedCalls: ["JA3XYZ", "DL1AAA"])
        XCTAssertNil(passed)
    }

    func testNoFlagsNoCandidate() {
        XCTAssertNil(pick([("CQ JA3XYZ PM74", -1)], flags: CQHunter.Flags()))
    }

    func testHigherSNRWinsWithinSameReason() {
        let candidate = pick(
            [("CQ JA3XYZ PM74", -18), ("CQ DL1AAA JO31", -4)],
            flags: CQHunter.Flags(dx: true)
        )
        XCTAssertEqual(candidate?.call, "DL1AAA")
    }

    // MARK: - Directed CQs

    func testCQDXFromOwnCountryExcludesUs() {
        // A US station calling "CQ DX" doesn't want another US station
        XCTAssertNil(pick(
            [("CQ DX K1ABC FN42", -3)],
            flags: CQHunter.Flags(newStates: true),
            stateForGrid: { _ in "MA" }
        ))
        // But a foreign "CQ DX" wants exactly us
        let candidate = pick([("CQ DX JA3XYZ PM74", -11)], flags: CQHunter.Flags(dx: true))
        XCTAssertEqual(candidate?.call, "JA3XYZ")
    }

    func testContinentDirectedCQ() {
        // "CQ EU" from Germany — we're NA, not wanted
        XCTAssertNil(pick([("CQ EU DL1AAA JO31", -5)], flags: CQHunter.Flags(dx: true)))
        // "CQ NA" from Germany — that's us
        let candidate = pick([("CQ NA DL1AAA JO31", -5)], flags: CQHunter.Flags(dx: true))
        XCTAssertEqual(candidate?.call, "DL1AAA")
    }

    func testUnrecognizedModifierStaysAnswerable() {
        let candidate = pick([("CQ POTA VE3MNO FN03", -9)], flags: CQHunter.Flags(dx: true))
        XCTAssertEqual(candidate?.call, "VE3MNO")
        XCTAssertEqual(candidate?.reason, .dx("Canada"))
    }

    // MARK: - New states

    func testNewStateMatchesOnlyUnworkedResolvedStates() {
        let states = ["FN42": "MA", "DM79": "CO"]
        let lookup: (String) -> String? = { states[$0] }
        let flags = CQHunter.Flags(newStates: true)

        let fresh = pick([("CQ K1ABC FN42", -3)], flags: flags, stateForGrid: lookup)
        XCTAssertEqual(fresh?.reason, .newState("MA"))

        // Already-worked state: no match
        XCTAssertNil(pick([("CQ K1ABC FN42", -3)], flags: flags,
                          workedStates: ["MA"], stateForGrid: lookup))
        // Unresolved grid: conservatively no match (lookup is queued for later)
        XCTAssertNil(pick([("CQ K5DEF EM12", -3)], flags: flags, stateForGrid: lookup))
        // Foreign station never matches a state
        XCTAssertNil(pick([("CQ JA3XYZ PM74", -3)], flags: flags, stateForGrid: { _ in "TX" }))
    }

    // MARK: - New countries

    func testNewCountryExcludesOwnAndWorked() {
        let flags = CQHunter.Flags(newCountries: true)
        let candidate = pick([("CQ JA3XYZ PM74", -11)], flags: flags)
        XCTAssertEqual(candidate?.reason, .newCountry("Japan"))

        XCTAssertNil(pick([("CQ JA3XYZ PM74", -11)], flags: flags, workedCountries: ["Japan"]))
        // Own country is never a "new country", even with an empty log
        XCTAssertNil(pick([("CQ K1ABC FN42", -1)], flags: flags))
    }

    func testReasonPriorityNewCountryBeatsDXAndState() {
        // Weak new-country beats strong plain DX (Japan worked → DX only)
        let candidate = pick(
            [("CQ JA3XYZ PM74", -1), ("CQ ZL1XYZ RF73", -20)],
            flags: CQHunter.Flags(dx: true, newCountries: true),
            workedCountries: ["Japan"]
        )
        XCTAssertEqual(candidate?.reason, .newCountry("New Zealand"))

        // New state beats plain DX
        let stateWins = pick(
            [("CQ JA3XYZ PM74", -1), ("CQ K1ABC FN42", -20)],
            flags: CQHunter.Flags(dx: true, newStates: true, newCountries: true),
            workedCountries: ["Japan"],
            stateForGrid: { $0 == "FN42" ? "MA" : nil }
        )
        XCTAssertEqual(stateWins?.reason, .newState("MA"))
    }

    // MARK: - Worked sets

    // MARK: - Contest CQ

    func testWWHuntsOnlyContestDirectedCQs() {
        let ww = CQHunter.Flags(ww: true)
        XCTAssertNil(pick([("CQ K1ABC FN42", -5)], flags: ww), "plain CQ is not a contest CQ")
        XCTAssertNil(pick([("CQ TEST K1ABC FN42", -5)], flags: ww), "only WW, not other contests")
        XCTAssertNil(pick([("W0CJW K1ABC R FN42", -5)], flags: ww), "not a CQ at all")
        let candidate = pick([("CQ WW K1ABC FN42", -5)], flags: ww)
        XCTAssertEqual(candidate?.call, "K1ABC")
        XCTAssertEqual(candidate?.grid, "FN42")
        XCTAssertEqual(candidate?.reason, .contestCQ("WW"))
        XCTAssertEqual(candidate?.reason.label, "Contest: CQ WW")
    }

    /// DX scores in WW Digi, so a DX station outranks a domestic CQ WW —
    /// and a DX station calling CQ WW takes the DX rank.
    func testDXOutranksContestCQ() {
        let flags = CQHunter.Flags(dx: true, ww: true)
        let candidate = pick([("CQ WW K1ABC FN42", -3), ("CQ JA3XYZ PM74", -15)], flags: flags)
        XCTAssertEqual(candidate?.call, "JA3XYZ")
        XCTAssertEqual(pick([("CQ WW JA3XYZ PM74", -15)], flags: flags)?.reason, .dx("Japan"))
    }

    func testWWRespectsWorkedAndPassed() {
        let ww = CQHunter.Flags(ww: true)
        XCTAssertNil(pick([("CQ WW K1ABC FN42", -5)], flags: ww, workedCalls: ["K1ABC"]))
        XCTAssertNil(pick([("CQ WW K1ABC FN42", -5)], flags: ww, passedCalls: ["K1ABC"]))
        XCTAssertNil(pick([("CQ WW W0CJW DM79", -5)], flags: ww), "never our own CQ")
    }

    func testCQModifierExtraction() {
        XCTAssertEqual(CQHunter.cqModifier(text: "CQ WW K1ABC FN42", sender: "K1ABC"), "WW")
        XCTAssertEqual(CQHunter.cqModifier(text: "CQ DX K1ABC FN42", sender: "K1ABC"), "DX")
        XCTAssertNil(CQHunter.cqModifier(text: "CQ K1ABC FN42", sender: "K1ABC"))
        XCTAssertNil(CQHunter.cqModifier(text: "CQ K1ABC", sender: "K1ABC"))
        XCTAssertNil(CQHunter.cqModifier(text: "W0CJW K1ABC FN42", sender: "K1ABC"))
    }

    func testWorkedSetsFromRecords() {
        func record(_ partner: String, grid: String? = nil, state: String? = nil, country: String? = nil) -> QSORecord {
            QSORecord(id: UUID(), partner: partner, partnerGrid: grid, reportSent: "-05",
                      reportReceived: "-10", start: Date(), end: Date(),
                      dialFrequencyMHz: 28.074, mode: "FT8",
                      state: state, country: country)
        }
        let records = [
            record("K1ABC", grid: "FN42", state: "MA", country: "United States"),
            record("VE3MNO", grid: "FN03", state: "ON", country: "Canada"), // province ≠ WAS state
            record("K5DEF", grid: "EM12"),                                  // state via grid resolver
            record("JA3XYZ", grid: "PM74"),
        ]
        let sets = CQHunter.workedSets(records: records) { grid in
            grid == "EM12" ? "TX" : nil
        }
        XCTAssertEqual(sets.states, ["MA", "TX"])
        XCTAssertEqual(sets.countries, ["USA", "Canada", "Japan"])
    }
}
