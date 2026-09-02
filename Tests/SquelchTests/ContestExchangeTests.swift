import XCTest
@testable import Squelch

/// The grid-only contest exchange (WW Digi / NA VHF style): "R GRID" in
/// place of the signal report, RR73 straight after.
final class ContestExchangeTests: XCTestCase {
    private func makeSequencer(contest: Bool) -> QSOSequencer {
        let seq = QSOSequencer()
        seq.myCall = "W0CJW"
        seq.myGrid4 = "DM79"
        seq.isContestActive = { contest }
        seq.isContestExchange = { contest }
        seq.speaksContestExchange = { _ in true } // profiled — the fast path
        return seq
    }

    // MARK: Who gets "R GRID"

    func testContestSpeakersProfile() {
        let speakers = ContestSpeakers()
        speakers.note(["CQ K1ABC FN42", "K1ABC W9XYZ RR73", "CQ DX N0FW EM79"], myCall: "W0CJW")
        XCTAssertFalse(speakers.speaks("K1ABC"), "a plain CQ says nothing")
        XCTAssertFalse(speakers.speaks("N0FW"), "CQ DX isn't the contest call")
        speakers.note("CQ WW K1ABC FN42", myCall: "W0CJW")
        XCTAssertTrue(speakers.speaks("K1ABC"))
        speakers.note("N0FW W9XYZ R EM79", myCall: "W0CJW")
        XCTAssertTrue(speakers.speaks("w9xyz"), "an R GRID to anyone profiles the sender")
        XCTAssertFalse(speakers.speaks("N0FW"), "…not the addressee")
        speakers.note("K1ABC W0CJW R DM79", myCall: "W0CJW")
        XCTAssertFalse(speakers.speaks("W0CJW"), "our own loopback never counts")
    }

    /// KY0R, 03:26Z: a station never heard using the contest exchange
    /// gets a report first — the message every program understands.
    func testUnprofiledStationGetsReportFirst() {
        let seq = makeSequencer(contest: true)
        seq.speaksContestExchange = { $0 == "K1ABC" }
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW KY0R DM78", snr: -14)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "KY0R W0CJW -14")
        // A standard station completes the standard way
        seq.ingest(decodes: [.init(text: "W0CJW KY0R R-07", snr: -14)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "KY0R W0CJW RR73")
        XCTAssertEqual(completed?.reportReceived, "-07")

        // A profiled station still gets the fast path
        seq.ingest(decodes: [], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "CQ W0CJW DM79")
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW R DM79")
    }

    /// A search-and-pounce contest station never sends CQ WW or R GRID,
    /// so it can't be profiled — answering our "CQ WW" is the evidence.
    func testAnswerToCQWWGetsRogerGridUnprofiled() {
        let seq = makeSequencer(contest: true)
        seq.speaksContestExchange = { _ in false }
        seq.cqModifier = "WW"
        seq.startCQ(parity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "CQ WW W0CJW DM79")
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW R DM79")

        // A plain CQ carries no such evidence — report first
        let plain = makeSequencer(contest: true)
        plain.speaksContestExchange = { _ in false }
        plain.startCQ(parity: 0)
        _ = plain.transmission(forSlotParity: 0)
        plain.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(plain.transmission(forSlotParity: 0), "K1ABC W0CJW -07")

        // Outside a contest the flavor changes nothing
        let casual = makeSequencer(contest: false)
        casual.cqModifier = "WW"
        casual.startCQ(parity: 0)
        _ = casual.transmission(forSlotParity: 0)
        casual.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(casual.transmission(forSlotParity: 0), "K1ABC W0CJW -07")
    }

    /// A contest-mode WSJT-X station given a report answers "R GRID" —
    /// the conservative lead costs one slot, never the QSO.
    func testUnprofiledContestStationStillCompletes() {
        let seq = makeSequencer(contest: true)
        seq.speaksContestExchange = { _ in false }
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW S52XYZ JN76", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "S52XYZ W0CJW -07")
        seq.ingest(decodes: [.init(text: "W0CJW S52XYZ R JN76", snr: -8)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "S52XYZ W0CJW RR73")
        XCTAssertEqual(completed?.partnerGrid, "JN76")
        XCTAssertNil(completed?.reportReceived)
    }

    // MARK: Parsing

    func testParserReadsRogerGrid() {
        let p = FT8MessageParser.parse("W0CJW K1ABC R EN52")
        XCTAssertEqual(p.addressee, "W0CJW")
        XCTAssertEqual(p.sender, "K1ABC")
        XCTAssertEqual(p.grid, "EN52")
        XCTAssertTrue(p.isRogerGrid)
        XCTAssertFalse(FT8MessageParser.parse("W0CJW K1ABC EN52").isRogerGrid)

        XCTAssertEqual(FT8MessageParser.rogerGridValue("R EN52"), "EN52")
        XCTAssertNil(FT8MessageParser.rogerGridValue("R-05"), "roger report is not a grid")
        XCTAssertNil(FT8MessageParser.rogerGridValue("R RR73"), "RR73 is a sign-off, not a grid")
        XCTAssertNil(FT8MessageParser.rogerGridValue("EN52"))
        XCTAssertNil(FT8MessageParser.rogerGridValue("R EN52 X"))
    }

    func testPayloadTokenCarriesBothRogerGridTokens() {
        let text = "W0CJW K1ABC R EN52"
        let m = DecodedMessage(
            id: UUID(), slotStart: Date(), snr: -5, timeOffset: 0.5,
            audioFrequency: 1500, dialFrequencyMHz: 14.074, text: text,
            callsign: FT8MessageParser.parse(text).sender,
            grid: FT8MessageParser.parse(text).grid,
            latitude: nil, longitude: nil, distanceKm: nil
        )
        XCTAssertEqual(m.payloadToken, "R EN52")
        XCTAssertTrue(m.isAnswerable(by: "W0CJW"))
        XCTAssertEqual(m.feedSummary(myCall: "W0CJW"), "→ you: roger, grid EN52")
    }

    /// ft8_lib's packer had no "R " + grid path — the message would have
    /// fallen through to free text and failed. Both directions must hold.
    func testEncodeDecodeRogerGrid() throws {
        let decoder = try XCTUnwrap(FT8Decoder())
        let message = "K1ABC W0CJW R DM79"
        var samples = try XCTUnwrap(FT8Encoder.encode(message: message, frequencyHz: 1500))
        samples.append(contentsOf: [Float](repeating: 0, count: 15 * FT8Decoder.sampleRate - samples.count))
        let results = decoder.decodeSlot(samples)
        XCTAssertEqual(results.first?.text, message)
        XCTAssertEqual(results.count, 1)
    }

    /// The contest messages ride the same 77-bit payload in FT4 — pinned
    /// through the FT4 modulator/decoder too, since WW Digi runs on both.
    func testFT4EncodeDecodeContestMessages() throws {
        let decoder = try XCTUnwrap(FT8Decoder(mode: .ft4))
        for message in ["K1ABC W0CJW R DM79", "CQ WW W0CJW DM79", "K1ABC W0CJW RR73"] {
            var samples = try XCTUnwrap(FT8Encoder.encode(message: message, frequencyHz: 1200, mode: .ft4),
                                        "FT4 encode failed for \(message)")
            samples.append(contentsOf: [Float](repeating: 0, count: Int(7.5 * Double(FT8Decoder.sampleRate)) - samples.count))
            let results = decoder.decodeSlot(samples)
            XCTAssertEqual(results.first?.text, message)
        }
    }

    func testCallCandidateRecognizesRogerGrid() {
        let results = [FT8Result(snr: -3, timeOffset: 0, freqHz: 1200, text: "W0CJW K1ABC R EN52")]
        let c = AppModel.callCandidate(in: results, myCall: "W0CJW")
        XCTAssertEqual(c?.call, "K1ABC")
        XCTAssertEqual(c?.rogerGrid, "EN52")
        XCTAssertNil(c?.grid)
        XCTAssertNil(c?.report)
    }

    // MARK: Caller side (we CQ)

    func testCallerSideContestExchange() {
        let seq = makeSequencer(contest: true)
        seq.modeName = { "FT4" }
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }

        seq.startCQ(parity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "CQ W0CJW DM79")

        // K1ABC answers with a grid → we roger with ours, no report
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW R DM79")
        XCTAssertEqual(seq.stateDescription, "R DM79 to K1ABC (EN52)")

        // Their RR73 closes it: logged, and the very next slot is a CQ
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC RR73", snr: -8)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "CQ W0CJW DM79",
                       "no 73 in the contest sequence — straight back to CQ")

        XCTAssertEqual(completed?.partner, "K1ABC")
        XCTAssertEqual(completed?.partnerGrid, "EN52")
        XCTAssertEqual(completed?.reportSent, "")
        XCTAssertNil(completed?.reportReceived)
        XCTAssertEqual(completed?.mode, "FT4")
    }

    /// RRR asks for a final — it gets a 73. A bare 73 closes like RR73.
    func testCallerSideRRRGetsA73() {
        let seq = makeSequencer(contest: true)
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW R DM79")
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC RRR", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW 73")
        XCTAssertNotNil(completed)
        seq.ingest(decodes: [], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "CQ W0CJW DM79")
    }

    /// The option is a no-op outside a contest: a grid answer still gets a
    /// report, exactly as before.
    func testContestExchangeOffKeepsReports() {
        let seq = makeSequencer(contest: false)
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW -07")
    }

    /// A station answering with a bare report is running the standard
    /// sequence — it gets a report back, contest or not.
    func testBareReportAnswerStaysStandardMidContest() {
        let seq = makeSequencer(contest: true)
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW NR1W -14", snr: -15.5)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "NR1W W0CJW -16")
        seq.ingest(decodes: [.init(text: "W0CJW NR1W RR73", snr: -15)], slotParity: 1)
        XCTAssertEqual(completed?.reportReceived, "-14")
    }

    /// A partner who repeats their grid after our "R DM79" isn't running
    /// the contest exchange (or missed us): the first repeat earns the
    /// report, and the exchange finishes the standard way. KW8CW and KY0R
    /// both left after one unanswered repeat — no second chance.
    func testCallerFallsBackToReportForStandardPartner() {
        let seq = makeSequencer(contest: true)
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW R DM79")

        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -9)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW -09", "first repeat → the report they're waiting for")

        seq.ingest(decodes: [.init(text: "W0CJW K1ABC R-12", snr: -9)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW RR73")
        XCTAssertEqual(completed?.reportSent, "-09")
        XCTAssertEqual(completed?.reportReceived, "-12")
    }

    /// Give up on a silent partner after sending "R GRID" — their grid was
    /// in hand, so a straggling RR73 still logs the contact.
    func testLateRR73AfterContestGiveUpStillLogs() {
        let seq = makeSequencer(contest: true)
        seq.maxRetries = 1
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW R DM79")
        // Silence: retry, then give up and CQ again
        seq.ingest(decodes: [], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW R DM79")
        seq.ingest(decodes: [], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "CQ W0CJW DM79")
        XCTAssertNil(completed)

        seq.ingest(decodes: [.init(text: "W0CJW K1ABC RR73", snr: -7)], slotParity: 1)
        XCTAssertEqual(completed?.partner, "K1ABC")
        XCTAssertEqual(completed?.partnerGrid, "EN52")
        XCTAssertEqual(completed?.reportSent, "")
    }

    /// Pileup: the queued caller after a contest QSO gets "R GRID" too.
    func testPileupCallerGetsRogerGrid() {
        let seq = makeSequencer(contest: true)
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW R DM79")
        // W9XYZ answers while we're busy; K1ABC closes
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC RR73", snr: -7),
                             .init(text: "W0CJW W9XYZ EN37", snr: -3)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "W9XYZ W0CJW R DM79")
    }

    /// WSJT-X in WW Digi mode rogers a signal report with "R GRID" (its Tx3
    /// carries the grid no matter what it received). With the option OFF
    /// that is exactly what a contest station answering our CQ sends back
    /// to our report — it must close the QSO, not stall it.
    func testStandardCallerAcceptsRogerGridAsRoger() {
        let seq = makeSequencer(contest: false)
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW S52XYZ JN76", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "S52XYZ W0CJW -07")

        seq.ingest(decodes: [.init(text: "W0CJW S52XYZ R JN76", snr: -8)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "S52XYZ W0CJW RR73")
        XCTAssertEqual(completed?.partner, "S52XYZ")
        XCTAssertEqual(completed?.partnerGrid, "JN76")
        XCTAssertEqual(completed?.reportSent, "-07")
        XCTAssertNil(completed?.reportReceived, "they never sent one")

        // They missed the RR73 and repeat their roger → RR73 again; their
        // 73 (WSJT-X sends one) ends it
        seq.ingest(decodes: [.init(text: "W0CJW S52XYZ R JN76", snr: -8)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "S52XYZ W0CJW RR73")
        seq.ingest(decodes: [.init(text: "W0CJW S52XYZ 73", snr: -8)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "CQ W0CJW DM79")
    }

    /// A bare "W0CJW K1ABC" repeat (no grid) counts as a repeat too.
    func testBareCallRepeatCountsTowardFallback() {
        let seq = makeSequencer(contest: true)
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW R DM79")
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC", snr: -9)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW -09")
    }

    /// No own grid → nothing to roger with; the report sequence is used.
    func testContestExchangeNeedsOwnGrid() {
        let seq = makeSequencer(contest: true)
        seq.myGrid4 = ""
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW -07")
    }

    /// The "CQ WW" directed call WSJT-X sends in WW Digi mode parses like
    /// any modifier, and is a valid modifier for our own CQ.
    func testCQWWParsesAndIsSendable() {
        let p = FT8MessageParser.parse("CQ WW K1ABC FN42")
        XCTAssertTrue(p.isCQ)
        XCTAssertEqual(p.sender, "K1ABC")
        XCTAssertEqual(p.grid, "FN42")
        XCTAssertTrue(QSOSequencer.isValidCQModifier("WW"))
        XCTAssertNotNil(FT8Encoder.encode(message: "CQ WW W0CJW DM79", frequencyHz: 1500))
    }

    /// KJ5PTH, 2026-08-29 03:10Z: two stations answered one CQ; the first
    /// closed with RR73 in the same slot the second was still sending its
    /// grid. Promoting the second mid-slot must not count that grid as a
    /// "repeat" of an R GRID we hadn't sent yet — it took one genuine
    /// repeat to a report instead of two.
    func testPileupCallerGridInPromotionSlotIsNotARepeat() {
        let seq = makeSequencer(contest: true)
        seq.startCQ(parity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "CQ W0CJW DM79")

        // Two answers in one slot: KS4OT is taken, KJ5PTH queued
        seq.ingest(decodes: [.init(text: "W0CJW KS4OT EM83", snr: -10),
                             .init(text: "W0CJW KJ5PTH EL39", snr: -12)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "KS4OT W0CJW R DM79")

        // KS4OT closes; KJ5PTH's grid lands in the very same slot — the
        // decoder's order puts the RR73 first, so KJ5PTH is promoted and
        // then his grid is handled while he's already the partner
        seq.ingest(decodes: [.init(text: "W0CJW KS4OT RR73", snr: -11),
                             .init(text: "W0CJW KJ5PTH EL39", snr: -16)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "KJ5PTH W0CJW R DM79",
                       "the grid heard in the promotion slot predates our R GRID and must not count as a repeat — first TX is R GRID, not a report")

        // The first genuine repeat → the report
        seq.ingest(decodes: [.init(text: "W0CJW KJ5PTH EL39", snr: -14)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "KJ5PTH W0CJW -14")
    }

    /// The same protection when the grid and the promotion arrive in the
    /// other order within the slot (grid decoded before the RR73): the
    /// grid is queued for a non-partner, then he's promoted — still no
    /// repeat counted.
    func testPileupPromotionOrderIndependent() {
        let seq = makeSequencer(contest: true)
        seq.startCQ(parity: 1)
        _ = seq.transmission(forSlotParity: 1)
        seq.ingest(decodes: [.init(text: "W0CJW KS4OT EM83", snr: -10),
                             .init(text: "W0CJW KJ5PTH EL39", snr: -12)], slotParity: 0)
        _ = seq.transmission(forSlotParity: 1)
        seq.ingest(decodes: [.init(text: "W0CJW KJ5PTH EL39", snr: -16),
                             .init(text: "W0CJW KS4OT RR73", snr: -11)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "KJ5PTH W0CJW R DM79")
        seq.ingest(decodes: [.init(text: "W0CJW KJ5PTH EL39", snr: -14)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "KJ5PTH W0CJW -14")
    }

    /// A grid repeat that arrives after a *retry* of R GRID (silence in
    /// between) still counts — the flag is about whether it was ever sent,
    /// not about the slot immediately before.
    func testRepeatAfterSilentRetryStillCounts() {
        let seq = makeSequencer(contest: true)
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW R DM79")
        seq.ingest(decodes: [], slotParity: 1) // silence → retry
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW R DM79")
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -9)], slotParity: 1) // the repeat
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW -09")
    }

    // MARK: Answerer side (we answered their CQ)

    /// Their "R GRID" completes the contact whether or not the option is
    /// on — this is what a WSJT-X station in WW Digi mode sends us.
    func testAnswererAcceptsRogerGridWithOptionOff() {
        let seq = makeSequencer(contest: false)
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }

        seq.replyTo(call: "K1ABC", snr: -5, cqParity: 0, grid: "EN52")
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "K1ABC W0CJW DM79")

        seq.ingest(decodes: [.init(text: "W0CJW K1ABC R EN52", snr: -6)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "K1ABC W0CJW RR73")
        XCTAssertEqual(completed?.partner, "K1ABC")
        XCTAssertEqual(completed?.partnerGrid, "EN52")
        XCTAssertEqual(completed?.reportSent, "")
        XCTAssertNil(completed?.reportReceived)

        // They missed our RR73 and repeat — resend it; then done
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC R EN52", snr: -6)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "K1ABC W0CJW RR73")
        seq.ingest(decodes: [], slotParity: 0)
        XCTAssertNil(seq.transmission(forSlotParity: 1))
        XCTAssertEqual(seq.mode, .idle)
    }

    /// Reply to a CQ with the option on — the partner may still send a
    /// report (standard station); the exchange must complete their way.
    func testAnswererStillHandlesReportMidContest() {
        let seq = makeSequencer(contest: true)
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }
        seq.replyTo(call: "K1ABC", snr: -5, cqParity: 0, grid: "EN52")
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "K1ABC W0CJW DM79")
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC -10", snr: -6)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "K1ABC W0CJW R-05")
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC RR73", snr: -6)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "K1ABC W0CJW 73")
        XCTAssertEqual(completed?.reportReceived, "-10")
    }

    /// From idle, a roger-grid addressed to us (late reply, or a click on
    /// the message) logs at once and answers RR73.
    func testEngageWithRogerGridFromIdle() {
        let seq = makeSequencer(contest: false)
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }
        seq.engageWithRogerGrid(call: "K1ABC", grid: "EN52", snr: -4, theirParity: 0)
        XCTAssertEqual(completed?.partner, "K1ABC")
        XCTAssertEqual(completed?.partnerGrid, "EN52")
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "K1ABC W0CJW RR73")
        seq.ingest(decodes: [], slotParity: 0)
        XCTAssertNil(seq.transmission(forSlotParity: 1))
        XCTAssertEqual(seq.mode, .idle)
    }

    /// A logged partner who lost our RR73 and repeats "R GRID" gets a
    /// courtesy re-ack from idle — never a second log entry.
    func testCourtesyRR73ForRepeatedRogerGrid() {
        let seq = makeSequencer(contest: false)
        var logged = 0
        seq.onQSOComplete = { _ in logged += 1 }
        seq.replyTo(call: "K1ABC", snr: -5, cqParity: 0, grid: "EN52")
        _ = seq.transmission(forSlotParity: 1)
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC R EN52", snr: -6)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "K1ABC W0CJW RR73")
        seq.ingest(decodes: [], slotParity: 0)
        XCTAssertNil(seq.transmission(forSlotParity: 1))
        XCTAssertEqual(seq.mode, .idle)

        seq.ingest(decodes: [.init(text: "W0CJW K1ABC R EN52", snr: -6)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "K1ABC W0CJW RR73")
        XCTAssertEqual(logged, 1)
    }
}
