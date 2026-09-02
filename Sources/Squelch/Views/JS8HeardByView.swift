import SwiftUI

/// Who acknowledged our heartbeats — the payoff panel for the auto
/// heartbeat: each row is a station's live report of our signal.
struct JS8HeardByView: View {
    @ObservedObject var js8: JS8Session
    let onClose: () -> Void

    @State private var ageNow = Date()
    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Heard by", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide (reappears after the next heartbeat acknowledgement)")
            }
            ForEach(js8.heardBy.prefix(8)) { h in
                HStack(spacing: 8) {
                    Text(h.call)
                        .font(.callout.monospaced().bold())
                        .frame(width: 90, alignment: .leading)
                    Text("\(h.report) dB")
                        .font(.callout.monospaced())
                        .foregroundStyle(reportColor(h.report))
                    Spacer()
                    Text(relativeAgeText(for: h.at, now: ageNow))
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.6))
                }
            }
            Text("Reports are how these stations hear you — from their acknowledgements of your heartbeats.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .onReceive(tick) { ageNow = $0 }
    }

    private func reportColor(_ report: String) -> Color {
        guard let v = Int(report.replacingOccurrences(of: "+", with: "")) else { return .primary }
        if v >= -5 { return .green }
        if v >= -15 { return .primary }
        return .orange
    }
}
