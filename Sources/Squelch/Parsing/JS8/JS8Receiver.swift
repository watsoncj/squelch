import Foundation

/// One assembled JS8 message — the unit the feed shows and the log keeps.
/// Mirrors the fields JS8Call publishes on its API (RX.DIRECTED).
struct JS8Message: Equatable {
    enum Kind: Equatable {
        case heartbeat
        case cq
        case directed
        /// Text with no addressee — a lone data transmission
        case freeText
    }

    var kind: Kind
    var from: String
    var to: String
    var cmd: String
    var extra: String
    var text: String
    var grid: String?
    var snr: Float
    var offsetHz: Float
    /// Start offset of the most recent frame within its slot, seconds.
    var timeOffset: Float = 0
    var timestamp: Date
    var speed: DigiMode
    /// False for the sliver JS8Call would show before the last frame.
    var isComplete: Bool

    static let endOfTransmission = "♢"

    /// Class tag for the feed filter: heartbeats and their acks are
    /// ambient telemetry; everything else is communication.
    var feedKind: String {
        switch kind {
        case .heartbeat: return "heartbeat"
        case .cq: return "cq"
        case .freeText: return "freeText"
        case .directed: return cmd == " HEARTBEAT SNR" ? "hbAck" : "directed"
        }
    }

    /// "FROM: TO CMD EXTRA TEXT ♢ " — what JS8Call prints.
    var displayText: String {
        var base = kind == .freeText ? text : to + cmd
        if kind != .freeText {
            if !extra.isEmpty { base += " " + extra }
            if !text.isEmpty { base += " " + text }
        }
        if isComplete {
            base = base.rstripped() + " " + Self.endOfTransmission + " "
        }
        return (from.isEmpty ? "" : from + ": ") + base
    }
}

/// Assembles decoded frames into messages: heartbeats and single-frame
/// commands pass straight through; directed commands buffer the text
/// frames that follow them on the same audio offset until a Last flag
/// (or a timeout) closes the message. Written from the receive-assembly
/// description; tolerances follow JS8Call's.
final class JS8Receiver {
    struct Input {
        let frame: JS8Frame
        let offsetHz: Float
        let snr: Float
        var timeOffset: Float = 0
        let timestamp: Date
        let speed: DigiMode
    }

    private struct CommandDetail {
        var from: String
        var to: String
        var cmd: String
        var extra: String
        var grid: String?
        var flags: JS8Frame.TransmissionType
        var timestamp: Date
        var snr: Float
        var offsetHz: Float
        var timeOffset: Float
        var speed: DigiMode
    }

    private struct CompoundDetail {
        var call: String
        var grid: String?
        var flags: JS8Frame.TransmissionType
        var timestamp: Date
    }

    private struct TextDetail {
        var text: String
        var flags: JS8Frame.TransmissionType
        var timestamp: Date
    }

    private struct Buffer {
        var cmd: CommandDetail?
        var compound: [CompoundDetail] = []
        var msgs: [TextDetail] = []
        var snr: Float = 0
        var timeOffset: Float = 0
        var speed: DigiMode = .js8

        var latest: Date {
            [cmd?.timestamp, compound.last?.timestamp, msgs.last?.timestamp].compactMap { $0 }.max() ?? .distantPast
        }
    }

    /// A free-text line accumulating at an offset (no command in front).
    private struct ActivityLine {
        var text: String
        var from: String
        var timestamp: Date
        var snr: Float
        var timeOffset: Float
        var speed: DigiMode
    }

    /// Messages in progress, for the UI ("receiving from … at 1500 Hz").
    struct Pending: Equatable {
        let offsetHz: Float
        let from: String?
        let to: String?
        let textSoFar: String
        let since: Date
    }

    private var buffers: [Int: Buffer] = [:]      // keyed by rounded offset
    private var activity: [Int: ActivityLine] = [:]
    private var recent: [(key: String, at: Date)] = []
    private var dictionary: JS8Dictionary?

    static let bufferIdleSeconds: TimeInterval = 60
    static let bufferExpirySeconds: TimeInterval = 90
    /// Shown where a frame went missing (JS8Call's default indicator).
    static let missingFrameMarker = "……"

    init(dictionary: JS8Dictionary? = JS8Dictionary.installed) {
        self.dictionary = dictionary
    }

    func setDictionary(_ d: JS8Dictionary?) { dictionary = d }

    /// Offset tolerance for matching a frame to an open buffer, per speed.
    static func offsetTolerance(_ speed: DigiMode) -> Float {
        switch speed {
        case .js8Fast: return 16
        case .js8Turbo: return 32
        case .js8Ultra: return 50
        default: return 10
        }
    }

    var pending: [Pending] {
        var out: [Pending] = []
        for (offset, b) in buffers {
            let text = b.msgs.map(\.text).joined()
            out.append(Pending(offsetHz: Float(offset), from: b.cmd?.from ?? b.compound.first?.call,
                               to: b.cmd?.to, textSoFar: text, since: b.latest))
        }
        for (offset, a) in activity {
            out.append(Pending(offsetHz: Float(offset), from: a.from.isEmpty ? nil : a.from, to: nil,
                               textSoFar: a.text, since: a.timestamp))
        }
        return out.sorted { $0.offsetHz < $1.offsetHz }
    }

    /// Feed one slot's decodes; returns the messages completed by them
    /// (plus any closed by timeouts). `now` defaults to the newest input's
    /// timestamp so replayed recordings age their buffers consistently.
    func ingest(_ inputs: [Input], now: Date? = nil) -> [JS8Message] {
        let now = now ?? inputs.map(\.timestamp).max() ?? Date()
        var out: [JS8Message] = []
        for input in inputs.sorted(by: { $0.offsetHz < $1.offsetHz }) {
            out.append(contentsOf: process(input))
        }
        out.append(contentsOf: completeBuffers(now: now))
        return out
    }

    // MARK: Per-frame

    private func process(_ input: Input) -> [JS8Message] {
        // De-duplicate identical frames within half a period
        let key = "\(input.speed.rawValue)/\(input.frame.hexString)/\(input.frame.type.rawValue)"
        let half = input.speed.slotSeconds / 2
        recent.removeAll { input.timestamp.timeIntervalSince($0.at) > half }
        if recent.contains(where: { $0.key == key }) { return [] }
        recent.append((key, input.timestamp))

        guard let decoded = JS8FrameCodec.decode(input.frame, dictionary: dictionary) else { return [] }
        let flags = input.frame.type
        let tolerance = Self.offsetTolerance(input.speed)
        var out: [JS8Message] = []

        // A new message on this offset supersedes whatever was buffering
        if flags.contains(.first), let k = bufferKey(near: input.offsetHz, tolerance: tolerance) {
            buffers.removeValue(forKey: k)
        }

        switch decoded {
        case .data(let text, let compressed):
            let shown = text ?? (compressed ? "[JS8 word table not installed]" : "")
            if let k = bufferKey(near: input.offsetHz, tolerance: tolerance) {
                var b = buffers.removeValue(forKey: k)!
                // A transmission sends one frame per slot: a gap of more
                // than 1.5 periods means a frame was lost — mark it
                if !b.msgs.isEmpty, input.timestamp.timeIntervalSince(b.latest) > 1.5 * input.speed.slotSeconds {
                    b.msgs.append(TextDetail(text: Self.missingFrameMarker, flags: [], timestamp: b.latest))
                }
                b.msgs.append(TextDetail(text: shown, flags: flags, timestamp: input.timestamp))
                b.snr = input.snr
                b.timeOffset = input.timeOffset
                buffers[Int(input.offsetHz.rounded())] = b
            } else {
                out.append(contentsOf: appendActivity(text: shown, input: input, tolerance: tolerance))
            }

        case .heartbeat(let call, let grid, let isCQ, let variant):
            out.append(JS8Message(
                kind: isCQ ? .cq : .heartbeat, from: call, to: isCQ ? "@ALLCALL" : "@HB",
                cmd: isCQ ? " " + JS8Command.cqString(variant) : " HEARTBEAT",
                extra: grid ?? "", text: "", grid: grid, snr: input.snr, offsetHz: input.offsetHz,
                timeOffset: input.timeOffset, timestamp: input.timestamp, speed: input.speed, isComplete: true))

        case .compound(let call, let grid):
            let k = bufferKey(near: input.offsetHz, tolerance: tolerance) ?? Int(input.offsetHz.rounded())
            var b = buffers.removeValue(forKey: k) ?? Buffer()
            b.compound.append(CompoundDetail(call: call, grid: grid, flags: flags, timestamp: input.timestamp))
            b.snr = input.snr
            b.speed = input.speed
            buffers[Int(input.offsetHz.rounded())] = b

        case .directed, .compoundDirected:
            let fromCall: String, to: String, cmd: String, extra: String?
            switch decoded {
            case .directed(let f, let t, let c, let e): (fromCall, to, cmd, extra) = (f, t, c, e)
            case .compoundDirected(let t, let c, let e): (fromCall, to, cmd, extra) = (JS8Fields.placeholderCall, t, c, e)
            default: return []
            }
            let detail = CommandDetail(from: fromCall, to: to, cmd: cmd, extra: extra ?? "", grid: nil,
                                       flags: flags, timestamp: input.timestamp, snr: input.snr,
                                       offsetHz: input.offsetHz, timeOffset: input.timeOffset, speed: input.speed)
            let needsBuffer = (JS8Command.isBuffered(cmd) && !flags.contains(.last))
                || fromCall == JS8Fields.placeholderCall || to == JS8Fields.placeholderCall
            if needsBuffer {
                let k = bufferKey(near: input.offsetHz, tolerance: tolerance) ?? Int(input.offsetHz.rounded())
                var b = buffers.removeValue(forKey: k) ?? Buffer()
                b.cmd = detail
                b.msgs.removeAll()
                b.snr = input.snr
                b.speed = input.speed
                buffers[Int(input.offsetHz.rounded())] = b
            } else {
                out.append(message(from: detail, text: "", complete: true))
            }
        }
        return out
    }

    private func bufferKey(near offset: Float, tolerance: Float) -> Int? {
        let exact = Int(offset.rounded())
        if buffers[exact] != nil { return exact }
        return buffers.keys.first { abs(Float($0) - offset) <= tolerance }
    }

    private func activityKey(near offset: Float, tolerance: Float) -> Int? {
        let exact = Int(offset.rounded())
        if activity[exact] != nil { return exact }
        return activity.keys.first { abs(Float($0) - offset) <= tolerance }
    }

    /// Free text accumulates on one line per offset until a Last flag.
    private func appendActivity(text: String, input: Input, tolerance: Float) -> [JS8Message] {
        let flags = input.frame.type
        var line: ActivityLine
        if !flags.contains(.first), let k = activityKey(near: input.offsetHz, tolerance: tolerance),
           let existing = activity.removeValue(forKey: k) {
            line = existing
            if input.timestamp.timeIntervalSince(line.timestamp) > 1.5 * input.speed.slotSeconds {
                line.text += Self.missingFrameMarker
            }
            line.text += text
        } else {
            if let k = activityKey(near: input.offsetHz, tolerance: tolerance) {
                activity.removeValue(forKey: k)
            }
            line = ActivityLine(text: text, from: "", timestamp: input.timestamp, snr: input.snr, timeOffset: input.timeOffset, speed: input.speed)
            // "CALL: text" identifies the sender
            if let colon = text.firstIndex(of: ":") {
                let call = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
                if JS8Fields.isValidCallsign(call) {
                    line.from = call
                    line.text = String(text[text.index(after: colon)...]).lstripped()
                }
            }
        }
        line.timestamp = input.timestamp
        line.snr = input.snr
        line.timeOffset = input.timeOffset
        if flags.contains(.last) {
            return [JS8Message(kind: .freeText, from: line.from, to: "", cmd: "", extra: "", text: line.text.rstripped(),
                               grid: nil, snr: line.snr, offsetHz: input.offsetHz, timeOffset: line.timeOffset,
                               timestamp: line.timestamp, speed: line.speed, isComplete: true)]
        }
        activity[Int(input.offsetHz.rounded())] = line
        return []
    }

    // MARK: Completion

    private func message(from d: CommandDetail, text: String, complete: Bool) -> JS8Message {
        let kind: JS8Message.Kind = d.cmd == " HEARTBEAT" ? .heartbeat : (d.cmd == " CQ" ? .cq : .directed)
        return JS8Message(kind: kind, from: d.from, to: d.to, cmd: d.cmd, extra: d.extra, text: text, grid: d.grid,
                          snr: d.snr, offsetHz: d.offsetHz, timeOffset: d.timeOffset, timestamp: d.timestamp,
                          speed: d.speed, isComplete: complete)
    }

    /// What an abandoned buffer can still tell us: the command (if its
    /// header frame arrived) and whatever text frames landed, with the
    /// missing tail marked. Nil when nothing presentable was heard.
    private func partialMessage(from b: Buffer) -> JS8Message? {
        var text = b.msgs.map(\.text).joined().rstripped()
        let ended = b.msgs.last?.flags.contains(.last) ?? false
        if !ended {
            text += (text.isEmpty ? "" : " ") + Self.missingFrameMarker
        }
        if var cmd = b.cmd {
            if cmd.from == JS8Fields.placeholderCall, let c = b.compound.first {
                cmd.from = c.call
                cmd.grid = c.grid
            }
            cmd.snr = b.snr
            var m = message(from: cmd, text: text, complete: false)
            m.timestamp = b.latest
            return m
        }
        guard !text.isEmpty, text != Self.missingFrameMarker else { return nil }
        let from = b.compound.first?.call ?? ""
        return JS8Message(kind: .freeText, from: from, to: "", cmd: "", extra: "", text: text,
                          grid: b.compound.first?.grid, snr: b.snr, offsetHz: 0, timeOffset: b.timeOffset,
                          timestamp: b.latest, speed: b.speed, isComplete: false)
    }

    private func completeBuffers(now: Date) -> [JS8Message] {
        var out: [JS8Message] = []
        // Compound completion: fill placeholders from buffered compound calls
        for (key, var b) in buffers {
            guard !b.compound.isEmpty, var cmd = b.cmd else { continue }
            let needFrom = cmd.from == JS8Fields.placeholderCall
            let needTo = cmd.to == JS8Fields.placeholderCall
            let needed = (needFrom ? 1 : 0) + (needTo ? 1 : 0)
            guard b.compound.count >= needed else { continue }
            var earliest = cmd.timestamp
            if needFrom {
                let c = b.compound.removeFirst()
                cmd.from = c.call
                cmd.grid = c.grid
                if c.flags.contains(.last) { cmd.flags = c.flags }
                earliest = min(earliest, c.timestamp)
            }
            if needTo {
                let c = b.compound.removeFirst()
                cmd.to = c.call
                if c.flags.contains(.last) { cmd.flags = c.flags }
                earliest = min(earliest, c.timestamp)
            }
            cmd.timestamp = earliest
            b.cmd = cmd
            if cmd.flags.contains(.last) {
                out.append(message(from: cmd, text: "", complete: true))
                buffers.removeValue(forKey: key)
            } else {
                buffers[key] = b
            }
        }
        // Buffered text completion
        for (key, var b) in buffers {
            let age = now.timeIntervalSince(b.latest)
            if age > Self.bufferIdleSeconds, !b.msgs.isEmpty {
                b.msgs[b.msgs.count - 1].flags.insert(.last)
            }
            if age > Self.bufferExpirySeconds {
                // Don't discard what was heard: deliver it as a partial
                // (no end-of-transmission marker, tail flagged as missing)
                if let partial = partialMessage(from: b) {
                    out.append(partial)
                }
                buffers.removeValue(forKey: key)
                continue
            }
            guard let last = b.msgs.last, last.flags.contains(.last) else { continue }
            guard var cmd = b.cmd else {
                // Text with no command and no placeholder to resolve
                buffers.removeValue(forKey: key)
                continue
            }
            var text = b.msgs.map(\.text).joined().rstripped()
            var valid = true
            if JS8Command.isBuffered(cmd.cmd) {
                let width = JS8Command.checksumWidth(cmd.cmd)
                if width == 32 {
                    text = text.lstripped()
                    let checksum = String(text.suffix(6))
                    let body = text.count > 7 ? String(text.dropLast(7)) : ""
                    valid = JS8Checksum.isValid32(checksum, for: body)
                    text = body
                } else if width == 16 {
                    text = text.lstripped()
                    let checksum = String(text.suffix(3))
                    let body = text.count > 4 ? String(text.dropLast(4)) : ""
                    valid = JS8Checksum.isValid16(checksum, for: body)
                    text = body
                }
            }
            if valid, cmd.from != JS8Fields.placeholderCall, cmd.to != JS8Fields.placeholderCall {
                cmd.flags.insert(.last)
                cmd.snr = b.snr
                cmd.timeOffset = b.timeOffset
                out.append(message(from: cmd, text: text, complete: true))
            } else if let partial = partialMessage(from: b) {
                // Bad checksum or unresolved placeholder — frames were
                // lost, but show what arrived rather than eating it
                out.append(partial)
            }
            buffers.removeValue(forKey: key)
        }
        // Stale free-text lines: deliver as partials, marker on the tail
        for (key, a) in activity where now.timeIntervalSince(a.timestamp) > Self.bufferExpirySeconds {
            activity.removeValue(forKey: key)
            let text = a.text.rstripped()
            guard !text.isEmpty, text != Self.missingFrameMarker else { continue }
            out.append(JS8Message(kind: .freeText, from: a.from, to: "", cmd: "", extra: "",
                                  text: text + " " + Self.missingFrameMarker, grid: nil, snr: a.snr,
                                  offsetHz: Float(key), timeOffset: a.timeOffset, timestamp: a.timestamp,
                                  speed: a.speed, isComplete: false))
        }
        return out
    }
}
