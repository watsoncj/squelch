import Foundation

/// A canonical digital-mode frequency the radio can QSY to.
struct QSYPreset: Identifiable {
    let label: String
    let mhz: Double
    let mode: DigiMode
    var id: String { label }

    /// Standard calling frequencies: 10m first (the workhorse band here),
    /// up through VHF, then down through HF; FT8 → FT4 → JS8 → WSPR within
    /// each band. JS8 rows carry the NORMAL speed; the flyout's speed
    /// picker switches speeds on the same frequency. The transmit/
    /// receive-only split comes from the license class.
    static let all: [QSYPreset] = [
        QSYPreset(label: "10m FT8 — 28.074", mhz: 28.074, mode: .ft8),
        QSYPreset(label: "10m FT4 — 28.180", mhz: 28.180, mode: .ft4),
        QSYPreset(label: "10m JS8 — 28.078", mhz: 28.078, mode: .js8),
        QSYPreset(label: "10m WSPR — 28.1246", mhz: 28.1246, mode: .wspr),
        QSYPreset(label: "6m FT8 — 50.313", mhz: 50.313, mode: .ft8),
        QSYPreset(label: "6m FT4 — 50.318", mhz: 50.318, mode: .ft4),
        QSYPreset(label: "6m WSPR — 50.293", mhz: 50.293, mode: .wspr),
        QSYPreset(label: "2m FT8 — 144.174", mhz: 144.174, mode: .ft8),
        QSYPreset(label: "15m FT8 — 21.074", mhz: 21.074, mode: .ft8),
        QSYPreset(label: "15m FT4 — 21.140", mhz: 21.140, mode: .ft4),
        QSYPreset(label: "15m JS8 — 21.078", mhz: 21.078, mode: .js8),
        QSYPreset(label: "15m WSPR — 21.0946", mhz: 21.0946, mode: .wspr),
        QSYPreset(label: "12m FT4 — 24.919", mhz: 24.919, mode: .ft4),
        QSYPreset(label: "17m FT8 — 18.100", mhz: 18.100, mode: .ft8),
        QSYPreset(label: "17m FT4 — 18.104", mhz: 18.104, mode: .ft4),
        QSYPreset(label: "17m JS8 — 18.104", mhz: 18.104, mode: .js8),
        QSYPreset(label: "20m FT8 — 14.074", mhz: 14.074, mode: .ft8),
        QSYPreset(label: "20m FT4 — 14.080", mhz: 14.080, mode: .ft4),
        QSYPreset(label: "20m JS8 — 14.078", mhz: 14.078, mode: .js8),
        QSYPreset(label: "20m WSPR — 14.0956", mhz: 14.0956, mode: .wspr),
        QSYPreset(label: "30m FT8 — 10.136", mhz: 10.136, mode: .ft8),
        QSYPreset(label: "30m FT4 — 10.140", mhz: 10.140, mode: .ft4),
        QSYPreset(label: "30m JS8 — 10.130", mhz: 10.130, mode: .js8),
        QSYPreset(label: "30m WSPR — 10.1387", mhz: 10.1387, mode: .wspr),
        QSYPreset(label: "40m FT8 — 7.074", mhz: 7.074, mode: .ft8),
        QSYPreset(label: "40m FT4 — 7.0475", mhz: 7.0475, mode: .ft4),
        QSYPreset(label: "40m JS8 — 7.078", mhz: 7.078, mode: .js8),
        QSYPreset(label: "40m WSPR — 7.0386", mhz: 7.0386, mode: .wspr),
        QSYPreset(label: "80m FT8 — 3.573", mhz: 3.573, mode: .ft8),
        QSYPreset(label: "80m FT4 — 3.575", mhz: 3.575, mode: .ft4),
        QSYPreset(label: "80m JS8 — 3.578", mhz: 3.578, mode: .js8),
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
