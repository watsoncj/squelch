import XCTest
@testable import Squelch

/// The conversation layer: what belongs in Chats, how threads key, unread.
final class JS8MessageStoreTests: XCTestCase {
    private func js8Message(kind: JS8Message.Kind, from: String, to: String, cmd: String = "", text: String = "") -> JS8Message {
        JS8Message(kind: kind, from: from, to: to, cmd: cmd, extra: "", text: text, grid: nil,
                   snr: -8, offsetHz: 1500, timestamp: Date(), speed: .js8, isComplete: true)
    }

    private func makeStore() -> JS8MessageStore {
        JS8MessageStore(filename: "test-js8-chats-\(UUID().uuidString).jsonl")
    }

    override func setUp() {
        UserDefaults.standard.set("W0CJW", forKey: SettingsKeys.myCallsign)
    }

    func testChatRelevance() {
        let me: Set<String> = ["W0CJW", "@R8AUXCOM"]
        XCTAssertTrue(JS8MessageStore.isChatRelevant(js8Message(kind: .directed, from: "K1ABC", to: "W0CJW", cmd: " MSG", text: "HI"), identities: me))
        XCTAssertTrue(JS8MessageStore.isChatRelevant(js8Message(kind: .directed, from: "W7CSO", to: "@R8AUXCOM", cmd: " "), identities: me))
        XCTAssertTrue(JS8MessageStore.isChatRelevant(js8Message(kind: .directed, from: "K1ABC", to: "W9XYZ", cmd: " MSG"), identities: me), "observed traffic stores too")
        XCTAssertFalse(JS8MessageStore.isChatRelevant(js8Message(kind: .heartbeat, from: "K1ABC", to: "@HB"), identities: me))
        XCTAssertFalse(JS8MessageStore.isChatRelevant(js8Message(kind: .directed, from: "K1ABC", to: "W0CJW", cmd: " HEARTBEAT SNR"), identities: me), "hb acks are ambient")
        XCTAssertFalse(JS8MessageStore.isChatRelevant(js8Message(kind: .cq, from: "K1ABC", to: "@ALLCALL", cmd: " CQ CQ CQ"), identities: me))
    }

    func testObservedConversationsThreadByPairAndStayRead() {
        let store = makeStore()
        store.ingest([
            js8Message(kind: .directed, from: "W7CSO", to: "KE7IK", cmd: " ", text: "IN THE EOC"),
            js8Message(kind: .directed, from: "KE7IK", to: "W7CSO", cmd: " ", text: "PARTLY CLOUDY"),
            js8Message(kind: .directed, from: "K1ABC", to: "W0CJW", cmd: " ", text: "FOR ME"),
        ], myCall: "W0CJW", identities: ["W0CJW"])
        // Observed pair threads together, in both directions
        XCTAssertEqual(store.thread(with: "KE7IK · W7CSO").map(\.text), ["IN THE EOC", "PARTLY CLOUDY"])
        XCTAssertTrue(JS8MessageStore.isObservedPartner("KE7IK · W7CSO"))
        // Narrow view: only my conversation; wide view: both
        XCTAssertEqual(store.conversations(includeObserved: false).map(\.partner), ["K1ABC"])
        XCTAssertEqual(Set(store.conversations(includeObserved: true).map(\.partner)), ["K1ABC", "KE7IK · W7CSO"])
        // Observed traffic never counts unread
        XCTAssertEqual(store.totalUnread, 1)
    }

    func testThreadKeysAndUnread() {
        let store = makeStore()
        store.ingest([
            js8Message(kind: .directed, from: "K1ABC", to: "W0CJW", cmd: " ", text: "HELLO"),
            js8Message(kind: .directed, from: "W7CSO", to: "@R8AUXCOM", cmd: " ", text: "NET IN 5"),
        ], myCall: "W0CJW", identities: ["W0CJW", "@R8AUXCOM"])
        store.recordOutgoing(text: "K1ABC HI THERE", to: "K1ABC", myCall: "W0CJW")

        let convos = store.conversations
        XCTAssertEqual(Set(convos.map(\.partner)), ["K1ABC", "@R8AUXCOM"])
        XCTAssertEqual(store.totalUnread, 2)
        // The group message threads under the group, not the sender
        XCTAssertEqual(store.thread(with: "@R8AUXCOM").map(\.text), ["NET IN 5"])
        // The K1ABC thread interleaves both directions
        XCTAssertEqual(store.thread(with: "K1ABC").map(\.outgoing), [false, true])

        store.markRead(partner: "K1ABC")
        XCTAssertEqual(store.totalUnread, 1)
        store.markRead(partner: "@R8AUXCOM")
        XCTAssertEqual(store.totalUnread, 0)
    }

    func testPersistenceRoundTrip() {
        let name = "test-js8-chats-\(UUID().uuidString).jsonl"
        let a = JS8MessageStore(filename: name)
        a.ingest([js8Message(kind: .directed, from: "K1ABC", to: "W0CJW", cmd: " MSG", text: "SAVED")],
                 myCall: "W0CJW", identities: ["W0CJW"])
        a.markRead(partner: "K1ABC")
        let b = JS8MessageStore(filename: name)
        XCTAssertEqual(b.messages.map(\.text), ["SAVED"])
        XCTAssertEqual(b.messages.first?.read, true, "read state survives the rewrite")
        XCTAssertEqual(b.totalUnread, 0)
    }

    func testBubbleText() {
        let m = JS8ChatMessage(id: UUID(), timestamp: Date(), from: "K1ABC", to: "W0CJW",
                               cmd: " MSG", text: "HELLO", snr: -5, offsetHz: 1500, outgoing: false, read: false)
        XCTAssertEqual(m.bubbleText, "MSG HELLO")
    }
}
