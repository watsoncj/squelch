import XCTest
@testable import Squelch

/// The JS8 modem: LDPC(174,87) + CRC-12, JS8 Costas patterns, no Gray map.
/// Pinned against the tone vectors JS8Call-improved publishes in its API
/// documentation (TX.FRAME examples), so bit order, parity placement and
/// the CRC quirk are all checked against the reference implementation.
final class JS8CodecTests: XCTestCase {
    static let heartbeatTones: [UInt8] = [4,2,5,6,1,3,0,7,1,5,7,6,0,2,2,3,7,4,2,7,6,4,5,1,7,1,7,3,6,6,4,1,0,4,1,7,4,2,5,6,1,3,0,0,2,4,2,1,1,4,1,6,3,4,4,4,6,2,0,7,0,5,6,2,3,1,0,3,7,4,6,4,4,2,5,6,1,3,0]
    static let message1Tones: [UInt8] = [4,2,5,6,1,3,0,1,0,2,6,6,3,1,6,6,4,0,1,7,0,7,2,6,2,6,0,4,3,4,5,2,3,5,2,0,4,2,5,6,1,3,0,3,4,2,5,4,5,7,0,1,6,3,6,7,0,2,3,5,6,4,5,7,4,0,0,1,7,3,6,4,4,2,5,6,1,3,0]
    static let message2Tones: [UInt8] = [4,2,5,6,1,3,0,2,3,7,1,3,7,7,5,2,2,4,1,1,2,2,1,1,5,3,5,4,0,7,0,5,2,1,6,5,4,2,5,6,1,3,0,7,1,6,4,4,3,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,2,6,7,1,2,4,2,5,6,1,3,0]

    func testPublishedToneVectorsDecodeAndReencode() throws {
        for (name, tones) in [("heartbeat", Self.heartbeatTones), ("msg1", Self.message1Tones), ("msg2", Self.message2Tones)] {
            let frame = try XCTUnwrap(JS8ToneCodec.frame(fromTones: tones), "\(name): parity/CRC failed")
            XCTAssertEqual(JS8ToneCodec.tones(for: frame), tones, "\(name): re-encode differs")
        }
        // Known contents: the first message frame is flagged First, the
        // second Last, and the second's tail is idle padding
        XCTAssertEqual(JS8ToneCodec.frame(fromTones: Self.message1Tones)?.type, .first)
        XCTAssertEqual(JS8ToneCodec.frame(fromTones: Self.message2Tones)?.type, .last)
        XCTAssertEqual(JS8ToneCodec.frame(fromTones: Self.heartbeatTones)?.hexString, "0a2261ce4990e2e4c8")
    }

    func testCorruptedTonesAreRejected() {
        var tones = Self.heartbeatTones
        tones[20] ^= 1
        XCTAssertNil(JS8ToneCodec.frame(fromTones: tones), "a single flipped bit must fail the parity checks")
    }

    func testSyncPatternsPerSpeed() {
        let frame = JS8Frame(bits: 0x123456789abcdef, type: [])
        let normal = JS8ToneCodec.tones(for: frame, mode: .js8)
        XCTAssertEqual(Array(normal[0..<7]), [4,2,5,6,1,3,0])
        XCTAssertEqual(Array(normal[36..<43]), [4,2,5,6,1,3,0])
        XCTAssertEqual(Array(normal[72..<79]), [4,2,5,6,1,3,0])
        for speed in [DigiMode.js8Fast, .js8Turbo, .js8Slow, .js8Ultra] {
            let t = JS8ToneCodec.tones(for: frame, mode: speed)
            XCTAssertEqual(Array(t[0..<7]), [0,6,2,3,5,4,1], "\(speed)")
            XCTAssertEqual(Array(t[36..<43]), [1,5,0,2,3,6,4], "\(speed)")
            XCTAssertEqual(Array(t[72..<79]), [2,5,0,6,4,1,3], "\(speed)")
            // Data symbols are identical across speeds — only sync differs
            XCTAssertEqual(Array(t[7..<36]), Array(normal[7..<36]))
        }
    }

    /// Audio round trip through the real monitor/decoder on every speed.
    func testAudioLoopbackAllSpeeds() throws {
        for speed in DigiMode.js8Speeds {
            let decoder = try XCTUnwrap(FT8Decoder(mode: speed))
            let frame = JS8Frame(payload: [0x71, 0x59, 0x78, 0x39, 0xee, 0x13, 0xba, 0x5f, 0x00], type: .first)
            var samples = try XCTUnwrap(FT8Encoder.encode(frame: frame, frequencyHz: 1200, mode: speed))
            XCTAssertEqual(Double(samples.count) / Double(FT8Decoder.sampleRate),
                           speed.startDelaySeconds + speed.transmissionSeconds, accuracy: 0.01, "\(speed)")
            let slot = Int(speed.slotSeconds * Double(FT8Decoder.sampleRate))
            samples.append(contentsOf: [Float](repeating: 0, count: slot - samples.count))
            let results = decoder.decodeSlot(samples)
            XCTAssertEqual(results.count, 1, "\(speed): expected one decode")
            XCTAssertEqual(results.first?.js8, frame, "\(speed)")
            XCTAssertEqual(results.first?.freqHz ?? 0, 1200, accuracy: Float(speed.toneSpanHz / 8), "\(speed)")
        }
    }

    func testFT8DecoderIgnoresJS8() throws {
        let decoder = try XCTUnwrap(FT8Decoder(mode: .ft8))
        let frame = JS8Frame(bits: 0xdeadbeef, type: [])
        var samples = try XCTUnwrap(FT8Encoder.encode(frame: frame, frequencyHz: 1500, mode: .js8))
        samples.append(contentsOf: [Float](repeating: 0, count: 15 * FT8Decoder.sampleRate - samples.count))
        XCTAssertEqual(decoder.decodeSlot(samples).count, 0)
    }

    /// JS8Call's own decoder fixtures (media/tests in its repository —
    /// recordings, not code). Not vendored: fetch them with
    /// Scripts/fetch_js8_fixtures.sh and point JS8_FIXTURES at the
    /// directory. The file names encode {mode}_{depth}_{expected decodes}.
    func testJS8CallFixtureRecordings() throws {
        guard let dir = ProcessInfo.processInfo.environment["JS8_FIXTURES"] else {
            throw XCTSkip("set JS8_FIXTURES=<dir of JS8Call media/tests wavs> (see Scripts/fetch_js8_fixtures.sh)")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".wav") }.sorted()
        XCTAssertFalse(files.isEmpty)
        var got = 0, expected = 0
        for file in files {
            let parts = file.dropLast(4).split(separator: "_")
            guard parts.count == 3, let want = Int(parts[2]) else { continue }
            let mode: DigiMode = parts[0] == "E" ? .js8Slow : .js8
            let samples = try Self.loadWav(URL(fileURLWithPath: dir).appendingPathComponent(file))
            let decoder = try XCTUnwrap(FT8Decoder(mode: mode))
            let results = decoder.decodeSlot(samples)
            got += results.count
            expected += want
            print("JS8 fixture \(file): \(results.count)/\(want)")
            // The single-signal recordings must decode fully
            if want == 1 {
                XCTAssertEqual(results.count, 1, file)
            }
        }
        // Single-pass decoding (no subtraction) trails JS8Call's deep
        // decoder on the crowded clips; hold the floor we measured
        XCTAssertGreaterThanOrEqual(got, expected * 2 / 3, "decoded \(got) of \(expected)")
    }

    /// Recordings → frames → assembled messages, with the full word table
    /// (JS8_DICTIONARY). Every message must name a plausible sender.
    func testJS8CallFixtureRecordingsAssemble() throws {
        guard let dir = ProcessInfo.processInfo.environment["JS8_FIXTURES"],
              let dictPath = ProcessInfo.processInfo.environment["JS8_DICTIONARY"] else {
            throw XCTSkip("needs JS8_FIXTURES and JS8_DICTIONARY")
        }
        let dict = try JS8Dictionary.load(from: URL(fileURLWithPath: dictPath))
        var assembled: [JS8Message] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: dir).filter({ $0.hasSuffix(".wav") }).sorted() {
            let mode: DigiMode = file.hasPrefix("E_") ? .js8Slow : .js8
            let samples = try Self.loadWav(URL(fileURLWithPath: dir).appendingPathComponent(file))
            let decoder = try XCTUnwrap(FT8Decoder(mode: mode))
            let rx = JS8Receiver(dictionary: dict)
            let slot = Date(timeIntervalSince1970: 0)
            let inputs = decoder.decodeSlot(samples).compactMap { r -> JS8Receiver.Input? in
                guard let f = r.js8 else { return nil }
                return JS8Receiver.Input(frame: f, offsetHz: r.freqHz, snr: r.snr, timestamp: slot, speed: mode)
            }
            // Each clip is one slot; whatever a lone first frame started
            // is flushed by the idle timeout so it can be inspected too
            let messages = rx.ingest(inputs) + rx.ingest([], now: slot.addingTimeInterval(61))
            for m in messages { print("JS8 \(file): \(m.displayText)") }
            assembled += messages
        }
        XCTAssertGreaterThanOrEqual(assembled.count, 15)
        for m in assembled where m.kind != .freeText {
            XCTAssertTrue(JS8Fields.isValidCallsign(m.from), "sender \(m.from) in \(m.displayText)")
            XCTAssertTrue(JS8Fields.isValidCallsign(m.to), "addressee \(m.to) in \(m.displayText)")
        }
    }

    private static func loadWav(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let body = data.dropFirst(44)
        return body.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
    }
}
