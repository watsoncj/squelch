import XCTest
@testable import RadioFun

final class FT8EncoderTests: XCTestCase {
    /// Full round trip through our own DSP: encode → decode.
    func testEncodeDecodeLoopback() throws {
        let decoder = try XCTUnwrap(FT8Decoder())
        for message in ["CQ W0CJW DM79", "K1ABC W0CJW -05", "K1ABC W0CJW RR73", "W0CJW K1ABC R+03"] {
            var samples = try XCTUnwrap(FT8Encoder.encode(message: message, frequencyHz: 1500),
                                        "encode failed for \(message)")
            XCTAssertGreaterThan(samples.count, 13 * FT8Decoder.sampleRate / 2)
            samples.append(contentsOf: [Float](repeating: 0, count: 15 * FT8Decoder.sampleRate - samples.count))
            let results = decoder.decodeSlot(samples)
            XCTAssertEqual(results.count, 1, "expected one decode for \(message)")
            XCTAssertEqual(results.first?.text, message)
            XCTAssertEqual(results.first?.freqHz ?? 0, 1500, accuracy: 5)
        }
    }

    func testEncodeRejectsGarbage() {
        XCTAssertNil(FT8Encoder.encode(message: "THIS IS MUCH TOO LONG TO BE AN FT8 MESSAGE AT ALL", frequencyHz: 1500))
    }

    func testFT4EncodeDecodeLoopback() throws {
        let decoder = try XCTUnwrap(FT8Decoder(mode: .ft4))
        for message in ["CQ W0CJW DM79", "K1ABC W0CJW R-07"] {
            var samples = try XCTUnwrap(FT8Encoder.encode(message: message, frequencyHz: 1200, mode: .ft4))
            // FT4 signal: 0.5 s lead + 5.04 s of tones, inside a 7.5 s slot
            XCTAssertEqual(Double(samples.count) / Double(FT8Decoder.sampleRate), 5.54, accuracy: 0.1)
            samples.append(contentsOf: [Float](repeating: 0, count: Int(7.5 * Double(FT8Decoder.sampleRate)) - samples.count))
            let results = decoder.decodeSlot(samples)
            XCTAssertEqual(results.count, 1, "expected one FT4 decode for \(message)")
            XCTAssertEqual(results.first?.text, message)
        }
    }

    func testFT8DecoderDoesNotDecodeFT4() throws {
        let decoder = try XCTUnwrap(FT8Decoder(mode: .ft8))
        var samples = try XCTUnwrap(FT8Encoder.encode(message: "CQ W0CJW DM79", frequencyHz: 1500, mode: .ft4))
        samples.append(contentsOf: [Float](repeating: 0, count: 15 * FT8Decoder.sampleRate - samples.count))
        XCTAssertEqual(decoder.decodeSlot(samples).count, 0)
    }
}

final class FT891CATTests: XCTestCase {
    func testParseFrequencyResponse() {
        XCTAssertEqual(FT891CAT.parseFrequencyResponse("FA014074000;"), 14.074)
        XCTAssertEqual(FT891CAT.parseFrequencyResponse("FA028074000;"), 28.074)
        XCTAssertNil(FT891CAT.parseFrequencyResponse("FA;"))
        XCTAssertNil(FT891CAT.parseFrequencyResponse("MD0C;"))
        XCTAssertNil(FT891CAT.parseFrequencyResponse("FA0280740;")) // wrong length
    }

    func testSetFrequencyCommand() {
        XCTAssertEqual(FT891CAT.setFrequencyCommand(mhz: 28.074), "FA028074000;")
        XCTAssertEqual(FT891CAT.setFrequencyCommand(mhz: 7.074), "FA007074000;")
        XCTAssertEqual(FT891CAT.setFrequencyCommand(mhz: 144.174), "FA144174000;")
    }

    func testParseModeResponse() {
        XCTAssertEqual(FT891CAT.parseModeResponse("MD0C;"), "DATA-USB")
        XCTAssertEqual(FT891CAT.parseModeResponse("MD02;"), "USB")
        XCTAssertNil(FT891CAT.parseModeResponse("FA014074000;"))
    }

    func testDigiModeSlots() {
        XCTAssertEqual(DigiMode.ft8.slotSeconds, 15.0)
        XCTAssertEqual(DigiMode.ft4.slotSeconds, 7.5)
    }
}

final class TechLegalityTests: XCTestCase {
    func testTenMeterDataSegment() {
        XCTAssertTrue(TransmitController.isTechLegalMHz(28.074))
        XCTAssertTrue(TransmitController.isTechLegalMHz(28.000))
        XCTAssertTrue(TransmitController.isTechLegalMHz(28.300))
        XCTAssertFalse(TransmitController.isTechLegalMHz(28.400)) // phone segment
    }

    func testHFBandsAreBlocked() {
        XCTAssertFalse(TransmitController.isTechLegalMHz(14.074)) // 20 m
        XCTAssertFalse(TransmitController.isTechLegalMHz(7.074))  // 40 m
        XCTAssertFalse(TransmitController.isTechLegalMHz(21.074)) // 15 m
    }

    func testVHFAndUp() {
        XCTAssertTrue(TransmitController.isTechLegalMHz(50.313)) // 6 m FT8
        XCTAssertTrue(TransmitController.isTechLegalMHz(144.174))
    }
}

final class QSOSequencerTests: XCTestCase {
    private func makeSequencer() -> QSOSequencer {
        let seq = QSOSequencer()
        seq.myCall = "W0CJW"
        seq.myGrid4 = "DM79"
        return seq
    }

    func testCallerSideFullQSO() {
        let seq = makeSequencer()
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }

        seq.startCQ(parity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "CQ W0CJW DM79")
        XCTAssertNil(seq.transmission(forSlotParity: 1), "must not transmit in the receive slot")

        // K1ABC answers with grid; their signal was -7 dB at our end
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW -07")

        // They roger our report and send theirs
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC R-12", snr: -8)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW RR73")

        let record = completed
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.partner, "K1ABC")
        XCTAssertEqual(record?.partnerGrid, "EN52")
        XCTAssertEqual(record?.reportSent, "-07")
        XCTAssertEqual(record?.reportReceived, "-12")

        // Nothing more from them → back to CQ
        seq.ingest(decodes: [], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "CQ W0CJW DM79")
    }

    func testAnswererSideFullQSO() {
        let seq = makeSequencer()
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }

        // K1ABC called CQ in even slots (parity 0) at -3 dB → we TX odd
        seq.replyTo(call: "K1ABC", snr: -3, cqParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "K1ABC W0CJW DM79")
        XCTAssertNil(seq.transmission(forSlotParity: 0))

        seq.ingest(decodes: [.init(text: "W0CJW K1ABC -05", snr: -4)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "K1ABC W0CJW R-03")

        seq.ingest(decodes: [.init(text: "W0CJW K1ABC RR73", snr: -4)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "K1ABC W0CJW 73")
        XCTAssertEqual(completed?.partner, "K1ABC")
        XCTAssertEqual(completed?.reportReceived, "-05")

        // 73 sent once, then idle
        seq.ingest(decodes: [], slotParity: 0)
        XCTAssertNil(seq.transmission(forSlotParity: 1))
        XCTAssertEqual(seq.mode, .idle)
    }

    func testRetriesThenReturnToCQ() {
        let seq = makeSequencer()
        seq.maxRetries = 2
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)

        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW -07")

        // K1ABC vanishes: report is retried, then we resume CQ
        seq.ingest(decodes: [], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW -07")
        seq.ingest(decodes: [], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW -07")
        seq.ingest(decodes: [], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "CQ W0CJW DM79")
    }

    func testCQGivesUpWhenUnanswered() {
        let seq = makeSequencer()
        seq.maxUnansweredCQ = 3
        seq.startCQ(parity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "CQ W0CJW DM79")
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "CQ W0CJW DM79")
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "CQ W0CJW DM79")
        XCTAssertNil(seq.transmission(forSlotParity: 0))
        XCTAssertEqual(seq.mode, .idle)
    }

    func testIgnoresMessagesForOthers() {
        let seq = makeSequencer()
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [
            .init(text: "K9XYZ K1ABC EN52", snr: -1), // not addressed to us
            .init(text: "CQ N0DEF DM33", snr: -2),
        ], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "CQ W0CJW DM79")
    }

    func testRepeatedRogerReportResendsRR73() {
        let seq = makeSequencer()
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC R-12", snr: -8)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW RR73")

        // They didn't hear it and repeat R-12 → we repeat RR73
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC R-12", snr: -9)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW RR73")
    }

    // MARK: - Mode transitions

    /// The real-world flow: calling CQ, then manually answering someone
    /// else's CQ that runs on the SAME parity as ours (the N5CAR case).
    func testSwitchFromCQToReply() {
        let seq = makeSequencer()
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }

        seq.startCQ(parity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "CQ W0CJW DM79")

        // N5CAR's CQ decodes in parity-0 (a slot we happened not to TX in).
        // User clicks Reply: we must flip to parity 1 — his listening slot.
        seq.replyTo(call: "N5CAR", snr: -9, cqParity: 0)
        XCTAssertNil(seq.transmission(forSlotParity: 0), "must vacate the old CQ parity")
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "N5CAR W0CJW DM79")

        // No stale CQ-mode state may leak into the exchange
        seq.ingest(decodes: [.init(text: "W0CJW N5CAR -17", snr: -8)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "N5CAR W0CJW R-09")
        seq.ingest(decodes: [.init(text: "W0CJW N5CAR RR73", snr: -8)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "N5CAR W0CJW 73")
        XCTAssertEqual(completed?.partner, "N5CAR")
        XCTAssertEqual(completed?.reportSent, "-09")
        XCTAssertEqual(completed?.reportReceived, "-17")

        // Manual reply replaced the CQ session: after the QSO we go idle,
        // we do NOT silently resume the interrupted CQ loop
        seq.ingest(decodes: [], slotParity: 0)
        XCTAssertNil(seq.transmission(forSlotParity: 1))
        XCTAssertNil(seq.transmission(forSlotParity: 0))
        XCTAssertEqual(seq.mode, .idle)
    }

    /// Replying while mid-QSO as the CQ caller abandons the old partner
    /// cleanly and starts fresh with the new one.
    func testReplySwitchesPartnerMidQSO() {
        let seq = makeSequencer()
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW -07")

        // Operator spots rarer DX and clicks Reply on VP8AA's CQ (parity 1)
        seq.replyTo(call: "VP8AA", snr: -15, cqParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "VP8AA W0CJW DM79")
        XCTAssertNil(seq.transmission(forSlotParity: 1))

        // The abandoned partner's messages are now ignored
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC R-12", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "VP8AA W0CJW DM79")
    }

    /// The N5CAR failure boundary: after retries exhaust, the sequencer is
    /// idle and a late report is ignored (documented current behavior —
    /// auto-answer may want to change this).
    func testLateReportAfterGiveUpIsIgnored() {
        let seq = makeSequencer()
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }

        seq.replyTo(call: "N5CAR", snr: -9, cqParity: 0)
        // Initial send + 3 retries, all unanswered
        for _ in 0..<4 {
            XCTAssertEqual(seq.transmission(forSlotParity: 1), "N5CAR W0CJW DM79")
            seq.ingest(decodes: [], slotParity: 0)
        }
        // Fifth window: gives up
        XCTAssertNil(seq.transmission(forSlotParity: 1))
        XCTAssertEqual(seq.mode, .idle)

        // His report finally decodes one slot later — too late
        seq.ingest(decodes: [.init(text: "W0CJW N5CAR -17", snr: -8)], slotParity: 0)
        XCTAssertNil(seq.transmission(forSlotParity: 1))
        XCTAssertEqual(seq.mode, .idle)
        XCTAssertNil(completed)
    }

    func testStopMidQSOGoesSilent() {
        let seq = makeSequencer()
        seq.startCQ(parity: 0)
        _ = seq.transmission(forSlotParity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW -07")

        seq.stop()
        XCTAssertEqual(seq.mode, .idle)
        XCTAssertNil(seq.transmission(forSlotParity: 0))
        XCTAssertNil(seq.transmission(forSlotParity: 1))
        // Partner's roger after stop must not wake anything up
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC R-12", snr: -7)], slotParity: 1)
        XCTAssertNil(seq.transmission(forSlotParity: 0))
    }

    /// Restarting CQ after a completed reply-QSO works from a clean slate.
    func testCQAfterReplyQSO() {
        let seq = makeSequencer()
        seq.replyTo(call: "N5CAR", snr: -9, cqParity: 0)
        _ = seq.transmission(forSlotParity: 1)
        seq.ingest(decodes: [.init(text: "W0CJW N5CAR -17", snr: -8)], slotParity: 0)
        _ = seq.transmission(forSlotParity: 1) // R-09
        seq.ingest(decodes: [.init(text: "W0CJW N5CAR RR73", snr: -8)], slotParity: 0)
        _ = seq.transmission(forSlotParity: 1) // 73
        seq.ingest(decodes: [], slotParity: 0)
        _ = seq.transmission(forSlotParity: 1) // winds down → idle

        seq.startCQ(parity: 1)
        XCTAssertEqual(seq.mode, .cqLoop)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "CQ W0CJW DM79")
        // Old partner's stray 73 must not confuse the new session
        seq.ingest(decodes: [.init(text: "W0CJW N5CAR 73", snr: -8)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "CQ W0CJW DM79")
    }

    // MARK: - Auto-answer entry points

    /// They answered our stopped CQ with a grid → we engage owing a report.
    func testEngageAsCaller() {
        let seq = makeSequencer()
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }

        seq.engageAsCaller(call: "K1ABC", grid: "EN52", snr: -7.4, theirParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "K1ABC W0CJW -07")
        XCTAssertNil(seq.transmission(forSlotParity: 0))

        seq.ingest(decodes: [.init(text: "W0CJW K1ABC R-12", snr: -8)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "K1ABC W0CJW RR73")
        XCTAssertEqual(completed?.partner, "K1ABC")
        XCTAssertEqual(completed?.partnerGrid, "EN52")
        XCTAssertEqual(completed?.reportReceived, "-12")
    }

    /// The N5CAR recovery: their report arrived while idle → we engage
    /// owing a roger, and the QSO completes.
    func testEngageAsAnswerer() {
        let seq = makeSequencer()
        var completed: QSORecord?
        seq.onQSOComplete = { completed = $0 }

        seq.engageAsAnswerer(call: "N5CAR", report: "-17", snr: -8.2, theirParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "N5CAR W0CJW R-08")

        seq.ingest(decodes: [.init(text: "W0CJW N5CAR RR73", snr: -8)], slotParity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 1), "N5CAR W0CJW 73")
        XCTAssertEqual(completed?.partner, "N5CAR")
        XCTAssertEqual(completed?.reportSent, "-08")
        XCTAssertEqual(completed?.reportReceived, "-17")

        seq.ingest(decodes: [], slotParity: 0)
        XCTAssertNil(seq.transmission(forSlotParity: 1))
        XCTAssertEqual(seq.mode, .idle)
    }

    func testNextTXWindow() {
        let period = 15.0
        // t = 0 is an even slot start; ask for the next odd window ≥5 s out
        let base = Date(timeIntervalSince1970: 0)
        let odd = QSOSequencer.nextTXWindow(parity: 1, period: period, after: base, minLead: 5)
        XCTAssertEqual(odd.timeIntervalSince1970, 15)
        // Even window at t=0 is "now" (lead 0 < 5) → next even is t=30
        let even = QSOSequencer.nextTXWindow(parity: 0, period: period, after: base, minLead: 5)
        XCTAssertEqual(even.timeIntervalSince1970, 30)
        // 2 s before an odd boundary with 5 s lead → skip to the next odd
        let late = Date(timeIntervalSince1970: 13)
        XCTAssertEqual(QSOSequencer.nextTXWindow(parity: 1, period: period, after: late, minLead: 5).timeIntervalSince1970, 45)
        // FT4 period
        XCTAssertEqual(QSOSequencer.nextTXWindow(parity: 0, period: 7.5, after: base, minLead: 5).timeIntervalSince1970, 15)
    }

    func testReportFormatting() {
        XCTAssertEqual(QSOSequencer.formatReport(-7.4), "-07")
        XCTAssertEqual(QSOSequencer.formatReport(3.6), "+04")
        XCTAssertEqual(QSOSequencer.formatReport(-42), "-30") // clamped
        XCTAssertTrue(QSOSequencer.isReport("-05"))
        XCTAssertFalse(QSOSequencer.isReport("EN52"))
        XCTAssertEqual(QSOSequencer.rogerReportValue("R-08"), "-08")
        XCTAssertNil(QSOSequencer.rogerReportValue("RR73"))
    }
}
