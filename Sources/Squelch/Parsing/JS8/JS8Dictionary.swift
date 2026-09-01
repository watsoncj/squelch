import Foundation

/// The JSC word table: 262,144 entries ranked by frequency. Rank is what
/// travels on the air, so the table must match JS8Call's byte for byte.
/// It is not shipped with Squelch — it's loaded from a file the operator
/// installs (JS8Call's `JSC_map.cpp`, or the compact cache written from
/// it). See `Scripts/fetch_js8_dictionary.sh`.
final class JS8Dictionary {
    static let expectedCount = 262_144
    static let maxWordLength = 26

    /// rank → word (nil for ranks absent from a sparse test table)
    let words: [String?]
    /// rank → recorded size, only where it differs from the word's length
    let oddSizes: [Int: Int]
    private let rankByWord: [String: Int]

    init(words: [String?], oddSizes: [Int: Int] = [:]) {
        self.words = words
        self.oddSizes = oddSizes
        var m: [String: Int] = [:]
        m.reserveCapacity(words.count)
        // Encoder side: only entries whose recorded size is their length
        // are matchable (JS8Call's own encoder can't reach the others)
        for (rank, w) in words.enumerated() {
            guard let w, oddSizes[rank] == nil, m[w] == nil else { continue }
            m[w] = rank
        }
        rankByWord = m
    }

    /// A sparse table for tests: known ranks only.
    convenience init(sparse: [Int: String]) {
        let maxRank = sparse.keys.max() ?? -1
        var arr = [String?](repeating: nil, count: maxRank + 1)
        for (rank, w) in sparse { arr[rank] = w }
        self.init(words: arr)
    }

    var isComplete: Bool { words.count == Self.expectedCount }

    func word(at rank: Int) -> String? {
        rank < words.count ? words[rank] : nil
    }

    func rank(of word: String) -> Int? {
        rankByWord[word]
    }

    /// Longest table entry that is a prefix of `text` (from its start).
    func longestPrefix(of text: Substring) -> (rank: Int, length: Int)? {
        let chars = Array(text.prefix(Self.maxWordLength))
        var len = chars.count
        while len > 0 {
            if let r = rankByWord[String(chars[0..<len])] {
                return (r, len)
            }
            len -= 1
        }
        return nil
    }

    // MARK: Loading

    enum LoadError: Error, LocalizedError {
        case unreadable(URL)
        case badTable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url): return "Can't read \(url.lastPathComponent)"
            case .badTable(let why): return "JS8 word table is invalid: \(why)"
            }
        }
    }

    /// Load from either the compact cache (`.txt`) or JS8Call's
    /// `JSC_map.cpp` source table.
    static func load(from url: URL) throws -> JS8Dictionary {
        guard let data = try? Data(contentsOf: url) else { throw LoadError.unreadable(url) }
        if url.pathExtension.lowercased() == "cpp" {
            return try parseCppTable(data)
        }
        return try parseCompact(data)
    }

    /// Compact cache: one entry per line in rank order, `word` or
    /// `word\tsize` when the recorded size differs. Control characters
    /// and non-ASCII are written as `\uXXXX`.
    func compactRepresentation() -> Data {
        var out = ""
        out.reserveCapacity(words.count * 8)
        for (rank, w) in words.enumerated() {
            out += Self.escape(w ?? "")
            if let size = oddSizes[rank] { out += "\t\(size)" }
            out += "\n"
        }
        return Data(out.utf8)
    }

    static func parseCompact(_ data: Data) throws -> JS8Dictionary {
        guard let text = String(data: data, encoding: .utf8) else { throw LoadError.badTable("not UTF-8") }
        var words: [String?] = []
        words.reserveCapacity(expectedCount)
        var odd: [Int: Int] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty && words.count >= expectedCount { continue }
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let word = unescape(String(parts[0]))
            if parts.count == 2, let size = Int(parts[1]) { odd[words.count] = size }
            words.append(word)
        }
        guard words.count == expectedCount else { throw LoadError.badTable("\(words.count) entries, expected \(expectedCount)") }
        return JS8Dictionary(words: words, oddSizes: odd)
    }

    /// Parse the C initializer `{"WORD", size, rank},` lines. Bytes are
    /// Latin-1 (accented letters appear as `\xNN`).
    static func parseCppTable(_ data: Data) throws -> JS8Dictionary {
        let bytes = [UInt8](data)
        var words = [String?](repeating: nil, count: expectedCount)
        var odd: [Int: Int] = [:]
        var i = 0
        let n = bytes.count
        var seen = 0
        while i < n {
            // Skip comments
            if bytes[i] == UInt8(ascii: "/"), i + 1 < n {
                if bytes[i + 1] == UInt8(ascii: "/") {
                    while i < n, bytes[i] != UInt8(ascii: "\n") { i += 1 }
                    continue
                }
                if bytes[i + 1] == UInt8(ascii: "*") {
                    i += 2
                    while i + 1 < n, !(bytes[i] == UInt8(ascii: "*") && bytes[i + 1] == UInt8(ascii: "/")) { i += 1 }
                    i += 2
                    continue
                }
            }
            guard bytes[i] == UInt8(ascii: "{"), i + 1 < n, bytes[i + 1] == UInt8(ascii: "\"") else {
                i += 1
                continue
            }
            // String literal
            i += 2
            var scalars: [UInt8] = []
            while i < n, bytes[i] != UInt8(ascii: "\"") {
                if bytes[i] == UInt8(ascii: "\\"), i + 1 < n {
                    let e = bytes[i + 1]
                    switch e {
                    case UInt8(ascii: "n"): scalars.append(10); i += 2
                    case UInt8(ascii: "t"): scalars.append(9); i += 2
                    case UInt8(ascii: "r"): scalars.append(13); i += 2
                    case UInt8(ascii: "\\"): scalars.append(92); i += 2
                    case UInt8(ascii: "\""): scalars.append(34); i += 2
                    case UInt8(ascii: "'"): scalars.append(39); i += 2
                    case UInt8(ascii: "x"):
                        var j = i + 2
                        var v = 0
                        while j < n, let h = hexValue(bytes[j]), j < i + 4 { v = v * 16 + h; j += 1 }
                        scalars.append(UInt8(v & 0xFF))
                        i = j
                    default:
                        scalars.append(e); i += 2
                    }
                } else {
                    scalars.append(bytes[i]); i += 1
                }
            }
            i += 1 // closing quote
            // , size , rank }
            var numbers: [Int] = []
            var current: Int? = nil
            while i < n, bytes[i] != UInt8(ascii: "}") {
                let b = bytes[i]
                if b >= 48, b <= 57 {
                    current = (current ?? 0) * 10 + Int(b - 48)
                } else if let c = current {
                    numbers.append(c)
                    current = nil
                    if b == UInt8(ascii: "/") { // comment inside the tuple
                        if i + 1 < n, bytes[i + 1] == UInt8(ascii: "*") {
                            i += 2
                            while i + 1 < n, !(bytes[i] == UInt8(ascii: "*") && bytes[i + 1] == UInt8(ascii: "/")) { i += 1 }
                            i += 1
                        }
                    }
                } else if b == UInt8(ascii: "/"), i + 1 < n, bytes[i + 1] == UInt8(ascii: "*") {
                    i += 2
                    while i + 1 < n, !(bytes[i] == UInt8(ascii: "*") && bytes[i + 1] == UInt8(ascii: "/")) { i += 1 }
                    i += 1
                }
                i += 1
            }
            if let c = current { numbers.append(c) }
            guard numbers.count == 2 else { continue }
            let (size, rank) = (numbers[0], numbers[1])
            guard rank >= 0, rank < expectedCount else { throw LoadError.badTable("rank \(rank) out of range") }
            let word = String(scalars.map { Character(UnicodeScalar($0)) })
            words[rank] = word
            if size != word.count { odd[rank] = size }
            seen += 1
        }
        guard seen == expectedCount, !words.contains(nil) else {
            throw LoadError.badTable("parsed \(seen) of \(expectedCount) entries")
        }
        return JS8Dictionary(words: words, oddSizes: odd)
    }

    private static func hexValue(_ b: UInt8) -> Int? {
        switch b {
        case 48...57: return Int(b - 48)
        case 65...70: return Int(b - 55)
        case 97...102: return Int(b - 87)
        default: return nil
        }
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            if u.value < 32 || u.value > 126 || u == "\\" {
                out += String(format: "\\u%04x", u.value)
            } else {
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("\\u") else { return s }
        var out = ""
        var chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 5 < chars.count + 0, i + 5 <= chars.count - 1 + 1, chars[i + 1] == "u",
               let v = UInt32(String(chars[i + 2..<i + 6]), radix: 16), let u = UnicodeScalar(v) {
                out.unicodeScalars.append(u)
                i += 6
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        chars.removeAll()
        return out
    }

    // MARK: Installed table

    /// Where the operator's copy lives.
    static var installedURL: URL {
        squelchSupportDirectory().appendingPathComponent("js8-words.txt")
    }

    /// Loaded once per process; nil when no table is installed.
    private static var cached: JS8Dictionary?
    private static var cacheChecked = false
    private static let lock = NSLock()

    /// A raw `JSC_map.cpp` dropped next to the cache (by the fetch script)
    /// is converted on first use.
    static var sourceURL: URL {
        squelchSupportDirectory().appendingPathComponent("JSC_map.cpp")
    }

    static var installed: JS8Dictionary? {
        lock.lock(); defer { lock.unlock() }
        if !cacheChecked {
            cacheChecked = true
            if let d = try? load(from: installedURL) {
                cached = d
            } else if let d = try? load(from: sourceURL), d.isComplete {
                try? d.compactRepresentation().write(to: installedURL, options: .atomic)
                cached = d
            }
        }
        return cached
    }

    /// Install from a `JSC_map.cpp` (or compact) file: parses, validates,
    /// writes the compact cache and makes it the active table.
    @discardableResult
    static func install(from source: URL) throws -> JS8Dictionary {
        let dict = try load(from: source)
        guard dict.isComplete else { throw LoadError.badTable("incomplete") }
        try dict.compactRepresentation().write(to: installedURL, options: .atomic)
        lock.lock()
        cached = dict
        cacheChecked = true
        lock.unlock()
        return dict
    }

    static func setInstalled(_ dict: JS8Dictionary?) {
        lock.lock()
        cached = dict
        cacheChecked = true
        lock.unlock()
    }
}
