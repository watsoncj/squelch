import XCTest
@testable import Squelch

/// The JS8 frame layer, pinned to bit-exact worked examples: field
/// packers, frame strings, the Huffman and JSC codings, checksums, the
/// message builder and the receive-side assembler.
final class JS8VaricodeTests: XCTestCase {
    /// Sparse word table carrying just the ranks the examples need.
    static let words = JS8Dictionary(sparse: [
        0: "E", 1: "T", 2: "A", 3: "O", 4: "I", 5: "N", 6: "S", 7: "H", 8: "R", 9: "D", 10: "L",
        33: "0", 35: "1", 38: "2", 41: "3", 42: "5", 43: "4", 44: "9", 45: "8", 46: "6", 47: "7",
        67: " ", 907: "WORLD", 6571: "HELLO", 3971: "QUICK", 600: "THIS", 200: "MSG", 121: "CQ",
    ])

    private func frame(_ s: String, _ type: JS8Frame.TransmissionType = [.first, .last]) -> JS8Frame {
        JS8Frame(frameString: s, type: type)!
    }

    // MARK: Fields

    func testCallsignPacking() {
        XCTAssertEqual(JS8Fields.packCallsign("KN4CRD").value, 146_325_342)
        XCTAssertEqual(JS8Fields.packCallsign("W0CJW").value, 261_391_963)
        let portable = JS8Fields.packCallsign("KN4CRD/P")
        XCTAssertEqual(portable.value, 146_325_342)
        XCTAssertTrue(portable.portable)
        XCTAssertEqual(JS8Fields.packCallsign("3DA0ABC").value, 23_816_459)
        XCTAssertEqual(JS8Fields.packCallsign("@ALLCALL").value, 262_177_562)
        XCTAssertEqual(JS8Fields.packCallsign("<....>").value, 262_177_561)
        XCTAssertEqual(JS8Fields.packCallsign("@HB").value, 262_177_605)
        XCTAssertEqual(JS8Fields.packCallsign("K").value, 0)

        XCTAssertEqual(JS8Fields.unpackCallsign(146_325_342, portable: false), "KN4CRD")
        XCTAssertEqual(JS8Fields.unpackCallsign(146_325_342, portable: true), "KN4CRD/P")
        XCTAssertEqual(JS8Fields.unpackCallsign(261_391_963, portable: false), "W0CJW")
        XCTAssertEqual(JS8Fields.unpackCallsign(23_816_459, portable: false), "3DA0ABC")
        XCTAssertEqual(JS8Fields.unpackCallsign(262_177_605, portable: false), "@HB")
    }

    func testCallsignValidity() {
        XCTAssertTrue(JS8Fields.isStandardCallsign("W0CJW"))
        XCTAssertTrue(JS8Fields.isStandardCallsign("KN4CRD/P"))
        XCTAssertTrue(JS8Fields.isStandardCallsign("@ALLCALL"))
        XCTAssertFalse(JS8Fields.isStandardCallsign("KN4CRD/QRP"))
        XCTAssertTrue(JS8Fields.isCompoundCallsign("KN4CRD/QRP"))
        XCTAssertTrue(JS8Fields.isCompoundCallsign("VE3/LB9YHX"))
        XCTAssertTrue(JS8Fields.isCompoundCallsign("@FOO"))
        XCTAssertFalse(JS8Fields.isCompoundCallsign("@HB"))
        XCTAssertFalse(JS8Fields.isValidCallsign("HELLO"))
        XCTAssertTrue(JS8Fields.isGroupAllowed("@RACES"))
        XCTAssertFalse(JS8Fields.isGroupAllowed("@APRSIS"))
    }

    func testAlphaNumeric50() {
        XCTAssertEqual(JS8Fields.packAlphaNumeric50("KN4CRD"), 358_399_795_381_724)
        XCTAssertEqual(JS8Fields.packAlphaNumeric50("KN4CRD/P"), 358_399_795_420_712)
        XCTAssertEqual(JS8Fields.packAlphaNumeric50("VE3/LB9YHX"), 545_579_025_695_551)
        for call in ["KN4CRD", "KN4CRD/P", "VE3/LB9YHX", "@RACES", "W0CJW"] {
            XCTAssertEqual(JS8Fields.unpackAlphaNumeric50(JS8Fields.packAlphaNumeric50(call)), call)
        }
    }

    func testGrid() {
        XCTAssertEqual(JS8Fields.packGrid("EM73"), 23_883)
        XCTAssertEqual(JS8Fields.packGrid("DM79"), 25_689)
        XCTAssertEqual(JS8Fields.packGrid("JO22"), 15_802)
        XCTAssertEqual(JS8Fields.packGrid("AA00"), 32_220)
        XCTAssertEqual(JS8Fields.packGrid("RR99"), 179)
        XCTAssertEqual(JS8Fields.packGrid("EM"), 32_767)
        for g in ["EM73", "DM79", "JO22", "AA00", "RR99", "FN42", "PM74"] {
            XCTAssertEqual(JS8Fields.unpackGrid(JS8Fields.packGrid(g)), g)
        }
        XCTAssertEqual(JS8Fields.unpackGrid(32_767), "")
    }

    func testNumbersAndSNR() {
        XCTAssertEqual(JS8Fields.packNum(""), 0)
        XCTAssertEqual(JS8Fields.packNum("-5"), 26)
        XCTAssertEqual(JS8Fields.packNum("+10"), 41)
        XCTAssertEqual(JS8Fields.packNum("99"), 62)
        XCTAssertEqual(JS8Fields.formatSNR(-5), "-05")
        XCTAssertEqual(JS8Fields.formatSNR(0), "+00")
        XCTAssertEqual(JS8Fields.formatSNR(10), "+10")
        XCTAssertEqual(JS8Fields.formatSNR(-30), "-30")
        XCTAssertEqual(JS8Fields.formatSNR(61), "")
    }

    func testChecksums() {
        XCTAssertEqual(JS8Checksum.crc16(Array("123456789".utf8)), 0x2189)
        XCTAssertEqual(JS8Checksum.crc32(Array("123456789".utf8)), 0xFC89_1918)
        XCTAssertEqual(JS8Checksum.checksum16("HELLO WORLD"), "5GA")
        XCTAssertEqual(JS8Checksum.checksum16("HELLO"), "387")
        XCTAssertEqual(JS8Checksum.checksum16("123456789"), "54G")
        XCTAssertEqual(JS8Checksum.checksum32("123456789"), ".IX3XS")
        XCTAssertEqual(JS8Checksum.checksum32("HELLO WORLD"), "M?TO9W")
        XCTAssertEqual(JS8Checksum.checksum32("HELLO"), "HM17Q+")
        XCTAssertEqual(JS8Checksum.unpack16("???"), 0)
    }

    func testCommandTable() {
        XCTAssertEqual(JS8Command.byString(" SNR?")?.code, 0)
        XCTAssertEqual(JS8Command.byString("?")?.code, 0)
        XCTAssertEqual(JS8Command.byString(">")?.code, 5)
        XCTAssertEqual(JS8Command.byString(" QUERY MSGS?")?.canonical, " QUERY MSGS")
        XCTAssertEqual(JS8Command.byCode(31)?.canonical, " ")
        XCTAssertTrue(JS8Command.isBuffered(" MSG"))
        XCTAssertTrue(JS8Command.isBuffered(" SNR?"), "every spaced command buffers")
        XCTAssertFalse(JS8Command.isBuffered("?"))
        XCTAssertEqual(JS8Command.checksumWidth(" MSG"), 16)
        XCTAssertEqual(JS8Command.checksumWidth(" GRID"), 0)
        XCTAssertTrue(JS8Command.isAutoReply(" HEARING?"))
        XCTAssertTrue(JS8Command.isSNRCommand(" HEARTBEAT SNR"))
    }

    // MARK: Frame strings

    func testFrameStringRoundTrip() {
        let f = frame("2Y-pe-ukukfO")
        XCTAssertEqual(f.frameString, "2Y-pe-ukukfO")
        XCTAssertNil(JS8Frame(frameString: "2Y-pe-ukuk", type: []))
        XCTAssertNil(JS8Frame(frameString: "2Y-pe-ukukf*", type: []))
    }

    func testHeartbeatAndCQFrames() {
        XCTAssertEqual(JS8FrameCodec.heartbeat(call: "KN4CRD", grid: "EM73", isCQ: false, variant: 0),
                       frame("2Y-pe-ukukfO").payload)
        XCTAssertEqual(JS8FrameCodec.heartbeat(call: "KN4CRD", grid: "EM73", isCQ: true, variant: 0),
                       frame("2Y-pe-ukvkfO").payload)
        XCTAssertEqual(JS8FrameCodec.heartbeat(call: "KN4CRD", grid: "EM73", isCQ: true, variant: 1),
                       frame("2Y-pe-ukvkfP").payload)

        let hb = JS8FrameCodec.decode(frame("2Y-pe-ukukfO"), dictionary: nil)
        XCTAssertEqual(hb, .heartbeat(call: "KN4CRD", grid: "EM73", isCQ: false, variant: 0))
        XCTAssertEqual(hb?.displayText, "KN4CRD: @HB HEARTBEAT EM73 ")
        let cq = JS8FrameCodec.decode(frame("2Y-pe-ukvkfP"), dictionary: nil)
        XCTAssertEqual(cq?.displayText, "KN4CRD: @ALLCALL CQ DX EM73 ")
    }

    func testDirectedFrames() {
        XCTAssertEqual(JS8FrameCodec.directed(from: "KN4CRD", to: "W0CJW", cmdCode: 0, num: 0), frame("SN5-lVAGos00").payload)
        XCTAssertEqual(JS8FrameCodec.directed(from: "KN4CRD", to: "W0CJW", cmdCode: 25, num: 26), frame("SN5-lVAGotaQ").payload)
        XCTAssertEqual(JS8FrameCodec.directed(from: "W0CJW", to: "KN4CRD", cmdCode: 29, num: 41), frame("VoaCjnSNwzqf").payload)
        XCTAssertEqual(JS8FrameCodec.directed(from: "KN4CRD", to: "W0CJW", cmdCode: 9, num: 0), frame("SN5-lVAGosa0").payload)

        XCTAssertEqual(JS8FrameCodec.decode(frame("SN5-lVAGos00"), dictionary: nil),
                       .directed(from: "KN4CRD", to: "W0CJW", cmd: " SNR?", extra: nil))
        XCTAssertEqual(JS8FrameCodec.decode(frame("SN5-lVAGos00"), dictionary: nil)?.displayText, "KN4CRD: W0CJW SNR? ")
        XCTAssertEqual(JS8FrameCodec.decode(frame("SN5-lVAGotaQ"), dictionary: nil)?.displayText, "KN4CRD: W0CJW SNR -05 ")
        XCTAssertEqual(JS8FrameCodec.decode(frame("VoaCjnSNwzqf"), dictionary: nil)?.displayText, "W0CJW: KN4CRD HEARTBEAT SNR +10 ")
    }

    func testCompoundFrames() {
        XCTAssertEqual(JS8FrameCodec.compound(call: "KN4CRD/P", grid: "EM73"), frame("AY-pe+BnGkfO").payload)
        XCTAssertEqual(JS8FrameCodec.compoundDirected(call: "W0CJW", cmdCode: 0, num: 0), frame("Jz95VAOyO+JG").payload)
        XCTAssertEqual(JS8FrameCodec.compoundDirected(call: "W0CJW", cmdCode: 25, num: 26), frame("Jz95VAOyO+cW").payload)

        XCTAssertEqual(JS8FrameCodec.decode(frame("AY-pe+BnGkfO"), dictionary: nil), .compound(call: "KN4CRD/P", grid: "EM73"))
        XCTAssertEqual(JS8FrameCodec.decode(frame("Jz95VAOyO+JG"), dictionary: nil), .compoundDirected(to: "W0CJW", cmd: " SNR?", extra: nil))
        XCTAssertEqual(JS8FrameCodec.decode(frame("Jz95VAOyO+cW"), dictionary: nil), .compoundDirected(to: "W0CJW", cmd: " SNR", extra: "-05"))
    }

    // MARK: Text codings

    func testHuffmanDataFrame() {
        let packed = JS8FrameCodec.dataHuffman("HELLO WORLD")
        XCTAssertEqual(packed?.payload, frame("XpFFwNy6VR++").payload)
        XCTAssertEqual(packed?.consumed, 11)
        XCTAssertEqual(JS8FrameCodec.decode(frame("XpFFwNy6VR++"), dictionary: nil), .data(text: "HELLO WORLD", compressed: false))
        XCTAssertNil(JS8FrameCodec.dataHuffman("HELLO, WORLD"), "comma is not in the Huffman table")
    }

    func testJSCCodewords() {
        func bits(_ s: String) -> [Bool] { s.filter { $0 != " " }.map { $0 == "1" } }
        XCTAssertEqual(JS8JSC.codeword(rank: 0, separator: false), bits("0000 0"))
        XCTAssertEqual(JS8JSC.codeword(rank: 6, separator: true), bits("0110 1"))
        XCTAssertEqual(JS8JSC.codeword(rank: 7, separator: false), bits("0111 0000 0"))
        XCTAssertEqual(JS8JSC.codeword(rank: 69, separator: false), bits("1111 0110 0"))
        XCTAssertEqual(JS8JSC.codeword(rank: 70, separator: false), bits("0111 0111 0000 0"))
        XCTAssertEqual(JS8JSC.codeword(rank: 637, separator: false), bits("0111 0111 0111 0000 0"))
        XCTAssertEqual(JS8JSC.codeword(rank: 6571, separator: true), bits("0111 1000 1011 1000 0101 1"))
        XCTAssertEqual(JS8JSC.decode(bits("0111 1000 1011 1000 0101 1 0111 1011 1001 0100 0"), dictionary: Self.words), "HELLO WORLD")
    }

    func testJSCDataFrames() {
        let packed = JS8FrameCodec.dataCompressed("HELLO WORLD", dictionary: Self.words)
        XCTAssertEqual(packed?.payload, frame("tYuMzoX+++++").payload)
        XCTAssertEqual(packed?.consumed, 11)
        XCTAssertEqual(JS8FrameCodec.decode(frame("tYuMzoX+++++"), dictionary: Self.words), .data(text: "HELLO WORLD", compressed: true))
        // Same bits, no header, in a fast-data frame
        let fast = JS8FrameCodec.fastData("HELLO WORLD", dictionary: Self.words)
        XCTAssertEqual(fast?.payload, frame("UBXRtA7+++++").payload)
        XCTAssertEqual(JS8FrameCodec.decode(frame("UBXRtA7+++++", [.data, .first, .last]), dictionary: Self.words),
                       .data(text: "HELLO WORLD", compressed: true))
        // Without a word table the text is unknown but the frame still classifies
        XCTAssertEqual(JS8FrameCodec.decode(frame("tYuMzoX+++++"), dictionary: nil), .data(text: nil, compressed: true))
    }

    // MARK: Builder

    func testBuildHeartbeatAndCQ() {
        let hb = JS8MessageBuilder.build(text: "KN4CRD: HEARTBEAT EM73", myCall: "KN4CRD", myGrid: "EM73", mode: .js8, dictionary: nil)
        XCTAssertEqual(hb.frames.map(\.frameString), ["2Y-pe-ukukfO"])
        XCTAssertEqual(hb.frames.first?.type, [.first, .last])
        let cq = JS8MessageBuilder.build(text: "CQ CQ CQ EM73", myCall: "KN4CRD", myGrid: "EM73", mode: .js8, dictionary: nil)
        XCTAssertEqual(cq.frames.map(\.frameString), ["2Y-pe-ukvkfO"])
        let dx = JS8MessageBuilder.build(text: "CQ DX EM73", myCall: "KN4CRD", myGrid: "EM73", mode: .js8, dictionary: nil)
        XCTAssertEqual(dx.frames.map(\.frameString), ["2Y-pe-ukvkfP"])
    }

    func testBuildDirected() {
        let snr = JS8MessageBuilder.build(text: "W0CJW SNR?", myCall: "KN4CRD", myGrid: "EM73", mode: .js8, dictionary: nil)
        XCTAssertEqual(snr.frames.map(\.frameString), ["SN5-lVAGos00"])
        XCTAssertEqual(snr.directedTo, "W0CJW")
        XCTAssertEqual(snr.directedCmd, " SNR?")
        let report = JS8MessageBuilder.build(text: "KN4CRD: W0CJW SNR -05", myCall: "KN4CRD", myGrid: "EM73", mode: .js8, dictionary: nil)
        XCTAssertEqual(report.frames.map(\.frameString), ["SN5-lVAGotaQ"])
        let ack = JS8MessageBuilder.build(text: "KN4CRD HEARTBEAT SNR +10", myCall: "W0CJW", myGrid: "DM79", mode: .js8, dictionary: nil)
        XCTAssertEqual(ack.frames.map(\.frameString), ["VoaCjnSNwzqf"])
        // Selected call is prepended when the line doesn't name a station
        let sel = JS8MessageBuilder.build(text: "SNR?", myCall: "KN4CRD", myGrid: "EM73", selectedCall: "W0CJW", mode: .js8, dictionary: nil)
        XCTAssertEqual(sel.frames.map(\.frameString), ["SN5-lVAGos00"])
    }

    func testBuildDataFrames() {
        let huff = JS8MessageBuilder.build(text: "HELLO WORLD", myCall: "KN4CRD", myGrid: "EM73", forceIdentify: false, mode: .js8, dictionary: nil)
        XCTAssertEqual(huff.frames.map(\.frameString), ["XpFFwNy6VR++"], "Huffman when no word table is installed")
        let jsc = JS8MessageBuilder.build(text: "HELLO WORLD", myCall: "KN4CRD", myGrid: "EM73", forceIdentify: false, mode: .js8, dictionary: Self.words)
        XCTAssertEqual(jsc.frames.map(\.frameString), ["tYuMzoX+++++"], "ties go to JSC")
        XCTAssertEqual(jsc.frames.first?.type, [.first, .last])
        let fast = JS8MessageBuilder.build(text: "HELLO WORLD", myCall: "KN4CRD", myGrid: "EM73", forceIdentify: false, mode: .js8Fast, dictionary: Self.words)
        XCTAssertEqual(fast.frames.map(\.frameString), ["UBXRtA7+++++"])
        XCTAssertEqual(fast.frames.first?.type, [.data, .first, .last])
    }

    func testBuildBufferedMessageWithChecksum() {
        let msg = JS8MessageBuilder.build(text: "W0CJW MSG HELLO", myCall: "KN4CRD", myGrid: "EM73", mode: .js8, dictionary: Self.words)
        XCTAssertEqual(msg.frames.map(\.frameString), ["SN5-lVAGosa0", "tYuNRCDYd+++"])
        XCTAssertEqual(msg.frames.map(\.type), [[.first], [.last]])
    }

    func testBuildCompoundSequences() {
        let compound = JS8MessageBuilder.build(text: "`KN4CRD/P EM73", myCall: "KN4CRD/P", myGrid: "EM73", mode: .js8, dictionary: nil)
        XCTAssertEqual(compound.frames.map(\.frameString), ["AY-pe+BnGkfO"])
        let cd = JS8MessageBuilder.build(text: "`W0CJW SNR?", myCall: "KN4CRD/P", myGrid: "EM73", mode: .js8, dictionary: nil)
        XCTAssertEqual(cd.frames.map(\.frameString), ["Jz95VAOyO+JG"])
        let cd2 = JS8MessageBuilder.build(text: "`W0CJW SNR -05", myCall: "KN4CRD/P", myGrid: "EM73", mode: .js8, dictionary: nil)
        XCTAssertEqual(cd2.frames.map(\.frameString), ["Jz95VAOyO+cW"])
        // A portable sender expands a directed line into compound + compound-directed
        let seq = JS8MessageBuilder.build(text: "W0CJW SNR?", myCall: "KN4CRD/P", myGrid: "EM73", mode: .js8, dictionary: nil)
        XCTAssertEqual(seq.frames.map(\.frameString), ["AY-pe+BnGkfO", "Jz95VAOyO+JG"])
        XCTAssertEqual(seq.frames.map(\.type), [[.first], [.last]])
    }

    // MARK: Receiver

    private func input(_ f: JS8Frame, offset: Float = 1500, at t: TimeInterval, speed: DigiMode = .js8) -> JS8Receiver.Input {
        JS8Receiver.Input(frame: f, offsetHz: offset, snr: -10, timestamp: Date(timeIntervalSince1970: t), speed: speed)
    }

    func testReceiverPassesHeartbeatsAndSingleCommandsThrough() {
        let rx = JS8Receiver(dictionary: Self.words)
        let out = rx.ingest([input(frame("2Y-pe-ukukfO"), offset: 800, at: 0), input(frame("SN5-lVAGotaQ"), offset: 1500, at: 0)])
        XCTAssertEqual(out.map(\.displayText), ["KN4CRD: @HB HEARTBEAT EM73 ♢ ", "KN4CRD: W0CJW SNR -05 ♢ "])
        XCTAssertEqual(out.first?.kind, .heartbeat)
        XCTAssertEqual(out.first?.grid, "EM73")
        XCTAssertEqual(out.last?.kind, .directed)
        XCTAssertEqual(out.last?.extra, "-05")
    }

    func testReceiverAssemblesBufferedMessage() {
        let rx = JS8Receiver(dictionary: Self.words)
        let first = rx.ingest([input(frame("SN5-lVAGosa0", [.first]), at: 0)])
        XCTAssertTrue(first.isEmpty, "the MSG header waits for its text")
        XCTAssertEqual(rx.pending.first?.to, "W0CJW")
        // Slight drift on the second frame still matches the buffer
        let second = rx.ingest([input(frame("tYuNRCDYd+++", [.last]), offset: 1506, at: 15)])
        XCTAssertEqual(second.map(\.displayText), ["KN4CRD: W0CJW MSG HELLO ♢ "])
        XCTAssertEqual(second.first?.text, "HELLO")
        XCTAssertTrue(rx.pending.isEmpty)
    }

    func testReceiverDeliversBadChecksumAsPartial() {
        let rx = JS8Receiver(dictionary: Self.words)
        _ = rx.ingest([input(frame("SN5-lVAGosa0", [.first]), at: 0)])
        // "HELLO WORLD" instead of "HELLO 387": the checksum doesn't
        // validate, but the text still reaches the feed as a partial
        let out = rx.ingest([input(frame("tYuMzoX+++++", [.last]), at: 15)])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.isComplete, false)
        XCTAssertEqual(out.first?.displayText, "KN4CRD: W0CJW MSG HELLO WORLD")
    }

    func testReceiverSalvagesExpiredPartials() {
        // A directed header whose text never finishes: expiry delivers
        // "FROM: TO CMD <text> ……" instead of discarding it
        let rx = JS8Receiver(dictionary: Self.words)
        _ = rx.ingest([input(frame("SN5-lVAGosa0", [.first]), at: 0)])
        _ = rx.ingest([input(frame("tYuMzoX+++++", []), at: 15)]) // no Last
        // 61 s: the idle rule tries completion, the checksum fails → partial
        let out = rx.ingest([], now: Date(timeIntervalSince1970: 15 + 61))
        XCTAssertEqual(out.map(\.displayText), ["KN4CRD: W0CJW MSG HELLO WORLD"])
        XCTAssertEqual(out.first?.isComplete, false)
        XCTAssertTrue(rx.pending.isEmpty)

        // Anonymous free text that never completes: kept, tail marked
        let rx2 = JS8Receiver(dictionary: Self.words)
        let f1 = JS8Frame(payload: JS8FrameCodec.dataCompressed("HELLO ", dictionary: Self.words)!.payload, type: [.first])
        _ = rx2.ingest([input(f1, at: 0)])
        let out2 = rx2.ingest([], now: Date(timeIntervalSince1970: 91))
        XCTAssertEqual(out2.map(\.displayText), ["HELLO \(JS8Receiver.missingFrameMarker)"])
        XCTAssertEqual(out2.first?.isComplete, false)
    }

    func testReceiverResolvesCompoundPlaceholder() {
        let rx = JS8Receiver(dictionary: Self.words)
        _ = rx.ingest([input(frame("AY-pe+BnGkfO", [.first]), at: 0)])
        let out = rx.ingest([input(frame("Jz95VAOyO+JG", [.last]), at: 15)])
        XCTAssertEqual(out.map(\.displayText), ["KN4CRD/P: W0CJW SNR? ♢ "])
        XCTAssertEqual(out.first?.grid, "EM73")
    }

    func testReceiverJoinsFreeTextAcrossFrames() {
        let rx = JS8Receiver(dictionary: Self.words)
        // Two hand-split frames of one free-text transmission
        let f1 = JS8Frame(payload: JS8FrameCodec.dataCompressed("HELLO ", dictionary: Self.words)!.payload, type: [.first])
        let f2 = JS8Frame(payload: JS8FrameCodec.dataCompressed("WORLD", dictionary: Self.words)!.payload, type: [.last])
        XCTAssertTrue(rx.ingest([input(f1, at: 0)]).isEmpty)
        XCTAssertEqual(rx.pending.first?.textSoFar, "HELLO ")
        let out = rx.ingest([input(f2, at: 15)])
        XCTAssertEqual(out.map(\.displayText), ["HELLO WORLD ♢ "])
        XCTAssertEqual(out.first?.kind, .freeText)
    }

    func testReceiverTimesOutStaleBuffer() {
        let rx = JS8Receiver(dictionary: Self.words)
        _ = rx.ingest([input(frame("SN5-lVAGosa0", [.first]), at: 0)])
        _ = rx.ingest([input(frame("tYuNRCDYd+++", []), at: 15)]) // text arrived without Last
        XCTAssertTrue(rx.ingest([], now: Date(timeIntervalSince1970: 30)).isEmpty)
        let out = rx.ingest([], now: Date(timeIntervalSince1970: 15 + 61))
        XCTAssertEqual(out.map(\.displayText), ["KN4CRD: W0CJW MSG HELLO ♢ "], "60 s idle closes the message")
    }

    func testReceiverMarksMissingFrames() {
        let rx = JS8Receiver(dictionary: Self.words)
        // Free text that loses its middle frame: "HELLO " ... (lost) ... "WORLD"
        let f1 = JS8Frame(payload: JS8FrameCodec.dataCompressed("HELLO ", dictionary: Self.words)!.payload, type: [.first])
        let f3 = JS8Frame(payload: JS8FrameCodec.dataCompressed("WORLD", dictionary: Self.words)!.payload, type: [.last])
        XCTAssertTrue(rx.ingest([input(f1, at: 0)]).isEmpty)
        // Two idle slots pass — the gap gets its marker
        XCTAssertTrue(rx.ingest([], now: Date(timeIntervalSince1970: 40)).isEmpty)
        let out = rx.ingest([input(f3, at: 45)])
        XCTAssertEqual(out.map(\.displayText), ["HELLO \(JS8Receiver.missingFrameMarker)WORLD ♢ "])
    }

    func testReceiverDeduplicatesRepeatedFrame() {
        let rx = JS8Receiver(dictionary: Self.words)
        let out = rx.ingest([input(frame("SN5-lVAGotaQ"), offset: 1500, at: 0), input(frame("SN5-lVAGotaQ"), offset: 1500.5, at: 0)])
        XCTAssertEqual(out.count, 1)
    }

    // MARK: On-air frames

    /// Frames JS8Call-improved published in its API docs (TX.FRAME tones)
    /// and the payloads decoded from them (JS8CodecTests).
    func testPublishedOnAirFramesClassify() throws {
        let hb = JS8Frame(payload: [0x0a, 0x22, 0x61, 0xce, 0x49, 0x90, 0xe2, 0xe4, 0xc8], type: [.first, .last])
        guard case .heartbeat(let call, let grid, let isCQ, _)? = JS8FrameCodec.decode(hb, dictionary: nil) else {
            return XCTFail("expected a heartbeat")
        }
        XCTAssertTrue(JS8Fields.isValidCallsign(call), call)
        XCTAssertEqual(grid?.count, 4)
        XCTAssertFalse(isCQ)
        let msg1 = JS8Frame(payload: [0x71, 0x59, 0x78, 0x39, 0xee, 0x13, 0xba, 0x5f, 0x00], type: [.first])
        guard case .directed(let from, let to, let cmd, _)? = JS8FrameCodec.decode(msg1, dictionary: nil) else {
            return XCTFail("expected a directed frame")
        }
        XCTAssertTrue(JS8Fields.isValidCallsign(from), from)
        XCTAssertTrue(JS8Fields.isValidCallsign(to), to)
        XCTAssertEqual(cmd, " ", "a plain 'CALL text' line is the free-text command")
    }

    // MARK: Full word table (needs JS8_DICTIONARY=<path to JSC_map.cpp or js8-words.txt>)

    private func fullDictionary() throws -> JS8Dictionary {
        guard let path = ProcessInfo.processInfo.environment["JS8_DICTIONARY"] else {
            throw XCTSkip("set JS8_DICTIONARY to a JSC_map.cpp (see Scripts/fetch_js8_dictionary.sh)")
        }
        return try JS8Dictionary.load(from: URL(fileURLWithPath: path))
    }

    func testFullDictionaryParsesAndRoundTrips() throws {
        let dict = try fullDictionary()
        XCTAssertTrue(dict.isComplete)
        XCTAssertEqual(dict.word(at: 0), "E")
        XCTAssertEqual(dict.word(at: 67), " ")
        XCTAssertEqual(dict.word(at: 68), "\\")
        XCTAssertEqual(dict.word(at: 69), "\n")
        XCTAssertEqual(dict.word(at: 72), "\u{1a}")
        XCTAssertEqual(dict.word(at: 907), "WORLD")
        XCTAssertEqual(dict.word(at: 6571), "HELLO")
        XCTAssertEqual(dict.word(at: 49715), "HEARTBEAT")
        XCTAssertEqual(dict.word(at: 262_143), "ROSIDS")
        XCTAssertEqual(dict.oddSizes, [81: 7, 262_143: 1])
        XCTAssertEqual(dict.word(at: 10704), "¡")
        XCTAssertEqual(dict.rank(of: "QUICK"), 3971)
        XCTAssertNil(dict.rank(of: "THE"), "THE is famously absent")
        let compact = try JS8Dictionary.parseCompact(dict.compactRepresentation())
        XCTAssertEqual(compact.words, dict.words)
        XCTAssertEqual(compact.oddSizes, dict.oddSizes)
    }

    func testFullDictionaryMultiFrameText() throws {
        let dict = try fullDictionary()
        let built = JS8MessageBuilder.build(text: "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG", myCall: "KN4CRD", myGrid: "EM73",
                                            forceIdentify: false, mode: .js8, dictionary: dict)
        XCTAssertEqual(built.frames.map(\.frameString), ["nE0ETvVbsl++", "--KzLqTxbOd0", "mvjoEdWJ++++"])
        XCTAssertEqual(built.frames.map(\.type), [[.first], [], [.last]])
        let rx = JS8Receiver(dictionary: dict)
        var out: [JS8Message] = []
        for (i, f) in built.frames.enumerated() {
            out += rx.ingest([input(f, at: Double(i) * 15)])
        }
        XCTAssertEqual(out.map(\.displayText), ["THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG ♢ "])
        // The published two-frame MSG: its text frame must carry a valid checksum
        let msg1 = JS8Frame(payload: [0x71, 0x59, 0x78, 0x39, 0xee, 0x13, 0xba, 0x5f, 0x00], type: [.first])
        let msg2 = JS8Frame(payload: [0xe7, 0x48, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], type: [.last])
        let rx2 = JS8Receiver(dictionary: dict)
        _ = rx2.ingest([input(msg1, at: 0)])
        let done = rx2.ingest([input(msg2, at: 15)])
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done.first?.kind, .directed)
        XCTAssertEqual(done.first?.text, "TEST")
        print("on-air MSG: \(done.first?.displayText ?? "<none>")")
    }
}
