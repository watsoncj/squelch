import XCTest
@testable import RadioFun

final class WaterfallTests: XCTestCase {
    func testFrequencyMapping() {
        XCTAssertEqual(WaterfallProcessor.frequency(forX: 0, width: 1000), 200)
        XCTAssertEqual(WaterfallProcessor.frequency(forX: 1000, width: 1000), 3000)
        XCTAssertEqual(WaterfallProcessor.frequency(forX: 500, width: 1000), 1600)
        // Out-of-bounds clamps
        XCTAssertEqual(WaterfallProcessor.frequency(forX: -50, width: 1000), 200)
        XCTAssertEqual(WaterfallProcessor.frequency(forX: 2000, width: 1000), 3000)

        // Round trip
        let x = WaterfallProcessor.x(forFrequency: 1500, width: 1000)
        XCTAssertEqual(WaterfallProcessor.frequency(forX: x, width: 1000), 1500, accuracy: 0.01)
    }

    func testPalette() {
        XCTAssertEqual(WaterfallProcessor.palette.count, 256)
        XCTAssertEqual(WaterfallProcessor.palette[255].0, 255) // hottest = white
        XCTAssertLessThan(WaterfallProcessor.palette[0].2, 64) // coldest = dark
    }

    /// End-to-end DSP: a 1500 Hz tone must light up the right column.
    func testToneProducesBrightColumnAtItsFrequency() throws {
        let processor = WaterfallProcessor()
        let rate = Double(FT8Decoder.sampleRate)
        let omega = 2.0 * Double.pi * 1500.0 / rate
        let tone = (0..<(3 * FT8Decoder.sampleRate)).map { i in
            Float(sin(omega * Double(i))) * 0.3
        }
        processor.ingest(tone)

        let deadline = Date().addingTimeInterval(3)
        while processor.image == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let image = try XCTUnwrap(processor.image, "waterfall image never appeared")

        // Find the brightest column
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let width = image.width, height = image.height
        var best = (column: -1, energy: 0)
        for x in 0..<width {
            var energy = 0
            for y in 0..<height {
                let p = (y * width + x) * 4
                energy += Int(data[p]) + Int(data[p + 1]) + Int(data[p + 2])
            }
            if energy > best.energy { best = (x, energy) }
        }

        let expectedX = WaterfallProcessor.x(forFrequency: 1500, width: CGFloat(width))
        XCTAssertEqual(Double(best.column), Double(expectedX), accuracy: 4,
                       "tone column off: got \(best.column), expected ~\(expectedX)")
    }
}
