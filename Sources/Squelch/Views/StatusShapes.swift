import SwiftUI

/// Animation-free progress bar: draws in one pass, invalidates nothing.
/// (Gauge/ProgressView animate via AppKit and keep window layout hot.)
struct CapsuleBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule()
                    .fill(tint)
                    .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .animation(nil, value: fraction)
    }
}

/// Radial slot-progress ring; static draws on 1 s ticks, no animation.
struct SlotRing: View {
    let fraction: Double
    var tint: Color = .green

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
        .animation(nil, value: fraction)
    }
}
