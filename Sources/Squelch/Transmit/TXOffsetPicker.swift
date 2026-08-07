import Foundation

/// Picks a clear TX offset from what the station can actually observe:
/// recent decodes (who owns which frequency, in which slot parity) and
/// the waterfall's averaged spectrum (carriers and QRM that never
/// decode). Pure logic — the wand button on the waterfall is the only
/// caller.
struct TXOffsetPicker {
    /// A recently active station: base frequency of its signal, whether
    /// it transmits in OUR slot parity (nil when our parity is unknown,
    /// e.g. TX idle between hunts), and how long since last heard.
    struct Occupant {
        let frequency: Double
        let sameParity: Bool?
        let age: TimeInterval
    }

    static let signalBandwidthHz = 50.0
    static let guardHz = 10.0
    /// Candidate range keeps the signal plus guard inside the radio's
    /// clean SSB TX passband, away from the filter rolloff at each end.
    static let minOffsetHz = 300.0
    static let maxOffsetHz = 2800.0

    static func pick(
        occupants: [Occupant],
        spectrum: [Float] = [],
        spectrumStartHz: Double = 0,
        spectrumHzPerBin: Double = 1
    ) -> Double {
        var best = 1500.0
        var bestScore = Double.infinity
        var f = minOffsetHz
        while f <= maxOffsetHz {
            let s = score(offset: f, occupants: occupants, spectrum: spectrum,
                          spectrumStartHz: spectrumStartHz, spectrumHzPerBin: spectrumHzPerBin)
            if s < bestScore {
                bestScore = s
                best = f
            }
            f += 10
        }
        return best
    }

    static func score(
        offset f: Double,
        occupants: [Occupant],
        spectrum: [Float],
        spectrumStartHz: Double,
        spectrumHzPerBin: Double
    ) -> Double {
        let lo = f - guardHz
        let hi = f + signalBandwidthHz + guardHz
        var total = 0.0
        for o in occupants where o.frequency + signalBandwidthHz > lo && o.frequency < hi {
            // Same-parity stations collide with us at the partner's
            // receiver; opposite-parity ones QRM the replies that
            // arrive on our frequency. Unknown splits the difference.
            let weight: Double
            switch o.sameParity {
            case .some(true): weight = 3
            case .some(false): weight = 1.5
            case .none: weight = 2
            }
            total += weight * exp(-o.age / 90)
        }
        if !spectrum.isEmpty, spectrumHzPerBin > 0 {
            let b0 = max(0, Int((lo - spectrumStartHz) / spectrumHzPerBin))
            let b1 = min(spectrum.count - 1, Int((hi - spectrumStartHz) / spectrumHzPerBin))
            if b0 <= b1 {
                var sum: Float = 0
                for b in b0...b1 { sum += spectrum[b] }
                total += Double(sum) / Double(b1 - b0 + 1) * 4
            }
        }
        // Gentle pull toward the mid-band so an empty band doesn't put
        // us at a passband edge
        let mid = (f - 1500) / 1300
        total += 0.25 * mid * mid
        return total
    }
}
