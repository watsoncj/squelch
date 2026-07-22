import XCTest
@testable import Squelch

final class WSPRTests: XCTestCase {
    /// Full round trip through the Swift wrappers and the vendored decoder.
    func testEncodeDecodeLoopback() throws {
        var audio = try XCTUnwrap(
            WSPREncoder.encode(call: "W0CJW", grid4: "DM79", dbm: 37, frequencyHz: 1507.3),
            "encode failed"
        )
        XCTAssertEqual(Double(audio.count) / 12000.0, 111.6, accuracy: 0.5)

        // Pad to a full 2-minute slot's worth of capture
        audio.append(contentsOf: [Float](repeating: 0, count: 119 * FT8Decoder.sampleRate - audio.count))

        let spots = WSPRDecoderEngine.decodeSlot(audio, rcall: "W0CJW", rgrid: "DM79", dialHz: 28_124_600)
        XCTAssertEqual(spots.count, 1)
        let spot = try XCTUnwrap(spots.first)
        XCTAssertEqual(spot.call, "W0CJW")
        XCTAssertEqual(spot.grid, "DM79")
        XCTAssertEqual(spot.powerDBm, 37)
        // Absolute RF frequency: dial + audio offset
        XCTAssertEqual(spot.frequencyHz, 28_124_600 + 1507.3, accuracy: 3)
    }

    func testShortCallAndDifferentGrid() throws {
        var audio = try XCTUnwrap(
            WSPREncoder.encode(call: "K1AB", grid4: "FN42", dbm: 30, frequencyHz: 1450)
        )
        audio.append(contentsOf: [Float](repeating: 0, count: 119 * FT8Decoder.sampleRate - audio.count))
        let spots = WSPRDecoderEngine.decodeSlot(audio, rcall: "W0CJW", rgrid: "DM79", dialHz: 28_124_600)
        XCTAssertEqual(spots.first?.call, "K1AB")
        XCTAssertEqual(spots.first?.grid, "FN42")
        XCTAssertEqual(spots.first?.powerDBm, 30)
    }

    /// Regression: wsprd's stack frames (hashtab/loctab, subtraction
    /// buffers) overflowed the 512 KB dispatch-queue stack in live use —
    /// the CLI harness passed only because main threads get 8 MB.
    func testDecodeOnDispatchQueueStack() throws {
        var audio = try XCTUnwrap(
            WSPREncoder.encode(call: "W0CJW", grid4: "DM79", dbm: 37, frequencyHz: 1500)
        )
        audio.append(contentsOf: [Float](repeating: 0, count: 119 * FT8Decoder.sampleRate - audio.count))

        let expectation = expectation(description: "decode on worker stack")
        var spots: [WSPRSpot] = []
        DispatchQueue(label: "test.wspr.decode", qos: .userInitiated).async {
            spots = WSPRDecoderEngine.decodeSlot(audio, rcall: "W0CJW", rgrid: "DM79", dialHz: 28_124_600)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 20)
        XCTAssertEqual(spots.first?.call, "W0CJW")
    }

    func testEncodeRejectsInvalidInput() {
        XCTAssertNil(WSPREncoder.encode(call: "NODIGITS", grid4: "DM79", dbm: 37, frequencyHz: 1500))
        XCTAssertNil(WSPREncoder.encode(call: "W0CJW", grid4: "ZZ99", dbm: 37, frequencyHz: 1500))
    }

    /// The synthesized log row parses like any other message: sender + grid.
    func testSpotRowParsesForMapAndLog() {
        let parsed = FT8MessageParser.parse("WSPR K1ABC EN52 37dBm")
        XCTAssertEqual(parsed.sender, "K1ABC")
        XCTAssertEqual(parsed.grid, "EN52")
        XCTAssertFalse(parsed.isCQ)
        XCTAssertNil(parsed.addressee) // "WSPR" is not a callsign
    }

    /// The synthetic TX row must stay display-only: no sender, no grid,
    /// no addressee — it can't become a station or map cell.
    func testBeaconTXRowIsInert() {
        let parsed = FT8MessageParser.parse("TX WSPR W0CJW DM79 37dBm")
        XCTAssertNil(parsed.sender)
        XCTAssertNil(parsed.grid)
        XCTAssertNil(parsed.addressee)
        XCTAssertFalse(parsed.isCQ)
    }

    func testWSPRModeProperties() {
        XCTAssertEqual(DigiMode.wspr.slotSeconds, 120)
        XCTAssertFalse(DigiMode.wspr.supportsQSO)
        XCTAssertTrue(DigiMode.ft8.supportsQSO)
    }
}

final class WSPRCodecTests: XCTestCase {
    func testPackUnpackRoundTrip() {
        for (call, grid, dbm) in [("W0CJW", "DM79", 37), ("K1AB", "FN42", 30),
                                  ("G4JNT", "IO90", 23), ("VE6CV", "DO31", 40)] {
            let n = WSPRCodec.packCallsign(call)
            XCTAssertNotNil(n, call)
            XCTAssertEqual(WSPRCodec.unpackCallsign(n!), call)
            let m = WSPRCodec.packGridPower(grid: grid, dBm: dbm)
            XCTAssertNotNil(m, grid)
            let gp = WSPRCodec.unpackGridPower(m!)
            XCTAssertEqual(gp?.grid, grid)
            XCTAssertEqual(gp?.dBm, dbm)
        }
    }

    func testSpecInvariants() {
        XCTAssertEqual(WSPRCodec.syncVector.count, 162)
        XCTAssertEqual(WSPRCodec.syncVector.reduce(0) { $0 + Int($1) }, 63) // checksum of the spec constant
        XCTAssertEqual(WSPRCodec.interleaveMap.count, 162)
        XCTAssertEqual(Set(WSPRCodec.interleaveMap).count, 162) // permutation
        let bits = WSPRCodec.messageBits(call: "W0CJW", grid: "DM79", dBm: 37)
        XCTAssertEqual(bits?.count, 50)
        XCTAssertEqual(WSPRCodec.convolve(bits!).count, 162)
    }

    func testRejectsInvalidInput() {
        XCTAssertNil(WSPRCodec.packCallsign("NODIGITS"))
        XCTAssertNil(WSPRCodec.packGridPower(grid: "ZZ99", dBm: 37)) // Z > R
        XCTAssertNil(WSPRCodec.packGridPower(grid: "DM79", dBm: 61))
    }

    /// THE clean-room gate: audio synthesized purely from the public spec
    /// must decode in the independently-implemented (vendored) decoder.
    /// Any packing/polynomial/interleave/sync mistake fails this.
    func testCleanRoomEncoderAgainstOracle() throws {
        var audio = try XCTUnwrap(
            WSPRCodec.audio(call: "W0CJW", grid: "DM79", dBm: 37, offsetHz: 1507.3)
        )
        audio.append(contentsOf: [Float](repeating: 0, count: 119 * 12000 - audio.count))
        let spots = WSPRDecoderEngine.decodeSlot(audio, rcall: "W0CJW", rgrid: "DM79", dialHz: 28_124_600)
        XCTAssertEqual(spots.count, 1, "oracle decoder found no signal — codec conventions wrong")
        XCTAssertEqual(spots.first?.call, "W0CJW")
        XCTAssertEqual(spots.first?.grid, "DM79")
        XCTAssertEqual(spots.first?.powerDBm, 37)
        XCTAssertEqual(spots.first.map { Double($0.frequencyHz) } ?? 0, 28_124_600 + 1507.3, accuracy: 3)
    }
}

final class WSPRCleanRoomDecoderTests: XCTestCase {
    private func slotAudio(call: String, grid: String, dBm: Int, offsetHz: Double,
                           noiseRMS: Float = 0) -> [Float] {
        var audio = WSPRCodec.audio(call: call, grid: grid, dBm: dBm, offsetHz: offsetHz)!
        audio.append(contentsOf: [Float](repeating: 0, count: 119 * 12000 - audio.count))
        if noiseRMS > 0 {
            var seed: UInt64 = 0x5eed_50f7
            func rand() -> Float {
                // xorshift → uniform → approx gaussian via sum of 4
                var s: Float = 0
                for _ in 0..<4 {
                    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                    s += Float(seed % 100000) / 100000.0 - 0.5
                }
                return s // variance ≈ 4/12 → rms ≈ 0.577
            }
            for i in 0..<audio.count {
                audio[i] += rand() * noiseRMS * 1.732
            }
        }
        return audio
    }

    func testCleanDecode() throws {
        let results = WSPRDecoder.decode(slotAudio(call: "W0CJW", grid: "DM79", dBm: 37, offsetHz: 1507.3))
        XCTAssertEqual(results.count, 1)
        let r = try XCTUnwrap(results.first)
        XCTAssertEqual(r.call, "W0CJW")
        XCTAssertEqual(r.grid, "DM79")
        XCTAssertEqual(r.dBm, 37)
        XCTAssertEqual(r.audioFrequencyHz, 1507.3, accuracy: 2.0)
    }

    func testDecodeAtBandEdgesAndOtherMessages() throws {
        for (call, grid, dbm, freq) in [("K1AB", "FN42", 30, 1420.0),
                                        ("G4JNT", "IO90", 23, 1580.0),
                                        ("VE6CV", "DO31", 40, 1500.0)] {
            let results = WSPRDecoder.decode(slotAudio(call: call, grid: grid, dBm: dbm, offsetHz: freq))
            XCTAssertEqual(results.first?.call, call, "at \(freq)")
            XCTAssertEqual(results.first?.grid, grid)
            XCTAssertEqual(results.first?.dBm, dbm)
        }
    }

    func testDecodeInNoise() throws {
        // Signal amplitude 0.5 (encoder), noise rms 1.0 → SNR in 2500 Hz
        // ≈ 10·log10((0.125)/(1.0² · 2500/6000)) ≈ -5 dB… iterate levels
        // downward and require decodes through a solidly negative SNR.
        for noise in [Float(1.0), 2.0, 4.0] {
            let results = WSPRDecoder.decode(
                slotAudio(call: "W0CJW", grid: "DM79", dBm: 37, offsetHz: 1492.0, noiseRMS: noise))
            XCTAssertEqual(results.first?.call, "W0CJW", "failed at noise rms \(noise)")
            XCTAssertEqual(results.first?.grid, "DM79")
        }
    }

    func testNoFalseDecodesOnNoise() {
        var noise = [Float](repeating: 0, count: 119 * 12000)
        var seed: UInt64 = 0xDEAD_BEEF
        for i in 0..<noise.count {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            noise[i] = Float(seed % 100000) / 100000.0 - 0.5
        }
        XCTAssertEqual(WSPRDecoder.decode(noise).count, 0)
    }

    func testTwoSimultaneousSignals() throws {
        var a = slotAudio(call: "W0CJW", grid: "DM79", dBm: 37, offsetHz: 1460)
        let b = slotAudio(call: "K1AB", grid: "FN42", dBm: 30, offsetHz: 1540)
        for i in 0..<a.count { a[i] += b[i] }
        let calls = Set(WSPRDecoder.decode(a).map(\.call))
        XCTAssertTrue(calls.contains("W0CJW"), "decoded: \(calls)")
        XCTAssertTrue(calls.contains("K1AB"), "decoded: \(calls)")
    }
}
