import SwiftUI

/// The single TX/session status surface — a compact chip that lives in the
/// toolbar, left of the frequency selector. Priority: transmitting (red,
/// Halt) → armed auto-answer (orange, Cancel) → active sequencer session
/// (blue/green, Stop) → armed WSPR beacon → TX error (dismissable).
struct QSOStatusPanel: View {
    @ObservedObject var sequencer: QSOSequencer
    @ObservedObject var transmit: TransmitController
    @ObservedObject var model: AppModel
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
        }
    }

    // MARK: - States

    private var transmittingChip: some View {
        chip(tint: .red, prominent: true) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text(transmit.isTuning
                 ? "TUNING"
                 : (transmit.currentTXText.isEmpty ? "TRANSMITTING" : transmit.currentTXText))
                .font(.callout.weight(.semibold).monospaced())
            Button("Halt") {
                model.haltTX()
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.3))
            .controlSize(.small)
        }
        .foregroundStyle(.white)
        .help(sequencer.mode != .idle ? sequencer.stateDescription : "Transmitting — Halt with Space")
    }

    private func pendingChip(_ pending: PendingReply) -> some View {
        chip(tint: .orange) {
            Image(systemName: "phone.arrow.down.left.fill")
                .foregroundStyle(.orange)
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let remaining = pending.fireAt.timeIntervalSince(context.date)
                Text(remaining > 0
                     ? String(format: "%@ calling · answering in %.0f s", pending.call, remaining.rounded(.up))
                     : "\(pending.call) calling · answering at next slot…")
                    .font(.callout)
                    .monospacedDigit()
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
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let period = DigiMode.wspr.slotSeconds
                let remaining = Int((period - context.date.timeIntervalSince1970
                    .truncatingRemainder(dividingBy: period)).rounded(.down))
                Text(model.beaconNextWindowWillTX
                     ? "Beacon: TX next window · \(remaining) s"
                     : "Beacon armed · \(remaining) s")
                    .font(.callout)
                    .monospacedDigit()
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
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let next = QSOSequencer.nextTXWindow(
                parity: sequencer.txParity,
                period: period,
                after: context.date,
                minLead: 0
            )
            let remaining = next.timeIntervalSince(context.date)
            Text(String(format: "TX in %.0f s", remaining.rounded(.up)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func chip<Content: View>(tint: Color, prominent: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            prominent ? AnyShapeStyle(tint) : AnyShapeStyle(.thinMaterial),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(prominent ? 0 : 0.6), lineWidth: 1)
        )
    }
}
