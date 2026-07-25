import SwiftUI

/// Docked card of WSPRnet reports of OUR beacon — who heard us, the mirror
/// image of the feed. Deliberately its own surface (not feed rows): these
/// arrive minutes late from the internet, not from the radio, and mixing
/// them into the decode timeline would read as things we received.
/// Purple is the "heard you" accent here and on the map's report cells.
struct BeaconReportsView: View {
    @ObservedObject var wsprNet: WSPRNetService
    var onClose: () -> Void

    @AppStorage(SettingsKeys.distanceUnit) private var distanceUnitRaw = DistanceUnit.miles.rawValue
    @State private var ageNow = Date()

    private static let ageTick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var reporters: [BeaconReporter] {
        WSPRNetService.aggregate(wsprNet.reports)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if reporters.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(reporters) { reporter in
                            row(reporter)
                        }
                    }
                    .padding(12)
                }
                .bottomFadeBar()
            }
        }
        .onReceive(Self.ageTick) { ageNow = $0 }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.title3)
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text("Heard your beacon")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.65))
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(12)
    }

    private var subtitle: String {
        if let error = wsprNet.fetchError {
            return error
        }
        let count = reporters.count
        let stations = count == 1 ? "1 station" : "\(count) stations"
        return "\(stations) · last \(WSPRNetService.queryHours) h · via WSPRnet"
    }

    /// Reports lag the transmission by a few minutes (reporters upload
    /// after their own decode cycle) — say so instead of looking broken.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No reports yet")
                .font(.callout.weight(.semibold))
            Text("Spots appear on WSPRnet a few minutes after a transmission is heard.")
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.7))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    private func row(_ reporter: BeaconReporter) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(CallsignCountry.lookup(reporter.callsign)?.flag ?? " ")
                Text(reporter.callsign)
                    .font(.body.monospaced().bold())
                Text(reporter.grid)
                    .font(.callout.monospaced())
                    .foregroundStyle(.primary.opacity(0.65))
                Spacer(minLength: 8)
                Text("\(reporter.lastSNR) dB")
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary.opacity(0.75))
            }
            HStack(spacing: 4) {
                Text(secondLine(reporter))
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(relativeAgeText(for: reporter.lastHeard, now: ageNow))
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.65))
                    .monospacedDigit()
            }
        }
    }

    private func secondLine(_ reporter: BeaconReporter) -> String {
        var parts = [DistanceUnit.current(distanceUnitRaw).text(fromKm: reporter.distanceKm)]
        parts.append(reporter.spotCount == 1 ? "1 spot" : "\(reporter.spotCount) spots")
        if reporter.spotCount > 1, reporter.bestSNR != reporter.lastSNR {
            parts.append("best \(reporter.bestSNR) dB")
        }
        return parts.joined(separator: " · ")
    }
}
