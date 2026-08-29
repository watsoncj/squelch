import Foundation

extension QSORecord {
    /// Fold in license-lookup data. User-entered and on-air values always
    /// win: the name fills only when empty, and a heard 4-char grid only
    /// extends to the lookup's 6-char square when the two agree (a portable
    /// station's real square beats its license address). Returns true if
    /// anything changed.
    ///
    /// In a grid-only contest the grid IS the exchange: a missing one
    /// stays missing, because a license-address grid was never copied on
    /// the air and the log must not claim it was.
    mutating func merge(_ entry: CallsignDirectory.Entry) -> Bool {
        var changed = false
        if name?.isEmpty != false, !entry.name.isEmpty {
            name = entry.name
            changed = true
        }
        if let grid = entry.grid {
            if partnerGrid == nil {
                if !exchangeIsGrid {
                    partnerGrid = grid
                    changed = true
                }
            } else if let heard = partnerGrid, heard.count == 4,
                      grid.hasPrefix(heard), grid != heard {
                partnerGrid = grid
                changed = true
            }
        }
        if state == nil, let s = entry.state {
            state = s
            changed = true
        }
        if country == nil, let c = entry.country {
            country = c
            changed = true
        }
        return changed
    }

    /// Logged under a contest whose exchange is the grid itself (WW Digi,
    /// ARRL VHF) — `partnerGrid` then means "what they sent", nothing else.
    var exchangeIsGrid: Bool {
        CabrilloExporter.exchangeStyle(for: contest) == .gridOnly
    }
}

/// One-pass HamDB enrichment for records logged before lookups existed —
/// fills missing names, states, and grids without touching anything the
/// operator entered. One network request per unique callsign, paced at
/// the same gentle 0.7 s the geocoder uses; session-cached answers apply
/// instantly.
final class QSOBackfiller: ObservableObject {
    struct Progress: Equatable {
        let done: Int
        let total: Int
    }

    @Published private(set) var progress: Progress? // nil = not running

    private static let pacing: TimeInterval = 0.7
    private var cancelled = false

    /// US/Canada records (all HamDB covers) still missing lookup data.
    static func needsBackfill(_ record: QSORecord) -> Bool {
        guard let country = CallsignCountry.lookup(record.partner)?.name,
              country == "USA" || country == "Canada" else { return false }
        return record.name == nil || record.state == nil
    }

    func start(log: QSOLog, directory: CallsignDirectory = .shared) {
        guard progress == nil else { return }
        cancelled = false
        let calls = Set(log.records.filter(Self.needsBackfill).map(\.partner)).sorted()
        guard !calls.isEmpty else { return }
        progress = Progress(done: 0, total: calls.count)
        step(calls: calls, index: 0, log: log, directory: directory)
    }

    func cancel() {
        cancelled = true
    }

    private func step(calls: [String], index: Int, log: QSOLog, directory: CallsignDirectory) {
        guard !cancelled, index < calls.count else {
            progress = nil
            return
        }
        let call = calls[index]
        let wasCached: Bool
        switch directory.lookups[call] {
        case .found, .missing, .failed: wasCached = true
        default: wasCached = false
        }
        directory.lookup(call) { [weak self] result in
            guard let self else { return }
            if case .found(let entry) = result {
                for var record in log.records where record.partner == call {
                    if record.merge(entry) {
                        log.update(record)
                    }
                }
            }
            self.progress = Progress(done: index + 1, total: calls.count)
            // Only real network answers count against the rate; replaying
            // the session cache costs HamDB nothing
            DispatchQueue.main.asyncAfter(deadline: .now() + (wasCached ? 0 : Self.pacing)) {
                self.step(calls: calls, index: index + 1, log: log, directory: directory)
            }
        }
    }
}
