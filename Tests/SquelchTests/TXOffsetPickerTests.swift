import XCTest
@testable import Squelch

final class TXOffsetPickerTests: XCTestCase {
    func testEmptyBandPicksMidband() {
        XCTAssertEqual(TXOffsetPicker.pick(occupants: []), 1500)
    }

    func testAvoidsSameParityOccupant() {
        let occupants = [TXOffsetPicker.Occupant(frequency: 1500, sameParity: true, age: 10)]
        let picked = TXOffsetPicker.pick(occupants: occupants)
        // Clear of the occupant's 1500–1550 span plus guard
        XCTAssertTrue(picked + 60 <= 1500 || picked - 10 >= 1550, "picked \(picked)")
    }

    func testPrefersOnlyGapInCrowdedBand() {
        // Stations every 25 Hz except a gap at 2000–2225
        var occupants: [TXOffsetPicker.Occupant] = []
        var f = 300.0
        while f <= 2800 {
            if !(2000...2225).contains(f) {
                occupants.append(.init(frequency: f, sameParity: true, age: 5))
            }
            f += 25
        }
        let picked = TXOffsetPicker.pick(occupants: occupants)
        // Last occupant below the gap tops out at 1975+50, first above
        // starts at 2250; the pick's guarded span must fit between
        XCTAssertTrue(picked - 10 >= 2025 && picked + 60 <= 2250, "picked \(picked)")
    }

    func testSameParityWeighsHeavierThanOpposite() {
        // Two otherwise-identical occupants near mid-band: the pick must
        // land on (or nearer) the opposite-parity one when squeezed
        let occupants = [
            TXOffsetPicker.Occupant(frequency: 1480, sameParity: true, age: 5),
            TXOffsetPicker.Occupant(frequency: 1520, sameParity: false, age: 5),
        ]
        let same = TXOffsetPicker.score(offset: 1450, occupants: occupants,
                                        spectrum: [], spectrumStartHz: 0, spectrumHzPerBin: 1)
        let opposite = TXOffsetPicker.score(offset: 1550, occupants: occupants,
                                            spectrum: [], spectrumStartHz: 0, spectrumHzPerBin: 1)
        XCTAssertGreaterThan(same, opposite)
    }

    func testAvoidsCarrierVisibleOnlyInSpectrum() {
        // A dead carrier at 1400–1600 Hz that never decodes
        var spectrum = [Float](repeating: 0, count: 280)
        for bin in 120..<140 { spectrum[bin] = 0.8 }
        let picked = TXOffsetPicker.pick(occupants: [], spectrum: spectrum,
                                         spectrumStartHz: 200, spectrumHzPerBin: 10)
        XCTAssertTrue(picked + 60 <= 1400 || picked - 10 >= 1600, "picked \(picked)")
    }

    func testStaleOccupantsMatterLessThanFresh() {
        let fresh = TXOffsetPicker.score(
            offset: 1500,
            occupants: [.init(frequency: 1500, sameParity: true, age: 5)],
            spectrum: [], spectrumStartHz: 0, spectrumHzPerBin: 1)
        let stale = TXOffsetPicker.score(
            offset: 1500,
            occupants: [.init(frequency: 1500, sameParity: true, age: 170)],
            spectrum: [], spectrumStartHz: 0, spectrumHzPerBin: 1)
        XCTAssertGreaterThan(fresh, stale * 2)
    }
}
