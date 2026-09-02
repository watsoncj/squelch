import Foundation
import Combine

/// Main-thread owner of the JS8 receive side: feeds frames to the
/// assembler, publishes what's still arriving, and manages the word table.
final class JS8Session: ObservableObject {
    /// Messages still being received (a directed command waiting for its
    /// text, free text mid-transmission).
    @Published private(set) var pending: [JS8Receiver.Pending] = []

    /// A station that acknowledged one of our heartbeats: their report of
    /// our signal, freshest first. The JS8 twin of WSPR's beacon reports.
    struct HeardBy: Identifiable, Equatable {
        let call: String
        let report: String   // their SNR of us, e.g. "-14"
        let at: Date
        var id: String { call }
    }
    @Published private(set) var heardBy: [HeardBy] = []
    static let heardByMaxAge: TimeInterval = 60 * 60

    @Published private(set) var wordTableInstalled: Bool
    @Published private(set) var wordTableStatus: String?
    @Published private(set) var installingWordTable = false

    /// Frames waiting to go out, one per slot.
    @Published private(set) var txQueue: [JS8Frame] = []
    /// The message the queue belongs to, for the UI.
    @Published private(set) var txLabel: String?
    private var txFramesTotal = 0
    private var txEcho: JS8Message?
    /// Audio offset for the queued message; nil = the station's TX offset.
    /// Heartbeats use this to ride the 500–1000 Hz heartbeat sub-band.
    private(set) var txOffsetOverride: Double?

    /// Rate limiter for unsolicited-ish replies (group-addressed queries
    /// and heartbeat acks). Queries directed at our own callsign are part
    /// of a conversation and are never limited — matching JS8Call, whose
    /// 15-minute limit applies to @ALLCALL/group traffic only.
    private var autoRepliedAt: [String: Date] = [:]
    static let autoReplyIntervalSeconds: TimeInterval = 15 * 60

    /// Stations heard recently (any decoded message), for HEARING? replies.
    private var heardAt: [String: Date] = [:]
    static let hearingWindowSeconds: TimeInterval = 30 * 60
    /// The last line we transmitted — what an AGN? repeats.
    private(set) var lastSentText: String?

    /// Groups this station has joined (@R8AUXCOM, @CENTS, …). Traffic to a
    /// joined group counts as addressed to us: highlighted, threaded, and
    /// eligible for auto-reply. Parsed from the comma-separated setting.
    static func joinedGroups(from raw: String?) -> Set<String> {
        guard let raw else { return [] }
        return Set(raw.uppercased()
            .split(whereSeparator: { ", ".contains($0) })
            .map { $0.hasPrefix("@") ? String($0) : "@" + $0 }
            .filter { $0.count > 1 && JS8Fields.isValidCallsign($0) })
    }

    var joinedGroups: Set<String> {
        Self.joinedGroups(from: UserDefaults.standard.string(forKey: SettingsKeys.js8Groups))
    }

    /// The set of destinations that mean "this is for me".
    func identities(myCall: String) -> Set<String> {
        var ids = joinedGroups
        if !myCall.isEmpty { ids.insert(myCall.uppercased()) }
        return ids
    }

    private let receiver: JS8Receiver

    static let wordTableURL = URL(string: "https://raw.githubusercontent.com/JS8Call-improved/JS8Call-improved/HEAD/JS8_JSC/JSC_map.cpp")!

    init() {
        let dict = JS8Dictionary.installed
        receiver = JS8Receiver(dictionary: dict)
        wordTableInstalled = dict != nil
    }

    /// One slot's frames → completed messages.
    func ingest(results: [FT8Result], slotStart: Date, speed: DigiMode) -> [JS8Message] {
        let inputs = results.compactMap { r -> JS8Receiver.Input? in
            guard let frame = r.js8 else { return nil }
            return JS8Receiver.Input(frame: frame, offsetHz: r.freqHz, snr: r.snr, timeOffset: r.timeOffset,
                                     timestamp: slotStart, speed: speed)
        }
        let messages = receiver.ingest(inputs, now: slotStart.addingTimeInterval(speed.slotSeconds))
        pending = receiver.pending
        noteHeardBy(messages)
        noteHeard(messages)
        return messages
    }

    private func noteHeard(_ messages: [JS8Message], now: Date = Date()) {
        heardAt = heardAt.filter { now.timeIntervalSince($0.value) < Self.hearingWindowSeconds }
        for m in messages where !m.from.isEmpty && m.from != JS8Fields.placeholderCall
            && JS8Fields.isValidCallsign(m.from) {
            heardAt[m.from.uppercased()] = m.timestamp
        }
    }

    /// Up to `limit` recently heard stations, freshest first, minus the
    /// excluded calls (the asker, ourselves).
    func recentlyHeard(excluding: Set<String>, limit: Int = 4, now: Date = Date()) -> [String] {
        heardAt
            .filter { now.timeIntervalSince($0.value) < Self.hearingWindowSeconds && !excluding.contains($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    /// Track " HEARTBEAT SNR" acks addressed to us.
    private func noteHeardBy(_ messages: [JS8Message]) {
        let me = (UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? "").uppercased()
        guard !me.isEmpty else { return }
        var list = heardBy.filter { Date().timeIntervalSince($0.at) < Self.heardByMaxAge }
        var changed = list.count != heardBy.count
        for m in messages where m.kind == .directed && m.cmd == " HEARTBEAT SNR" && m.to.uppercased() == me {
            list.removeAll { $0.call == m.from.uppercased() }
            list.insert(HeardBy(call: m.from.uppercased(), report: m.extra, at: m.timestamp), at: 0)
            changed = true
        }
        if changed { heardBy = list.sorted { $0.at > $1.at } }
    }

    func reset() {
        pending = []
    }

    // MARK: Transmit queue

    var isSending: Bool { !txQueue.isEmpty }

    /// Build a message into frames and queue it. One outgoing message at a
    /// time — a queue in flight refuses new sends (the UI disables Send).
    @discardableResult
    func send(text: String, myCall: String, myGrid: String, selectedCall: String = "", mode: DigiMode,
              offsetHz: Double? = nil) -> Bool {
        guard !isSending, !myCall.isEmpty else { return false }
        let line = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !line.isEmpty else { return false }
        let built = JS8MessageBuilder.build(text: line, myCall: myCall, myGrid: myGrid,
                                           selectedCall: selectedCall, mode: mode,
                                           dictionary: JS8Dictionary.installed)
        guard !built.frames.isEmpty else { return false }
        txQueue = built.frames
        txFramesTotal = built.frames.count
        txLabel = line
        txOffsetOverride = offsetHz
        lastSentText = line
        // Local echo, shown when the last frame has gone out; displayText
        // renders it as "MYCALL: <line> ♢ "
        txEcho = JS8Message(kind: .freeText, from: myCall.uppercased(), to: built.directedTo ?? "",
                            cmd: "", extra: "", text: line, grid: nil, snr: 0, offsetHz: 0,
                            timestamp: Date(), speed: mode, isComplete: true)
        return true
    }

    /// Pop the next frame to transmit this slot.
    func nextFrame() -> (frame: JS8Frame, label: String, isLast: Bool)? {
        guard !txQueue.isEmpty else { return nil }
        let frame = txQueue.removeFirst()
        let index = txFramesTotal - txQueue.count
        let label = "JS8 \(index)/\(txFramesTotal): \(txLabel ?? "")"
        let isLast = txQueue.isEmpty
        if isLast { txLabel = nil }
        return (frame, label, isLast)
    }

    /// The echo message for the just-completed transmission.
    func takeEcho() -> JS8Message? {
        defer { txEcho = nil }
        return txEcho
    }

    func haltTX() {
        txQueue = []
        txLabel = nil
        txEcho = nil
        txOffsetOverride = nil
    }

    // MARK: Auto-replies

    /// Reply texts owed for this slot's completed messages: query answers
    /// when addressed to us, heartbeat acknowledgements when enabled. At
    /// most one per slot, rate-limited per sender, never while sending.
    func autoReplies(for messages: [JS8Message], myCall: String, myGrid: String,
                     replyToQueries: Bool, ackHeartbeats: Bool,
                     inbox: JS8Inbox? = nil, relayEnabled: Bool = false,
                     info: String = "", statusText: String = "", now: Date = Date()) -> [String] {
        guard !isSending, !myCall.isEmpty else { return [] }
        let me = myCall.uppercased()
        let mine = identities(myCall: me)
        autoRepliedAt = autoRepliedAt.filter { now.timeIntervalSince($0.value) < Self.autoReplyIntervalSeconds }
        noteHeard(messages, now: now)
        for m in messages {
            let sender = m.from.uppercased()
            guard !sender.isEmpty, sender != me, JS8Fields.isValidCallsign(sender) else { continue }
            // Group-addressed queries and heartbeat acks are rate-limited;
            // queries to our own callsign are conversation and are not
            let isDirect = m.to.uppercased() == me
            if !isDirect, autoRepliedAt[sender] != nil { continue }
            let snr = JS8Fields.formatSNR(max(-30, min(31, Int(m.snr.rounded()))))
            var reply: String?
            if replyToQueries, m.kind == .directed, m.cmd == " MSG", mine.contains(m.to.uppercased()), !m.text.isEmpty {
                // A receipted message: acknowledge delivery (the receipt is
                // the point of MSG — exempt from the per-station rate limit)
                autoRepliedAt.removeValue(forKey: sender)
                return ["\(sender) ACK"]
            }
            if replyToQueries, relayEnabled, let inbox, m.kind == .directed, m.cmd == " MSG TO:",
               m.to.uppercased() == me, !m.text.isEmpty {
                // Hold a message for a third station: "ME MSG TO:DEST text".
                // The destination is the first token of the buffered text;
                // the storage receipt is a bare ACK (the id travels later
                // via QUERY MSGS).
                let parts = m.text.split(separator: " ", maxSplits: 1)
                if parts.count == 2, JS8Fields.isValidCallsign(String(parts[0])) {
                    inbox.store(from: sender, to: String(parts[0]), text: String(parts[1]))
                    autoRepliedAt.removeValue(forKey: sender)
                    return ["\(sender) ACK"]
                }
            }
            if replyToQueries, isDirect, m.kind == .directed, m.cmd == " AGN?", let last = lastSentText {
                // Repeat the previous transmission verbatim
                return [last]
            }
            if replyToQueries, m.kind == .directed, mine.contains(m.to.uppercased()) {
                switch m.cmd {
                case " SNR?": reply = "\(sender) SNR \(snr)"
                case " GRID?":
                    let grid = String(myGrid.uppercased().prefix(4))
                    if !grid.isEmpty { reply = "\(sender) GRID \(grid)" }
                case " INFO?":
                    let text = info.uppercased().trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { reply = "\(sender) INFO \(text)" }
                case " STATUS?":
                    let text = statusText.uppercased().trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { reply = "\(sender) STATUS \(text)" }
                case " HEARING?":
                    let calls = recentlyHeard(excluding: [sender, me], now: now)
                    if !calls.isEmpty { reply = "\(sender) HEARING \(calls.joined(separator: " "))" }
                case " QUERY MSGS":
                    // "<FROM> YES MSG ID <id>[ +<k>]" or the bare "<FROM> NO"
                    if let inbox, let offerFor = inbox.offer(for: sender, now: now) {
                        reply = "\(sender) YES MSG ID \(offerFor.id)" + (offerFor.more > 0 ? " +\(offerFor.more)" : "")
                    } else {
                        reply = "\(sender) NO"
                    }
                case " QUERY":
                    // Retrieval: "QUERY" with payload "MSG <id>" delivers the
                    // stored text as "<FROM> MSG <text> FROM <orig>"
                    if let inbox,
                       let match = m.text.range(of: "^MSG (\\d+)$", options: .regularExpression),
                       let id = Int(m.text[match].dropFirst(4)),
                       let heldMessage = inbox.message(id: id, for: sender) {
                        inbox.markDelivered(id: id, to: sender)
                        autoRepliedAt.removeValue(forKey: sender)
                        return ["\(sender) MSG \(heldMessage.text) FROM \(heldMessage.from)"]
                    }
                default: break
                }
            } else if ackHeartbeats, m.kind == .heartbeat, m.to == "@HB" {
                reply = "\(sender) HEARTBEAT SNR \(snr)"
            }
            if let reply {
                if !isDirect { autoRepliedAt[sender] = now }
                return [reply]
            }
        }
        return []
    }

    // MARK: Word table

    /// Install from a local JSC_map.cpp (or compact) file.
    func installWordTable(from url: URL) {
        installingWordTable = true
        wordTableStatus = "Reading \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try JS8Dictionary.install(from: url) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.installingWordTable = false
                switch result {
                case .success(let dict):
                    self.receiver.setDictionary(dict)
                    self.wordTableInstalled = true
                    self.wordTableStatus = "Installed \(dict.words.count) words"
                case .failure(let error):
                    self.wordTableStatus = error.localizedDescription
                }
            }
        }
    }

    /// Fetch JS8Call's table from its repository and install it.
    func downloadWordTable() {
        guard !installingWordTable else { return }
        installingWordTable = true
        wordTableStatus = "Downloading JSC_map.cpp (7 MB)…"
        let task = URLSession.shared.downloadTask(with: Self.wordTableURL) { [weak self] tmp, response, error in
            let outcome: Result<URL, Error> = {
                if let error { return .failure(error) }
                guard let tmp, (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                    return .failure(JS8Dictionary.LoadError.badTable("download failed"))
                }
                let dest = JS8Dictionary.sourceURL
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    return .success(dest)
                } catch {
                    return .failure(error)
                }
            }()
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .success(let url):
                    self.installingWordTable = false
                    self.installWordTable(from: url)
                case .failure(let error):
                    self.installingWordTable = false
                    self.wordTableStatus = "Download failed: \(error.localizedDescription)"
                }
            }
        }
        task.resume()
    }
}
