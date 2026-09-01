import Foundation

/// What one 72-bit frame says, once its header is understood.
enum JS8DecodedFrame: Equatable {
    /// Heartbeat (isCQ false: "@HB HEARTBEAT") or CQ (isCQ true: "@ALLCALL <cq variant>").
    case heartbeat(call: String, grid: String?, isCQ: Bool, variant: Int)
    /// A compound callsign, optionally with a grid, that a following
    /// directed frame's "<....>" placeholder refers to.
    case compound(call: String, grid: String?)
    /// A directed command whose FROM is the preceding compound frame.
    case compoundDirected(to: String, cmd: String, extra: String?)
    case directed(from: String, to: String, cmd: String, extra: String?)
    /// Free text (`compressed`: JSC; otherwise Huffman). `text` is nil when
    /// the frame is JSC but no word table is installed.
    case data(text: String?, compressed: Bool)

    var isCompoundLayout: Bool {
        switch self {
        case .heartbeat, .compound, .compoundDirected: return true
        default: return false
        }
    }

    var isDirected: Bool {
        switch self {
        case .directed, .compoundDirected: return true
        default: return false
        }
    }

    /// Display text exactly as JS8Call renders a lone frame.
    var displayText: String {
        switch self {
        case .heartbeat(let call, let grid, let isCQ, let variant):
            let g = grid ?? ""
            return isCQ ? "\(call): @ALLCALL \(JS8Command.cqString(variant)) \(g) " : "\(call): @HB HEARTBEAT \(g) "
        case .compound(let call, _):
            return "\(call): "
        case .compoundDirected(let to, let cmd, let extra):
            return "\(to)\(cmd)" + (extra.map { " \($0)" } ?? "") + " "
        case .directed(let from, let to, let cmd, let extra):
            return "\(from): \(to)\(cmd)" + (extra.map { " \($0)" } ?? "") + " "
        case .data(let text, _):
            return text ?? ""
        }
    }
}

/// Frame ↔ meaning. Written from the frame-layout description.
enum JS8FrameCodec {
    // MARK: Decode

    static func decode(_ frame: JS8Frame, dictionary: JS8Dictionary? = JS8Dictionary.installed) -> JS8DecodedFrame? {
        var r = JS8BitReader(payload: frame.payload)
        if frame.type.contains(.data) {
            let bits = r.unpaddedRest()
            return .data(text: dictionary.map { JS8JSC.decode(bits, dictionary: $0) }, compressed: true)
        }
        if r.readBit() {
            let compressed = r.readBit()
            let bits = r.unpaddedRest()
            if compressed {
                return .data(text: dictionary.map { JS8JSC.decode(bits, dictionary: $0) }, compressed: true)
            }
            return .data(text: JS8Huffman.decode(bits), compressed: false)
        }
        r = JS8BitReader(payload: frame.payload)
        let type = Int(r.read(3))
        switch type {
        case 0, 1, 2:
            let call50 = r.read(50)
            let upper11 = r.read(11)
            let low5 = r.read(5)
            let bits3 = Int(r.read(3))
            let num = UInt16((upper11 << 5) | low5)
            let call = JS8Fields.unpackAlphaNumeric50(call50)
            guard !call.isEmpty else { return nil }
            if type == 0 {
                let isCQ = num & 0x8000 != 0
                let grid15 = num & 0x7FFF
                let grid = grid15 == JS8Fields.noGrid ? nil : nonEmpty(JS8Fields.unpackGrid(grid15))
                return .heartbeat(call: call, grid: grid, isCQ: isCQ, variant: bits3)
            }
            if type == 1 {
                var grid: String?
                if num <= JS8Fields.gridUpperBound {
                    grid = nonEmpty(JS8Fields.unpackGrid(num))
                }
                return .compound(call: call, grid: grid)
            }
            // compound-directed
            guard num >= JS8Fields.compoundCommandBase, num < JS8Fields.noGrid else {
                return .compound(call: call, grid: num <= JS8Fields.gridUpperBound ? nonEmpty(JS8Fields.unpackGrid(num)) : nil)
            }
            let (code, n) = JS8Fields.unpackCmd(UInt8((num - JS8Fields.compoundCommandBase) & 0xFF))
            guard let cmd = JS8Command.byCode(code) else { return nil }
            let extra: String? = cmd.isSNR ? JS8Fields.formatSNR(Int(n) - 31) : nil
            return .compoundDirected(to: call, cmd: cmd.canonical, extra: extra)
        case 3:
            let from28 = UInt32(r.read(28))
            let to28 = UInt32(r.read(28))
            let cmd5 = Int(r.read(5))
            let p = r.readBit()
            let q = r.readBit()
            let num6 = Int(r.read(6))
            guard let cmd = JS8Command.byCode(cmd5) else { return nil }
            let from = JS8Fields.unpackCallsign(from28, portable: p)
            let to = JS8Fields.unpackCallsign(to28, portable: q)
            var extra: String?
            if num6 != 0 {
                extra = cmd.isSNR ? JS8Fields.formatSNR(num6 - 31) : String(num6 - 31)
            }
            return .directed(from: from, to: to, cmd: cmd.canonical, extra: extra)
        default:
            return nil
        }
    }

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    // MARK: Encode

    private static func compoundLayout(type: UInt64, call: String, num: UInt16, bits3: UInt8) -> [UInt8]? {
        let call50 = JS8Fields.packAlphaNumeric50(call)
        guard call50 != 0 else { return nil }
        var w = JS8BitWriter()
        w.append(type, width: 3)
        w.append(call50, width: 50)
        w.append(UInt64(num >> 5), width: 11)
        w.append(UInt64(num & 0x1F), width: 5)
        w.append(UInt64(bits3 & 7), width: 3)
        return w.payload()
    }

    static func heartbeat(call: String, grid: String?, isCQ: Bool, variant: Int) -> [UInt8]? {
        var num = grid.map(JS8Fields.packGrid) ?? JS8Fields.noGrid
        if isCQ { num |= 0x8000 }
        return compoundLayout(type: 0, call: call, num: num, bits3: UInt8(variant & 7))
    }

    static func compound(call: String, grid: String?) -> [UInt8]? {
        compoundLayout(type: 1, call: call, num: grid.map(JS8Fields.packGrid) ?? JS8Fields.noGrid, bits3: 0)
    }

    static func compoundDirected(call: String, cmdCode: Int, num: UInt8) -> [UInt8]? {
        let packed = JS8Fields.compoundCommandBase + UInt16(JS8Fields.packCmd(code: cmdCode, num: num))
        return compoundLayout(type: 2, call: call, num: packed, bits3: 0)
    }

    static func directed(from: String, to: String, cmdCode: Int, num: UInt8) -> [UInt8]? {
        let (f, p) = JS8Fields.packCallsign(from)
        let (t, q) = JS8Fields.packCallsign(to)
        guard f != 0, t != 0 else { return nil }
        var w = JS8BitWriter()
        w.append(3, width: 3)
        w.append(UInt64(f), width: 28)
        w.append(UInt64(t), width: 28)
        w.append(UInt64(cmdCode & 31), width: 5)
        w.append(p ? 1 : 0, width: 1)
        w.append(q ? 1 : 0, width: 1)
        w.append(UInt64(num & 63), width: 6)
        return w.payload()
    }

    /// Huffman data frame (header "10"). Returns nil when nothing fits.
    static func dataHuffman(_ text: String) -> (payload: [UInt8], consumed: Int)? {
        let (bits, consumed) = JS8Huffman.encode(text, budget: 70)
        guard consumed > 0 else { return nil }
        var w = JS8BitWriter()
        w.append(2, width: 2)
        w.append(bits: bits)
        return (w.paddedPayload(), consumed)
    }

    /// JSC data frame (header "11").
    static func dataCompressed(_ text: String, dictionary: JS8Dictionary) -> (payload: [UInt8], consumed: Int)? {
        let (bits, consumed) = JS8JSC.encode(text, budget: 70, dictionary: dictionary)
        guard consumed > 0 else { return nil }
        var w = JS8BitWriter()
        w.append(3, width: 2)
        w.append(bits: bits)
        return (w.paddedPayload(), consumed)
    }

    /// Fast data frame (no header; the Data transmission flag marks it).
    static func fastData(_ text: String, dictionary: JS8Dictionary) -> (payload: [UInt8], consumed: Int)? {
        let (bits, consumed) = JS8JSC.encode(text, budget: 72, dictionary: dictionary)
        guard consumed > 0 else { return nil }
        var w = JS8BitWriter()
        w.append(bits: bits)
        return (w.paddedPayload(), consumed)
    }
}
