import XCTest
@testable import Squelch

/// Nonstandard callsigns (W0CJW/AG while awaiting a license upgrade in ULS)
/// arrive from partners with OUR call as a 22-bit hash — displayed in
/// brackets: "<W0CJW/AG> K1ABC R-05". Matching must strip the brackets or
/// every reply is silently ignored and the QSO stalls.
final class HashedCallsignTests: XCTestCase {

    func testSequencerMatchesHashedOwnCall() {
        let seq = QSOSequencer()
        seq.myCall = "W0CJW/AG"
        seq.myGrid4 = "DM79"

        seq.startCQ(parity: 0)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "CQ W0CJW/AG DM79")

        // Partner's client hashes our nonstandard call in their answer
        seq.ingest(decodes: [.init(text: "<W0CJW/AG> K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW/AG -07",
                       "hashed-form answer must advance the exchange")

        seq.ingest(decodes: [.init(text: "<W0CJW/AG> K1ABC R-12", snr: -8)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW/AG RR73")
    }

    func testSequencerStillMatchesPlainCall() {
        let seq = QSOSequencer()
        seq.myCall = "W0CJW"
        seq.myGrid4 = "DM79"
        seq.startCQ(parity: 0)
        seq.ingest(decodes: [.init(text: "W0CJW K1ABC EN52", snr: -7)], slotParity: 1)
        XCTAssertEqual(seq.transmission(forSlotParity: 0), "K1ABC W0CJW -07")
    }

    func testAutoAnswerCandidateMatchesHashedOwnCall() {
        let results = [FT8Result(snr: -11, timeOffset: 0.2, freqHz: 1500,
                                 text: "<W0CJW/AG> N0FW EM79")]
        let candidate = AppModel.callCandidate(in: results, myCall: "W0CJW/AG")
        XCTAssertEqual(candidate?.call, "N0FW")
        XCTAssertEqual(candidate?.grid, "EM79")
    }

    func testAutoAnswerIgnoresOtherHashedCalls() {
        let results = [FT8Result(snr: -11, timeOffset: 0.2, freqHz: 1500,
                                 text: "<K5XYZ/AG> N0FW EM79")]
        XCTAssertNil(AppModel.callCandidate(in: results, myCall: "W0CJW/AG"))
    }
}
