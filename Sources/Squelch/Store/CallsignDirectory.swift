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
        let licenseClass: String?
    }

    enum LookupState: Equatable {
        case pending
        case found(Entry)
        case missing // HamDB answered: no such license
        case failed  // network/service error — NOT the same as missing
    }

    @Published private(set) var lookups: [String: LookupState] = [:]

    func lookup(_ callsign: String) {
        let call = callsign.uppercased()
        guard !call.isEmpty, lookups[call] == nil else { return }
        lookups[call] = .pending
        guard let url = URL(string: "https://api.hamdb.org/v1/\(call)/json/squelch") else {
            lookups[call] = .failed
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            let result: LookupState = error != nil ? .failed : Self.classify(data)
            DispatchQueue.main.async {
                self?.lookups[call] = result
            }
        }.resume()
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
            licenseClass: field("class").flatMap(className)
        ))
    }
}
