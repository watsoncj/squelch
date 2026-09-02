import Foundation

/// One message in a JS8 conversation — richer than the feed's flattened
/// text: sender, addressee and command survive, so threads can render.
struct JS8ChatMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let from: String
    let to: String
    let cmd: String
    let text: String
    let snr: Float
    let offsetHz: Float
    let outgoing: Bool
    var read: Bool

    /// The line a thread bubble shows: command + text, without the
    /// addressing that the thread already implies.
    var bubbleText: String {
        let c = cmd.trimmingCharacters(in: .whitespaces)
        let t = text.trimmingCharacters(in: .whitespaces)
        switch (c.isEmpty, t.isEmpty) {
        case (true, false): return t
        case (false, true): return c
        case (false, false): return "\(c) \(t)"
        case (true, true): return ""
        }
    }
}

/// The conversation layer: persists chat-relevant JS8 traffic (addressed
/// to this station or its joined groups, plus everything it sends) and
/// derives per-correspondent threads with unread counts.
final class JS8MessageStore: ObservableObject {
    @Published private(set) var messages: [JS8ChatMessage] = [] // oldest first

    struct Conversation: Identifiable, Equatable {
        let partner: String     // a callsign or an @group
        let last: JS8ChatMessage
        let unread: Int
        var id: String { partner }
    }

    private let fileURL: URL
    private var fileHandle: FileHandle?
    private let encoder = JSONEncoder()
    static let maxInMemory = 2000

    init(filename: String = "js8-chats.jsonl") {
        fileURL = squelchSupportDirectory().appendingPathComponent(filename)
        encoder.dateEncodingStrategy = .iso8601
        loadFromDisk()
    }

    /// Which conversation a message belongs to, from this station's view.
    static func partner(for m: JS8ChatMessage, myCall: String) -> String? {
        let me = myCall.uppercased()
        if m.outgoing {
            return m.to.isEmpty ? nil : m.to
        }
        if m.to.hasPrefix("@") { return m.to }
        if m.to.uppercased() == me { return m.from }
        return nil
    }

    /// True when this decoded message belongs in Chats rather than only
    /// the feed: directed/free-text traffic to us or a joined group.
    static func isChatRelevant(_ m: JS8Message, identities: Set<String>) -> Bool {
        switch m.kind {
        case .heartbeat, .cq: return false
        case .directed:
            if m.cmd == " HEARTBEAT SNR" { return false } // ambient ack
            return identities.contains(m.to.uppercased())
        case .freeText:
            return false // broadcast chatter stays in the feed
        }
    }

    func ingest(_ incoming: [JS8Message], myCall: String, identities: Set<String>) {
        let relevant = incoming.filter { Self.isChatRelevant($0, identities: identities) }
        guard !relevant.isEmpty else { return }
        let new = relevant.map { m in
            JS8ChatMessage(id: UUID(), timestamp: m.timestamp, from: m.from.uppercased(),
                           to: m.to.uppercased(), cmd: m.cmd, text: m.text, snr: m.snr,
                           offsetHz: m.offsetHz, outgoing: false, read: false)
        }
        append(new)
    }

    func recordOutgoing(text: String, to: String, cmd: String = "", myCall: String) {
        guard !myCall.isEmpty else { return }
        append([JS8ChatMessage(id: UUID(), timestamp: Date(), from: myCall.uppercased(),
                               to: to.uppercased(), cmd: cmd, text: text, snr: 0, offsetHz: 0,
                               outgoing: true, read: true)])
    }

    var conversations: [Conversation] {
        var lastByPartner: [String: JS8ChatMessage] = [:]
        var unread: [String: Int] = [:]
        let me = myCallCached
        for m in messages {
            guard let partner = Self.partner(for: m, myCall: me) else { continue }
            lastByPartner[partner] = m
            if !m.outgoing, !m.read {
                unread[partner, default: 0] += 1
            }
        }
        return lastByPartner
            .map { Conversation(partner: $0.key, last: $0.value, unread: unread[$0.key] ?? 0) }
            .sorted { $0.last.timestamp > $1.last.timestamp }
    }

    func thread(with partner: String) -> [JS8ChatMessage] {
        let me = myCallCached
        return messages.filter { Self.partner(for: $0, myCall: me) == partner }
    }

    var totalUnread: Int {
        conversations.reduce(0) { $0 + $1.unread }
    }

    func markRead(partner: String) {
        let me = myCallCached
        var changed = false
        for i in messages.indices where Self.partner(for: messages[i], myCall: me) == partner && !messages[i].read {
            messages[i].read = true
            changed = true
        }
        if changed { rewriteFile() }
    }

    private var myCallCached: String {
        UserDefaults.standard.string(forKey: SettingsKeys.myCallsign)?.uppercased() ?? ""
    }

    // MARK: Persistence (QSOLog's shape: JSONL, append + rewrite)

    private func append(_ new: [JS8ChatMessage]) {
        messages.append(contentsOf: new)
        if messages.count > Self.maxInMemory {
            messages.removeFirst(messages.count - Self.maxInMemory)
            rewriteFile()
        } else {
            for m in new {
                guard let data = try? encoder.encode(m) else { continue }
                if fileHandle == nil {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                    fileHandle = try? FileHandle(forWritingTo: fileURL)
                    _ = try? fileHandle?.seekToEnd()
                }
                try? fileHandle?.write(contentsOf: data + Data("\n".utf8))
            }
        }
    }

    private func rewriteFile() {
        try? fileHandle?.close()
        fileHandle = nil
        var out = Data()
        for m in messages {
            guard let data = try? encoder.encode(m) else { continue }
            out.append(data)
            out.append(Data("\n".utf8))
        }
        try? out.write(to: fileURL, options: .atomic)
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        _ = try? fileHandle?.seekToEnd()
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        messages = content.split(separator: "\n")
            .suffix(Self.maxInMemory)
            .compactMap { try? decoder.decode(JS8ChatMessage.self, from: Data($0.utf8)) }
    }
}
