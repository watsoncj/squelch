import XCTest
@testable import Squelch

/// Store-and-forward: storage receipts, offers, retrieval — grammar pinned
/// to JS8Call's exact reply templates.
final class JS8InboxTests: XCTestCase {
    private func makeInbox() -> JS8Inbox {
        JS8Inbox(filename: "test-js8-inbox-\(UUID().uuidString).jsonl")
    }

    private func directed(from: String, to: String, cmd: String, text: String = "") -> JS8Message {
        JS8Message(kind: .directed, from: from, to: to, cmd: cmd, extra: "", text: text, grid: nil,
                   snr: -7, offsetHz: 1500, timestamp: Date(), speed: .js8, isComplete: true)
    }

    private func replies(_ m: JS8Message, inbox: JS8Inbox, relay: Bool = true) -> [String] {
        JS8Session().autoReplies(for: [m], myCall: "W0CJW", myGrid: "DM79",
                                 replyToQueries: true, ackHeartbeats: false,
                                 inbox: inbox, relayEnabled: relay)
    }

    func testStoreRequestGetsBareACK() {
        let inbox = makeInbox()
        let out = replies(directed(from: "KF0DCV", to: "W0CJW", cmd: " MSG TO:", text: "WB7TSQ MEET AT 0200Z"), inbox: inbox)
        XCTAssertEqual(out, ["KF0DCV ACK"], "storage receipt is a bare ACK, no id")
        XCTAssertEqual(inbox.held.count, 1)
        XCTAssertEqual(inbox.held.first?.to, "WB7TSQ")
        XCTAssertEqual(inbox.held.first?.text, "MEET AT 0200Z")
        XCTAssertEqual(inbox.held.first?.id, 1)
    }

    func testStoreRefusedWhenRelayOff() {
        let inbox = makeInbox()
        let out = replies(directed(from: "KF0DCV", to: "W0CJW", cmd: " MSG TO:", text: "WB7TSQ HI"), inbox: inbox, relay: false)
        XCTAssertTrue(out.isEmpty)
        XCTAssertTrue(inbox.held.isEmpty)
    }

    func testQueryMsgsOfferAndNo() {
        let inbox = makeInbox()
        XCTAssertEqual(replies(directed(from: "WB7TSQ", to: "W0CJW", cmd: " QUERY MSGS"), inbox: inbox),
                       ["WB7TSQ NO"], "nothing held: the bare NO, not \"NO MESSAGES\"")
        inbox.store(from: "KF0DCV", to: "WB7TSQ", text: "FIRST")
        inbox.store(from: "KF0DCV", to: "WB7TSQ", text: "SECOND")
        inbox.store(from: "KF0DCV", to: "K1ABC", text: "OTHER GUY")
        let s = JS8Session()
        let out = s.autoReplies(for: [directed(from: "WB7TSQ", to: "W0CJW", cmd: " QUERY MSGS")],
                                myCall: "W0CJW", myGrid: "DM79", replyToQueries: true, ackHeartbeats: false,
                                inbox: inbox, relayEnabled: true)
        XCTAssertEqual(out, ["WB7TSQ YES MSG ID 1 +1"], "oldest id offered, +count of extras")
    }

    func testRetrievalDeliversAndMarks() {
        let inbox = makeInbox()
        let id = inbox.store(from: "KF0DCV", to: "WB7TSQ", text: "MEET AT 0200Z")
        let out = replies(directed(from: "WB7TSQ", to: "W0CJW", cmd: " QUERY", text: "MSG \(id)"), inbox: inbox)
        XCTAssertEqual(out, ["WB7TSQ MSG MEET AT 0200Z FROM KF0DCV"])
        XCTAssertEqual(inbox.undelivered(for: "WB7TSQ").count, 0, "delivered on retrieval")
        // A stranger asking for someone else's message gets silence
        let id2 = inbox.store(from: "KF0DCV", to: "WB7TSQ", text: "PRIVATE")
        XCTAssertTrue(replies(directed(from: "K1ABC", to: "W0CJW", cmd: " QUERY", text: "MSG \(id2)"), inbox: inbox).isEmpty)
    }

    func testGroupHoldRetrievableByAnyoneOnceEach() {
        let inbox = makeInbox()
        let id = inbox.store(from: "W7CSO", to: "@R8AUXCOM", text: "NET MOVES TO 0100Z")
        XCTAssertEqual(replies(directed(from: "K1ABC", to: "W0CJW", cmd: " QUERY", text: "MSG \(id)"), inbox: inbox),
                       ["K1ABC MSG NET MOVES TO 0100Z FROM W7CSO"])
        XCTAssertNil(inbox.offer(for: "K1ABC"), "delivered to K1ABC")
        XCTAssertNotNil(inbox.offer(for: "W9XYZ"), "still offered to other members")
        // Group offers expire after 48 hours
        XCTAssertNil(inbox.offer(for: "W9XYZ", now: Date().addingTimeInterval(49 * 3600)))
    }

    func testPersistenceKeepsIDs() {
        let name = "test-js8-inbox-\(UUID().uuidString).jsonl"
        let a = JS8Inbox(filename: name)
        _ = a.store(from: "K1ABC", to: "W9XYZ", text: "ONE")
        _ = a.store(from: "K1ABC", to: "W9XYZ", text: "TWO")
        let b = JS8Inbox(filename: name)
        XCTAssertEqual(b.held.map(\.id), [1, 2])
        XCTAssertEqual(b.store(from: "K1ABC", to: "W9XYZ", text: "THREE"), 3, "ids keep counting after reload")
    }
}
