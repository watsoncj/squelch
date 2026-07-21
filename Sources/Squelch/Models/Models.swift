import Foundation
import CoreLocation

/// One decoded FT8 transmission.
struct DecodedMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let slotStart: Date        // UTC start of the 15 s slot
    let snr: Float             // approximate SNR, dB
    let timeOffset: Float      // signal start offset within the slot, s
    let audioFrequency: Float  // offset within the audio passband, Hz
    let dialFrequencyMHz: Double
    let text: String
    let callsign: String?      // sender, if parseable
    let grid: String?
    let latitude: Double?
    let longitude: Double?
    let distanceKm: Double?    // from my location at time of decode

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isCQ: Bool { text.hasPrefix("CQ ") }

    /// The station this message is calling (first token), derived from the
    /// text so it also works for records logged before this field existed.
    var addressee: String? {
        FT8MessageParser.parse(text).addressee
    }

    /// Sender's country by callsign prefix, when recognizable.
    var country: CallsignCountry.Info? {
        callsign.flatMap(CallsignCountry.lookup)
    }

    /// Third token of a directed message ("EN52", "-05", "RR73", …).
    var payloadToken: String {
        let tokens = text.uppercased().split(separator: " ").map(String.init)
        return tokens.count >= 3 ? tokens[2] : ""
    }

    /// Can Reply start/continue an exchange from this message? True for any
    /// CQ, and for messages calling `myCall` — except sign-offs, which
    /// carry nothing to answer.
    func isAnswerable(by myCall: String) -> Bool {
        guard callsign != nil else { return false }
        if isCQ { return true }
        guard addressee == myCall.uppercased() else { return false }
        return !QSOSequencer.isSignoff(payloadToken)
    }

    /// Even (0) or odd (1) slot for the given slot period (15 s FT8,
    /// 7.5 s FT4); QSO partners alternate parity.
    func slotParity(slotSeconds: Double) -> Int {
        Int(slotStart.timeIntervalSince1970 / slotSeconds) % 2
    }

    func mentions(_ callsign: String) -> Bool {
        guard !callsign.isEmpty else { return false }
        return text.uppercased()
            .split(separator: " ")
            .contains(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) == callsign.uppercased() })
    }
}

extension DecodedMessage {
    /// Human reading of the message for the feed's second line:
    /// "Calling CQ from EN53", "→ W5TSU: report −17", "→ you: RR73 · QSO complete".
    /// Falls back to the raw text when the grammar doesn't match.
    func feedSummary(myCall: String) -> String {
        let upper = text.uppercased()
        let tokens = upper.split(separator: " ").map(String.init)

        if upper.hasPrefix("TX WSPR") {
            return "WSPR beacon transmission"
        }
        if upper.hasPrefix("WSPR ") {
            let power = tokens.first { $0.hasSuffix("DBM") }
                .map { $0.replacingOccurrences(of: "DBM", with: " dBm") }
            return "WSPR beacon" + (power.map { " · \($0)" } ?? "")
        }
        if isCQ {
            let parsed = FT8MessageParser.parse(text)
            // "CQ DX CALL GRID" — the modifier is whatever sits between CQ
            // and the sender's call
            var summary = "Calling CQ"
            if tokens.count >= 2, let sender = parsed.sender, tokens[1] != sender {
                summary += " \(tokens[1])"
            }
            if let grid {
                summary += " from \(grid.uppercased())"
            }
            return summary
        }
        guard let addr = addressee else { return text }
        let target = addr == myCall.uppercased() ? "you" : addr
        let payload = payloadToken
        let described: String
        if Maidenhead.isValidGrid(payload) {
            described = "grid \(payload)"
        } else if payload.range(of: #"^[+-]\d{1,2}$"#, options: .regularExpression) != nil {
            described = "report \(payload.replacingOccurrences(of: "-", with: "−"))"
        } else if payload.range(of: #"^R[+-]\d{1,2}$"#, options: .regularExpression) != nil {
            described = "roger, report \(String(payload.dropFirst()).replacingOccurrences(of: "-", with: "−"))"
        } else if payload == "RRR" {
            described = "roger-roger"
        } else if payload == "RR73" {
            described = "RR73 · QSO complete"
        } else if payload == "73" {
            described = "73"
        } else if payload.isEmpty {
            return text
        } else {
            described = payload
        }
        return "→ \(target): \(described)"
    }
}

/// A station we've heard, aggregated across decodes. One map pin each.
struct Station: Identifiable {
    let callsign: String
    var grid: String
    var coordinate: CLLocationCoordinate2D
    var firstHeard: Date
    var lastHeard: Date
    var lastSNR: Float
    var heardCount: Int
    var distanceKm: Double?

    var id: String { callsign }
}
