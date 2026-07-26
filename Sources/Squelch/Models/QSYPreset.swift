import Foundation

/// A canonical digital-mode frequency the radio can QSY to.
struct QSYPreset: Identifiable {
    let label: String
    let mhz: Double
    let mode: DigiMode
    var id: String { label }

    /// Standard calling frequencies: 10m first (the workhorse band here),
    /// up through VHF, then down through HF; FT8 → FT4 → WSPR within each
    /// band. The transmit/receive-only split comes from the license class.
    static let all: [QSYPreset] = [
        QSYPreset(label: "10m FT8 — 28.074", mhz: 28.074, mode: .ft8),
        QSYPreset(label: "10m FT4 — 28.180", mhz: 28.180, mode: .ft4),
        QSYPreset(label: "10m WSPR — 28.1246", mhz: 28.1246, mode: .wspr),
        QSYPreset(label: "6m FT8 — 50.313", mhz: 50.313, mode: .ft8),
        QSYPreset(label: "6m FT4 — 50.318", mhz: 50.318, mode: .ft4),
        QSYPreset(label: "6m WSPR — 50.293", mhz: 50.293, mode: .wspr),
        QSYPreset(label: "2m FT8 — 144.174", mhz: 144.174, mode: .ft8),
        QSYPreset(label: "15m FT8 — 21.074", mhz: 21.074, mode: .ft8),
        QSYPreset(label: "15m WSPR — 21.0946", mhz: 21.0946, mode: .wspr),
        QSYPreset(label: "17m FT8 — 18.100", mhz: 18.100, mode: .ft8),
        QSYPreset(label: "20m FT8 — 14.074", mhz: 14.074, mode: .ft8),
        QSYPreset(label: "20m FT4 — 14.080", mhz: 14.080, mode: .ft4),
        QSYPreset(label: "20m WSPR — 14.0956", mhz: 14.0956, mode: .wspr),
        QSYPreset(label: "40m FT8 — 7.074", mhz: 7.074, mode: .ft8),
        QSYPreset(label: "40m WSPR — 7.0386", mhz: 7.0386, mode: .wspr),
        QSYPreset(label: "80m FT8 — 3.573", mhz: 3.573, mode: .ft8),
    ]

    static func transmitLegal(for license: LicenseClass) -> [QSYPreset] {
        all.filter { license.canTransmitData(mhz: $0.mhz) }
    }

    /// Listening is unrestricted; TX on these stays hard-blocked by the
    /// legality guard.
    static func receiveOnly(for license: LicenseClass) -> [QSYPreset] {
        all.filter { !license.canTransmitData(mhz: $0.mhz) }
    }
}
