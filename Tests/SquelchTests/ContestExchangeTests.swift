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
        return seq
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

    /// A partner who keeps repeating their grid after our "R DM79" isn't
    /// running the contest exchange: repeat once, then fall back to a
    /// report and finish the standard way.
    func testCallerFallsBackToReportForStandardPartner() {
        let seq = makeSequencer(contest: true)
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW R DM79")

        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW R DM79", "one repeat")

        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -9)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW -09", "then the report they're waiting for")

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
