import Foundation

/// Keyless callsign lookup via HamDB.org — a free cached mirror of FCC and
/// Industry Canada license data. Results cache in memory for the session;
/// calls outside US/Canada simply come back missing (QRZ button covers
/// the rest of the world).
final class CallsignDirectory: ObservableObject {
    static let shared = CallsignDirectory()

    struct Entry: Equatable {
        let name: String
        let city: String?
        let state: String?   // "CT"
        let country: String? // "United States" / "Canada"
        let grid: String?    // license-address Maidenhead, e.g. "FN31PR"
        let licenseClass: String?
    }

    enum LookupState: Equatable {
        case pending
        case found(Entry)
        case missing // HamDB answered: no such license
        case failed  // network/service error — NOT the same as missing
    }

    @Published private(set) var lookups: [String: LookupState] = [:]
    private var waiters: [String: [(LookupState) -> Void]] = [:]

    /// Fire (or join) a lookup. `onResult` is called once on the main queue
    /// with the terminal state — immediately if it's already cached.
    func lookup(_ callsign: String, onResult: ((LookupState) -> Void)? = nil) {
        let call = callsign.uppercased()
        guard !call.isEmpty else { return }
        switch lookups[call] {
        case .found, .missing, .failed:
            onResult?(lookups[call]!)
            return
        case .pending:
            if let onResult { waiters[call, default: []].append(onResult) }
            return
        case nil:
            break
        }
        if let onResult { waiters[call, default: []].append(onResult) }
        lookups[call] = .pending
        // A compound call ("W1AW/2", "PJ4/K1ABC") is looked up by its
        // licensed base — the slash form 404s — and the answer is trimmed
        // to what still applies to a station operating away from home
        let target = Self.lookupTarget(call)
        guard let url = URL(string: "https://api.hamdb.org/v1/\(target.base)/json/squelch") else {
            settle(call, .failed)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            let result: LookupState = error != nil ? .failed : Self.trim(Self.classify(data), for: target)
            DispatchQueue.main.async {
                self?.settle(call, result)
            }
        }.resume()
    }

    // MARK: - Compound callsigns

    /// What a compound callsign tells a license lookup: which segment is
    /// the licensed call, and how much of the license record still
    /// describes the station on the air.
    struct LookupTarget: Equatable {
        enum Scope: Equatable {
            /// Plain call, or a suffix that doesn't move the station
            /// (/QRP, /AG…): the whole license record applies.
            case full
            /// Portable within the license's country (/2, /P, /M, /MM,
            /// /AM, /R): name and country hold, address-derived grid,
            /// state and city do not.
            case nameAndCountry
            /// Operating under a foreign prefix (PJ4/K1ABC): only the
            /// name is about the person in front of the radio.
            case nameOnly
        }
        let base: String
        let scope: Scope
    }

    /// Suffixes that qualify the license rather than the location.
    private static let nonLocatingSuffixes: Set<String> = ["QRP", "AG", "AE", "AT", "T", "KT"]

    static func lookupTarget(_ callsign: String) -> LookupTarget {
        let parts = callsign.uppercased().split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return LookupTarget(base: callsign.uppercased(), scope: .full) }
        // The licensed call is the longest callsign-shaped segment; with a
        // prefix form ("PJ4/K1ABC") that's the second one
        let base = parts.max { a, b in
            (FT8MessageParser.isCallsign(a) ? a.count : 0) < (FT8MessageParser.isCallsign(b) ? b.count : 0)
        } ?? parts[0]
        let modifiers = parts.filter { $0 != base }
        if parts[0] != base {
            return LookupTarget(base: base, scope: .nameOnly) // foreign prefix
        }
        if modifiers.allSatisfy({ nonLocatingSuffixes.contains($0) }) {
            return LookupTarget(base: base, scope: .full)
        }
        return LookupTarget(base: base, scope: .nameAndCountry)
    }

    /// Drop the license-address fields a relocated station has outgrown.
    static func trim(_ state: LookupState, for target: LookupTarget) -> LookupState {
        guard case .found(let e) = state, target.scope != .full else { return state }
        return .found(Entry(
            name: e.name,
            city: nil,
            state: nil,
            country: target.scope == .nameAndCountry ? e.country : nil,
            grid: nil,
            licenseClass: e.licenseClass
        ))
    }

    private func settle(_ call: String, _ result: LookupState) {
        lookups[call] = result
        for waiter in waiters.removeValue(forKey: call) ?? [] {
            waiter(result)
        }
    }

    /// Forget a failed lookup so the button can try again.
    func retry(_ callsign: String) {
        lookups.removeValue(forKey: callsign.uppercased())
        lookup(callsign)
    }

    /// FCC operator-class letters, expanded.
    static func className(_ letter: String) -> String? {
        switch letter.uppercased() {
        case "T": return "Technician"
        case "G": return "General"
        case "E": return "Amateur Extra"
        case "A": return "Advanced"
        case "N": return "Novice"
        default: return letter.isEmpty ? nil : letter
        }
    }

    /// A malformed/unexpected payload is a FAILURE (service trouble), only
    /// an explicit HamDB NOT_FOUND answer is a genuine miss.
    static func classify(_ data: Data?) -> LookupState {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hamdb = root["hamdb"] as? [String: Any],
              let cs = hamdb["callsign"] as? [String: Any],
              let call = cs["call"] as? String else { return .failed }
        guard call != "NOT_FOUND" else { return .missing }
        func field(_ key: String) -> String? {
            guard let v = cs[key] as? String, !v.isEmpty, v != "NOT_FOUND" else { return nil }
            return v
        }
        let name = [field("fname"), field("name")]
            .compactMap { $0 }
            .joined(separator: " ")
            .capitalized
        guard !name.isEmpty else { return .missing }
        return .found(Entry(
            name: name,
            city: field("addr2").map { $0.capitalized },
            state: field("state").map { $0.uppercased() },
            country: field("country"),
            grid: field("grid").map { $0.uppercased() }
                .flatMap { Maidenhead.isValidGrid($0) ? $0 : nil },
            licenseClass: field("class").flatMap(className)
        ))
    }
}
