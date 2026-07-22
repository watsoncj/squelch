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

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
        .animation(nil, value: fraction)
    }
}

/// The single TX/session status surface — a compact chip that lives in the
/// toolbar, left of the frequency selector. Priority: transmitting (red,
/// Halt) → armed auto-answer (orange, Cancel) → active sequencer session
/// (blue/green, Stop) → armed WSPR beacon → TX error (dismissable).
struct QSOStatusPanel: View {
    @ObservedObject var sequencer: QSOSequencer
    @ObservedObject var transmit: TransmitController
    @ObservedObject var model: AppModel
    @ObservedObject var controller: DecodeController
    @AppStorage(SettingsKeys.digiMode) private var digiMode = DigiMode.ft8.rawValue

    private var period: Double {
        (DigiMode(rawValue: digiMode) ?? .ft8).slotSeconds
    }

    var body: some View {
        if transmit.anyTXActive {
            transmittingChip
        } else if let pending = model.pendingReply {
            pendingChip(pending)
        } else if sequencer.mode != .idle {
            sessionChip
        } else if model.wsprBeaconEnabled {
            beaconChip
        } else if let error = transmit.txError {
            errorChip(error)
        } else if controller.isRunning {
            decodingChip
        }
    }

    /// Lowest priority: a radial ring filling over the decode slot.
    /// Deliberately minimal — input level lives in Settings › Audio Input.
    private var decodingChip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let fraction = context.date.timeIntervalSince1970
                .truncatingRemainder(dividingBy: period) / period
            SlotRing(fraction: fraction)
        }
        .padding(.horizontal, 6)
        .help("Decoding — the ring fills over the \(digiMode) slot")
    }

    // MARK: - States

    private var transmittingChip: some View {
        chip(tint: .red, prominent: true) {
            // Static icon on purpose: a repeating symbolEffect inside the
            // toolbar re-commits the whole window every frame (main thread
            // spent 44% blocked in CA commit waits — sluggish scrolling)
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.red)
            Text(transmit.isTuning
                 ? "TUNING"
                 : (transmit.currentTXText.isEmpty ? "TRANSMITTING" : transmit.currentTXText))
                .font(.callout.weight(.semibold).monospaced())
            // Plain bordered: a prominent red tint here bleeds across the
            // whole toolbar glass container and drowns the text
            Button("Halt") {
                model.haltTX()
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.bordered)
            .foregroundStyle(.red)
            .controlSize(.small)
        }
        .help(sequencer.mode != .idle ? sequencer.stateDescription : "Transmitting — Halt with Space")
    }

    private func pendingChip(_ pending: PendingReply) -> some View {
        chip(tint: .orange) {
            Image(systemName: "phone.arrow.down.left.fill")
                .foregroundStyle(.orange)
            Text("\(pending.call) calling · answering in")
                .font(.callout)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, pending.fireAt.timeIntervalSince(context.date).rounded(.up))
                counterText(Int(remaining))
                    .font(.callout)
            }
            Button("Cancel") {
                model.cancelPendingReply()
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var sessionChip: some View {
        chip(tint: sequencer.mode == .cqLoop ? .blue : .green) {
            Image(systemName: sequencer.mode == .cqLoop ? "megaphone.fill" : "person.line.dotted.person.fill")
                .foregroundStyle(sequencer.mode == .cqLoop ? .blue : .green)
            Text(title)
                .font(.callout.weight(.semibold))
            nextTXCountdown
            Button("Stop") {
                model.haltTX()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .help(sequencer.stateDescription)
    }

    private var beaconChip: some View {
        chip(tint: model.beaconNextWindowWillTX ? .orange : .blue) {
            Image(systemName: "dot.radiowaves.up.forward")
                .foregroundStyle(model.beaconNextWindowWillTX ? .orange : .blue)
            Text(model.beaconNextWindowWillTX ? "Beacon: TX next window ·" : "Beacon armed ·")
                .font(.callout)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let period = DigiMode.wspr.slotSeconds
                let remaining = Int((period - context.date.timeIntervalSince1970
                    .truncatingRemainder(dividingBy: period)).rounded(.down))
                counterText(remaining)
                    .font(.callout)
            }
            if !model.beaconNextWindowWillTX {
                Button("TX next") {
                    model.forceBeaconNextWindow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button("Stop") {
                model.setWSPRBeacon(false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .help("WSPR beacon — duty cycle in Settings")
    }

    private func errorChip(_ error: String) -> some View {
        chip(tint: .orange) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 280)
                .help(error)
            Button {
                transmit.txError = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Pieces

    private var title: String {
        switch sequencer.mode {
        case .cqLoop: return "Calling CQ"
        case .qsoAsCaller, .qsoAsAnswerer: return "QSO with \(sequencer.currentPartner ?? "…")"
        case .idle: return ""
        }
    }

    private var nextTXCountdown: some View {
        HStack(spacing: 3) {
            Text("TX in")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let next = QSOSequencer.nextTXWindow(
                    parity: sequencer.txParity,
                    period: period,
                    after: context.date,
                    minLead: 0
                )
                let remaining = next.timeIntervalSince(context.date)
                Text(String(format: "%.0f s", remaining.rounded(.up)))
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Content only — the toolbar's native glass container provides the
    /// chrome; drawing our own background/border doubled it up.
    private func chip<Content: View>(tint: Color, prominent: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .padding(.leading, 8) // breathing room between capsule edge and icon
        .padding(.trailing, 2)
    }

    /// Fixed-width seconds counter so ticking never changes the chip width.
    private func counterText(_ seconds: Int) -> some View {
        Text("\(seconds) s")
            .monospacedDigit()
            .frame(width: 42, alignment: .trailing)
    }
}
