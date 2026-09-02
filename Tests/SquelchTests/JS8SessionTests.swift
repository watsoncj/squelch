import XCTest
@testable import Squelch

/// The JS8 transmit queue and auto-reply policy.
final class JS8SessionTests: XCTestCase {
    private func message(kind: JS8Message.Kind, from: String, to: String, cmd: String, snr: Float = -7) -> JS8Message {
        JS8Message(kind: kind, from: from, to: to, cmd: cmd, extra: "", text: "", grid: nil,
                   snr: snr, offsetHz: 1500, timestamp: Date(), speed: .js8, isComplete: true)
    }

    func testSendQueuesFramesAndPopsInOrder() {
        let s = JS8Session()
        XCTAssertTrue(s.send(text: "W0ABC SNR?", myCall: "W0CJW", myGrid: "DM79", mode: .js8))
        XCTAssertTrue(s.isSending)
        XCTAssertEqual(s.txQueue.count, 1)
        let next = s.nextFrame()
        XCTAssertNotNil(next)
        XCTAssertTrue(next!.isLast)
        XCTAssertTrue(next!.label.contains("1/1"))
        XCTAssertFalse(s.isSending)
        XCTAssertNil(s.nextFrame())
        // Echo carries the sender-prefixed display text
        XCTAssertEqual(s.takeEcho()?.displayText.hasPrefix("W0CJW: W0ABC SNR?"), true)
        XCTAssertNil(s.takeEcho())
    }

    func testSecondSendRefusedWhileSending() {
        let s = JS8Session()
        XCTAssertTrue(s.send(text: "HEARTBEAT DM79", myCall: "W0CJW", myGrid: "DM79", mode: .js8))
        XCTAssertFalse(s.send(text: "W0ABC SNR?", myCall: "W0CJW", myGrid: "DM79", mode: .js8))
        s.haltTX()
        XCTAssertFalse(s.isSending)
        XCTAssertTrue(s.send(text: "W0ABC SNR?", myCall: "W0CJW", myGrid: "DM79", mode: .js8))
    }

    func testEmptyOrCallsignlessSendRefused() {
        let s = JS8Session()
        XCTAssertFalse(s.send(text: "  ", myCall: "W0CJW", myGrid: "DM79", mode: .js8))
        XCTAssertFalse(s.send(text: "HELLO", myCall: "", myGrid: "DM79", mode: .js8))
    }

    func testAutoReplyAnswersQueriesAddressedToMe() {
        let s = JS8Session()
        let snrQuery = message(kind: .directed, from: "KN4CRD", to: "W0CJW", cmd: " SNR?", snr: -12.4)
        let replies = s.autoReplies(for: [snrQuery], myCall: "W0CJW", myGrid: "DM79",
                                    replyToQueries: true, ackHeartbeats: false)
        XCTAssertEqual(replies, ["KN4CRD SNR -12"])
        // Someone else's query is not ours to answer
        let other = message(kind: .directed, from: "KN4CRD", to: "K1ABC", cmd: " SNR?")
        XCTAssertTrue(s.autoReplies(for: [other], myCall: "W0CJW", myGrid: "DM79",
                                    replyToQueries: true, ackHeartbeats: false).isEmpty)
        // Disabled → nothing
        XCTAssertTrue(s.autoReplies(for: [snrQuery], myCall: "W0CJW", myGrid: "DM79",
                                    replyToQueries: false, ackHeartbeats: false).isEmpty)
    }

    func testAutoReplyGridQueryUsesMyGrid() {
        let s = JS8Session()
        let q = message(kind: .directed, from: "KN4CRD", to: "W0CJW", cmd: " GRID?")
        XCTAssertEqual(s.autoReplies(for: [q], myCall: "W0CJW", myGrid: "DM79ob",
                                     replyToQueries: true, ackHeartbeats: false),
                       ["KN4CRD GRID DM79"])
    }

    func testHeartbeatAckGatedAndFormatted() {
        let s = JS8Session()
        let hb = message(kind: .heartbeat, from: "KE8WCR", to: "@HB", cmd: " HEARTBEAT", snr: 3.2)
        XCTAssertTrue(s.autoReplies(for: [hb], myCall: "W0CJW", myGrid: "DM79",
                                    replyToQueries: true, ackHeartbeats: false).isEmpty)
        XCTAssertEqual(s.autoReplies(for: [hb], myCall: "W0CJW", myGrid: "DM79",
                                     replyToQueries: false, ackHeartbeats: true),
                       ["KE8WCR HEARTBEAT SNR +03"])
        // The ack line round-trips through the builder as command 29
        let built = JS8MessageBuilder.build(text: "KE8WCR HEARTBEAT SNR +03", myCall: "W0CJW", myGrid: "DM79",
                                            mode: .js8, dictionary: nil)
        XCTAssertEqual(built.frames.count, 1)
        guard case .directed(let from, let to, let cmd, let extra)? =
            JS8FrameCodec.decode(built.frames[0], dictionary: nil) else { return XCTFail() }
        XCTAssertEqual([from, to, cmd, extra ?? ""], ["W0CJW", "KE8WCR", " HEARTBEAT SNR", "+03"])
    }

    func testAutoReplyRateLimitsPerSender() {
        let s = JS8Session()
        let now = Date()
        let hb = message(kind: .heartbeat, from: "KE8WCR", to: "@HB", cmd: " HEARTBEAT")
        XCTAssertEqual(s.autoReplies(for: [hb], myCall: "W0CJW", myGrid: "DM79",
                                     replyToQueries: false, ackHeartbeats: true, now: now).count, 1)
        XCTAssertTrue(s.autoReplies(for: [hb], myCall: "W0CJW", myGrid: "DM79",
                                    replyToQueries: false, ackHeartbeats: true,
                                    now: now.addingTimeInterval(600)).isEmpty,
                      "10 minutes later — still inside the 15 min limit")
        XCTAssertEqual(s.autoReplies(for: [hb], myCall: "W0CJW", myGrid: "DM79",
                                     replyToQueries: false, ackHeartbeats: true,
                                     now: now.addingTimeInterval(16 * 60)).count, 1)
    }

    func testAutoReplySuppressedWhileSending() {
        let s = JS8Session()
        _ = s.send(text: "HEARTBEAT DM79", myCall: "W0CJW", myGrid: "DM79", mode: .js8)
        let q = message(kind: .directed, from: "KN4CRD", to: "W0CJW", cmd: " SNR?")
        XCTAssertTrue(s.autoReplies(for: [q], myCall: "W0CJW", myGrid: "DM79",
                                    replyToQueries: true, ackHeartbeats: true).isEmpty)
    }

    func testJoinedGroupParsing() {
        XCTAssertEqual(JS8Session.joinedGroups(from: "@R8AUXCOM, @CENTS"), ["@R8AUXCOM", "@CENTS"])
        XCTAssertEqual(JS8Session.joinedGroups(from: "r8auxcom cents"), ["@R8AUXCOM", "@CENTS"],
                       "bare names get their @ and uppercasing")
        XCTAssertEqual(JS8Session.joinedGroups(from: nil), [])
        XCTAssertEqual(JS8Session.joinedGroups(from: " , ,"), [])
    }

    func testAutoReplyAnswersJoinedGroupQueries() {
        let s = JS8Session()
        UserDefaults.standard.set("@R8AUXCOM", forKey: SettingsKeys.js8Groups)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKeys.js8Groups) }
        let q = message(kind: .directed, from: "W7CSO", to: "@R8AUXCOM", cmd: " SNR?", snr: -8.2)
        XCTAssertEqual(s.autoReplies(for: [q], myCall: "W0CJW", myGrid: "DM79",
                                     replyToQueries: true, ackHeartbeats: false),
                       ["W7CSO SNR -08"])
        // Same query to a group we haven't joined: silence
        let other = message(kind: .directed, from: "W7CSO", to: "@CENTS", cmd: " SNR?")
        let s2 = JS8Session()
        XCTAssertTrue(s2.autoReplies(for: [other], myCall: "W0CJW", myGrid: "DM79",
                                     replyToQueries: true, ackHeartbeats: false).isEmpty)
    }

    func testMultiFrameMessageCountsDown() {
        let s = JS8Session()
        XCTAssertTrue(s.send(text: "W0ABC MSG HELLO HELLO HELLO", myCall: "W0CJW", myGrid: "DM79", mode: .js8))
        XCTAssertGreaterThan(s.txQueue.count, 1)
        var labels: [Bool] = []
        while let next = s.nextFrame() { labels.append(next.isLast) }
        XCTAssertEqual(labels.filter { $0 }.count, 1)
        XCTAssertEqual(labels.last, true)
    }
}
