import Foundation

/// Hit-testing for the waterfall's inspect mode: the highlight overlay's
/// decode → rectangle projection, inverted. Works in the (frequency,
/// time) domain so the view owns all pixel↔domain conversion. Pure
/// logic, unit-tested.
struct SignalInspector {
    struct Hit {
        let message: DecodedMessage
        /// Other decodes whose boxes also contain the click (overlapping
        /// signals — rare, worth a footnote in the UI)
        let alternates: Int
    }

    struct Miss {
        let frequencyHz: Double
        let time: Date
        /// Closest decode in the clicked slot, and the gap from the click
        /// to the edge of its tone span — "WA5PJA was 180 Hz below"
        let nearestInSlot: DecodedMessage?
        let nearestHzAway: Double?
    }

    enum Result {
        case hit(Hit)
        case miss(Miss)
    }

    /// A transmission occupies [audioFrequency, +toneSpanHz] ×
    /// [slotStart+timeOffset, +transmissionSeconds]; tolerances widen the
    /// box so near-misses on a 50 Hz-wide target still resolve.
    static func inspect(
        frequencyHz: Double,
        time: Date,
        messages: [DecodedMessage],
        slotSeconds: Double,
        transmissionSeconds: Double,
        toneSpanHz: Double = 50,
        toleranceHz: Double = 12,
        toleranceSeconds: TimeInterval = 0.9
    ) -> Result {
        var hits: [(message: DecodedMessage, distance: Double)] = []
        for message in messages {
            let lowHz = Double(message.audioFrequency)
            let start = message.slotStart.addingTimeInterval(TimeInterval(message.timeOffset))
            let dt = time.timeIntervalSince(start)
            guard frequencyHz >= lowHz - toleranceHz,
                  frequencyHz <= lowHz + toneSpanHz + toleranceHz,
                  dt >= -toleranceSeconds,
                  dt <= transmissionSeconds + toleranceSeconds else { continue }
            // Rank overlapping boxes by normalized distance to center
            let dx = (frequencyHz - (lowHz + toneSpanHz / 2)) / toneSpanHz
            let dy = (dt - transmissionSeconds / 2) / transmissionSeconds
            hits.append((message, dx * dx + dy * dy))
        }
        if let best = hits.min(by: { $0.distance < $1.distance }) {
            return .hit(Hit(message: best.message, alternates: hits.count - 1))
        }

        let clickedSlot = (time.timeIntervalSince1970 / slotSeconds).rounded(.down)
        let sameSlot = messages.filter {
            ($0.slotStart.timeIntervalSince1970 / slotSeconds).rounded(.down) == clickedSlot
        }
        func gap(_ message: DecodedMessage) -> Double {
            let low = Double(message.audioFrequency)
            let high = low + toneSpanHz
            if frequencyHz < low { return low - frequencyHz }
            if frequencyHz > high { return frequencyHz - high }
            return 0
        }
        let nearest = sameSlot.min(by: { gap($0) < gap($1) })
        return .miss(Miss(
            frequencyHz: frequencyHz,
            time: time,
            nearestInSlot: nearest,
            nearestHzAway: nearest.map(gap)
        ))
    }
}
