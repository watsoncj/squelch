import SwiftUI

/// The single TX/session status surface (map top-left). Priority:
/// transmitting (red, Halt) → armed auto-answer (orange, Cancel) →
/// active sequencer session (blue/green, Stop) → TX error (dismissable).
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
            transmittingPanel
        } else if let pending = model.pendingReply {
            pendingPanel(pending)
        } else if sequencer.mode != .idle {
            sessionPanel
        } else if let error = transmit.txError {
            errorPanel(error)
        }
    }

    // MARK: - States

    private var transmittingPanel: some View {
        panel(tint: .red, prominent: true) {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                VStack(alignment: .leading, spacing: 2) {
                    Text(transmit.isTuning ? "TUNING" : "TRANSMITTING")
                        .font(.callout.weight(.heavy))
                    if !transmit.isTuning, !transmit.currentTXText.isEmpty {
                        Text(transmit.currentTXText)
                            .font(.caption.monospaced())
                    } else if sequencer.mode != .idle {
                        Text(sequencer.stateDescription)
                            .font(.caption)
                    }
                }
                Button("Halt TX") {
                    model.haltTX()
                }
                .keyboardShortcut(.space, modifiers: [])
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.3))
            }
            .foregroundStyle(.white)
        }
    }

    private func pendingPanel(_ pending: PendingReply) -> some View {
        panel(tint: .orange) {
            HStack(spacing: 8) {
                Image(systemName: "phone.arrow.down.left.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(pending.call) is calling you")
                        .font(.callout.bold())
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        let remaining = pending.fireAt.timeIntervalSince(context.date)
                        Text(remaining > 0
                             ? String(format: "answering in %.0f s", remaining.rounded(.up))
                             : "answering at next slot…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Button("Cancel") {
                    model.cancelPendingReply()
                }
                .keyboardShortcut(.space, modifiers: [])
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var sessionPanel: some View {
        panel(tint: sequencer.mode == .cqLoop ? .blue : .green) {
            HStack(spacing: 8) {
                Image(systemName: sequencer.mode == .cqLoop ? "megaphone.fill" : "person.line.dotted.person.fill")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.callout.bold())
                        if let partner = sequencer.currentPartner,
                           let country = CallsignCountry.lookup(partner) {
                            Text("\(country.flag) \(country.name)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        Text(sequencer.stateDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        nextTXCountdown
                    }
                }
                Button("Stop") {
                    model.haltTX()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func errorPanel(_ error: String) -> some View {
        panel(tint: .orange) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .lineLimit(3)
                    .frame(maxWidth: 320, alignment: .leading)
                Button {
                    transmit.txError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
            }
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
            Label(String(format: "TX in %.0f s", remaining.rounded(.up)), systemImage: "timer")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func panel<Content: View>(tint: Color, prominent: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                prominent ? AnyShapeStyle(tint) : AnyShapeStyle(.thinMaterial),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint.opacity(prominent ? 0 : 0.6), lineWidth: 1.5)
            )
            .shadow(radius: prominent ? 4 : 0)
            .padding(10)
    }
}
