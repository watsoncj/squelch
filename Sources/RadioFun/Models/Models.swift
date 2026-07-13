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
