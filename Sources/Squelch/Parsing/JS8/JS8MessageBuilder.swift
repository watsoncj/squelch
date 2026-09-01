import Foundation

/// Turns a line of operator text into JS8 frames — heartbeat/CQ, directed
/// commands (with compound-callsign expansion and checksums) and text.
/// Written from the message-building description.
enum JS8MessageBuilder {
    struct Result {
        var frames: [JS8Frame] = []
        /// Directed-command metadata when the line was directed.
        var directedTo: String?
        var directedCmd: String?
        var directedNum: String?
    }

    private static let backtick: Character = "`"

    static func build(text input: String, myCall: String, myGrid: String, selectedCall: String = "",
                      forceIdentify: Bool = true, forceData: Bool = false, mode: DigiMode,
                      dictionary: JS8Dictionary? = JS8Dictionary.installed) -> Result {
        var result = Result()
        let myCall = myCall.uppercased()
        let myGrid4 = String(myGrid.uppercased().prefix(4))
        var forceIdentify = forceIdentify
        var hasData = forceData
        var hasDirected = false
        if forceData { forceIdentify = false }

        var line = input.uppercased().trimmingCharacters(in: .newlines)
        // Auto-remove own call
        if !myCall.isEmpty {
            if line.hasPrefix(myCall + ":") {
                line = String(line.dropFirst(myCall.count + 1)).lstripped()
            } else if line.hasPrefix(myCall + " ") {
                line = String(line.dropFirst(myCall.count + 1)).lstripped()
            }
        }
        // Auto-prepend the selected call
        let selected = selectedCall.uppercased()
        if !selected.isEmpty, !forceData, !line.hasPrefix(selected), line.first != backtick {
            let startsWithKnown = line.hasPrefix("@ALLCALL")
                || JS8Command.cqStrings.contains { line.hasPrefix($0) }
                || line.hasPrefix("HB")
                || leadingStandardCall(line).map { $0.count > 3 } ?? false
            if !startsWithKnown {
                line = selected + (line.hasPrefix(" ") ? "" : " ") + line
            }
        }

        var payloads: [(payload: [UInt8], data: Bool)] = []
        var guardCounter = 0
        while !line.isEmpty, guardCounter < 200 {
            guardCounter += 1
            // 1. heartbeat / CQ
            if !hasDirected, !hasData, let hb = packHeartbeat(line, call: myCall) {
                payloads.append((hb.payload, false))
                line = String(line.dropFirst(hb.consumed))
                continue
            }
            // 2. compound (backtick)
            if !hasDirected, !hasData, let c = packCompound(line) {
                payloads.append((c.payload, false))
                line = String(line.dropFirst(c.consumed))
                continue
            }
            // 3. directed
            if !hasDirected, !hasData, let d = packDirected(line, myCall: myCall, myGrid: myGrid4) {
                payloads.append(contentsOf: d.payloads.map { ($0, false) })
                hasDirected = true
                result.directedTo = d.to
                result.directedCmd = d.cmd
                result.directedNum = d.num
                line = String(line.dropFirst(d.consumed))
                if JS8Command.isBuffered(d.cmd), !line.isEmpty {
                    line = line.lstripped()
                    let width = JS8Command.checksumWidth(d.cmd)
                    let aprs = d.to == "@APRSIS" && (d.cmd == " MSG" || d.cmd == " MSG TO:")
                    if width == 16, !aprs {
                        line += " " + JS8Checksum.checksum16(line)
                    } else if width == 32, !aprs {
                        line += " " + JS8Checksum.checksum32(line)
                    }
                }
                continue
            }
            // 4. data
            if forceIdentify, payloads.isEmpty, selected.isEmpty, !myCall.isEmpty, !line.contains(myCall) {
                line = myCall + ": " + line
            }
            let packed = packData(line, mode: mode, dictionary: dictionary)
            guard let (payload, consumed) = packed, consumed > 0 else { break }
            payloads.append((payload, mode != .js8))
            hasData = true
            line = String(line.dropFirst(consumed))
        }

        result.frames = payloads.enumerated().map { i, p in
            var flags: JS8Frame.TransmissionType = []
            if i == 0 { flags.insert(.first) }
            if i == payloads.count - 1 { flags.insert(.last) }
            if p.data { flags.insert(.data) }
            return JS8Frame(payload: p.payload, type: flags)
        }
        return result
    }

    // MARK: Packers

    static func packHeartbeat(_ line: String, call: String) -> (payload: [UInt8], consumed: Int)? {
        guard let m = JS8Command.heartbeatRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let type = m.group("type", in: line) else { return nil }
        let isCQ = type.hasPrefix("CQ")
        let variant = isCQ ? (JS8Command.cqStrings.firstIndex(of: type) ?? 0) : 0
        var grid: String?
        if let g = m.group("grid", in: line), g.range(of: "^[A-X]{2}[0-9]{2}$", options: .regularExpression) != nil {
            grid = g
        }
        guard let payload = JS8FrameCodec.heartbeat(call: call, grid: grid, isCQ: isCQ, variant: variant) else { return nil }
        return (payload, m.matchedString(in: line).count)
    }

    static func packCompound(_ line: String) -> (payload: [UInt8], consumed: Int)? {
        guard let m = JS8Command.compoundRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let call = m.group("callsign", in: line) else { return nil }
        let cmdText = m.group("cmd", in: line) ?? ""
        let payload: [UInt8]?
        if !cmdText.isEmpty, let cmd = JS8Command.byString(cmdText), cmd.code >= 0 {
            let num = JS8Fields.packNum(m.group("num", in: line) ?? "")
            payload = JS8FrameCodec.compoundDirected(call: call, cmdCode: cmd.code, num: num)
        } else {
            let grid = m.group("grid", in: line)?.trimmingCharacters(in: .whitespaces)
            payload = JS8FrameCodec.compound(call: call, grid: (grid?.isEmpty ?? true) ? nil : grid)
        }
        guard let payload else { return nil }
        return (payload, m.matchedString(in: line).count)
    }

    struct DirectedPack {
        var payloads: [[UInt8]]
        var to: String
        var cmd: String
        var num: String?
        var consumed: Int
    }

    static func packDirected(_ line: String, myCall: String, myGrid: String) -> DirectedPack? {
        guard let m = JS8Command.directedRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let to = m.group("callsign", in: line),
              let cmdText = m.group("cmd", in: line), !cmdText.isEmpty,
              let cmd = JS8Command.byString(cmdText), cmd.code >= 0 else { return nil }
        guard to != myCall, JS8Fields.isValidCallsign(to) else { return nil }
        let numText = m.group("num", in: line)?.trimmingCharacters(in: .whitespaces)
        let num = JS8Fields.packNum(numText ?? "")
        let consumed = m.matchedString(in: line).count
        // The sender's own call goes the compound route whenever it has a
        // suffix/prefix (KN4CRD/P included); the destination only when it
        // can't be packed as a standard call
        let myCompound = (myCall.contains("/") || !JS8Fields.isStandardCallsign(myCall)) && JS8Fields.isCompoundCallsign(myCall)
        let toCompound = !JS8Fields.isStandardCallsign(to) && JS8Fields.isCompoundCallsign(to)
        var payloads: [[UInt8]] = []
        if !myCompound, !toCompound {
            guard let p = JS8FrameCodec.directed(from: myCall, to: to, cmdCode: cmd.code, num: num) else { return nil }
            payloads = [p]
        } else {
            guard let c = JS8FrameCodec.compound(call: myCall, grid: myGrid.isEmpty ? nil : myGrid),
                  let d = JS8FrameCodec.compoundDirected(call: to, cmdCode: cmd.code, num: num) else { return nil }
            payloads = [c, d]
        }
        return DirectedPack(payloads: payloads, to: to, cmd: cmd.canonical, num: numText, consumed: consumed)
    }

    /// Normal: the better of Huffman and JSC (JSC wins ties); other speeds:
    /// JSC fast data. Without a word table only Huffman is available.
    static func packData(_ line: String, mode: DigiMode, dictionary: JS8Dictionary?) -> (payload: [UInt8], consumed: Int)? {
        if mode == .js8 {
            let huff = JS8FrameCodec.dataHuffman(line)
            let jsc = dictionary.flatMap { JS8FrameCodec.dataCompressed(line, dictionary: $0) }
            switch (huff, jsc) {
            case (nil, nil): return nil
            case (let h?, nil): return h
            case (nil, let j?): return j
            case (let h?, let j?): return j.consumed >= h.consumed ? j : h
            }
        }
        guard let dictionary else { return nil }
        return JS8FrameCodec.fastData(line, dictionary: dictionary)
    }

    private static func leadingStandardCall(_ line: String) -> String? {
        guard let first = line.split(separator: " ").first else { return nil }
        let token = String(first)
        return JS8Fields.isStandardCallsign(token) ? token : nil
    }
}

extension String {
    func lstripped() -> String {
        String(drop(while: { $0 == " " }))
    }

    func rstripped() -> String {
        var s = Substring(self)
        while s.last == " " { s = s.dropLast() }
        return String(s)
    }
}
