import Foundation

/// Messages this station holds for third parties — JS8's store-and-forward
/// mailbox ("MSG TO:"). Ids are small autoincrementing integers local to
/// the holder, exactly as JS8Call allocates them; group-held messages may
/// be retrieved once per station and expire from offers after 48 hours.
final class JS8Inbox: ObservableObject {
    struct Held: Codable, Identifiable, Equatable {
        let id: Int
        let from: String
        let to: String          // a callsign or an @group
        let text: String
        let storedAt: Date
        var delivered: Bool     // direct messages: retrieved once
        var deliveredTo: [String] // group messages: per-retriever tracking
    }

    @Published private(set) var held: [Held] = []
    private var nextID = 1
    private let fileURL: URL
    static let groupOfferWindow: TimeInterval = 48 * 3600

    init(filename: String = "js8-inbox.jsonl") {
        fileURL = squelchSupportDirectory().appendingPathComponent(filename)
        load()
    }

    @discardableResult
    func store(from: String, to: String, text: String, at: Date = Date()) -> Int {
        let id = nextID
        nextID += 1
        held.append(Held(id: id, from: from.uppercased(), to: to.uppercased(),
                         text: text, storedAt: at, delivered: false, deliveredTo: []))
        persist()
        return id
    }

    /// Undelivered messages this station may offer `caller`, oldest first:
    /// direct holds addressed to them, plus group holds inside the 48 h
    /// window they haven't retrieved yet.
    func undelivered(for caller: String, now: Date = Date()) -> [Held] {
        let c = caller.uppercased()
        return held.filter { h in
            guard !h.text.isEmpty else { return false }
            if h.to.hasPrefix("@") {
                return !h.deliveredTo.contains(c) && now.timeIntervalSince(h.storedAt) < Self.groupOfferWindow
            }
            return h.to == c && !h.delivered
        }
    }

    /// The " YES MSG ID <id>[ +<k>]" offer, or nil when nothing is held.
    func offer(for caller: String, now: Date = Date()) -> (id: Int, more: Int)? {
        let list = undelivered(for: caller, now: now)
        guard let first = list.first else { return nil }
        return (first.id, list.count - 1)
    }

    /// The message for a "QUERY MSG <id>" — nil unless the id exists and
    /// the caller is entitled (addressee, or anyone for a group hold).
    func message(id: Int, for caller: String) -> Held? {
        guard let h = held.first(where: { $0.id == id }), !h.text.isEmpty else { return nil }
        if h.to.hasPrefix("@") { return h }
        return h.to == caller.uppercased() ? h : nil
    }

    func markDelivered(id: Int, to caller: String) {
        guard let i = held.firstIndex(where: { $0.id == id }) else { return }
        if held[i].to.hasPrefix("@") {
            if !held[i].deliveredTo.contains(caller.uppercased()) {
                held[i].deliveredTo.append(caller.uppercased())
            }
        } else {
            held[i].delivered = true
        }
        persist()
    }

    func remove(id: Int) {
        held.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var out = Data()
        for h in held {
            guard let d = try? encoder.encode(h) else { continue }
            out.append(d)
            out.append(Data("\n".utf8))
        }
        try? out.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        held = content.split(separator: "\n").compactMap { try? decoder.decode(Held.self, from: Data($0.utf8)) }
        nextID = (held.map(\.id).max() ?? 0) + 1
    }
}
