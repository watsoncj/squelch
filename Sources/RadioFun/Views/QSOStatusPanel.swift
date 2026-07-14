import SwiftUI

/// Always-visible session status: what the sequencer is doing (CQ loop or
/// QSO in progress), who with, and when the next transmission fires —
/// including the countdown for an armed auto-answer, with cancel.
struct QSOStatusPanel: View {
    @ObservedObject var sequencer: QSOSequencer
    @ObservedObject var model: AppModel
    @AppStorage(SettingsKeys.digiMode) private var digiMode = DigiMode.ft8.rawValue

    private var period: Double {
        (DigiMode(rawValue: digiMode) ?? .ft8).slotSeconds
    }

    var body: some View {
        if let pending = model.pendingReply {
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
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        } else if sequencer.mode != .idle {
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
    }

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

    private func panel<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint.opacity(0.6), lineWidth: 1.5)
            )
            .padding(10)
    }
}
