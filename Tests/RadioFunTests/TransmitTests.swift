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
