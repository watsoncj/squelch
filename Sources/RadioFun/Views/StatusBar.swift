import SwiftUI

struct StatusBar: View {
    @ObservedObject var controller: DecodeController
    @ObservedObject var store: DecodeStore
    @ObservedObject var location: LocationProvider
    var sequencer: QSOSequencer? = nil
    var qsoLog: QSOLog? = nil
    @AppStorage(SettingsKeys.dialFrequencyMHz) private var dialFrequencyMHz = 28.074

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle()
                    .fill(controller.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(controller.statusText)
                    .lineLimit(1)
            }

            if controller.isRunning {
                Divider().frame(height: 14)
                Label(controller.deviceName, systemImage: "waveform")
                    .lineLimit(1)

                // Input level meter
                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2")
                    Gauge(value: levelFraction) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(levelFraction > 0.9 ? .red : .green)
                        .frame(width: 90)
                }
                .help(String(format: "Input level: %.0f dBFS", controller.audioLevelDB))

                // Slot progress
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let seconds = context.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 15)
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                        ProgressView(value: seconds, total: 15)
                            .frame(width: 70)
                        Text(String(format: "%02.0fs", seconds))
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }
                .help("Time within the current 15-second FT8 slot")

                if let count = controller.lastSlotCount {
                    Text("Last slot: \(count) decode\(count == 1 ? "" : "s")")
                        .monospacedDigit()
                }
            }

            Spacer()

            Text(String(format: "Dial %.3f MHz (%@)", dialFrequencyMHz, bandName(dialFrequencyMHz)))
                .monospacedDigit()

            if let grid = location.effectiveGrid {
                Divider().frame(height: 14)
                Label(grid, systemImage: "location")
                    .help(location.systemCoordinate != nil ? "From Location Services" : "From your grid in Settings")
            }

            Divider().frame(height: 14)
            Text("\(store.totalDecodes) decodes · \(store.stations.count) stations")
                .monospacedDigit()

            if let qsoLog, !qsoLog.records.isEmpty {
                Divider().frame(height: 14)
                Label("\(qsoLog.records.count) QSOs", systemImage: "checkmark.seal")
                    .monospacedDigit()
                    .help("Completed contacts, logged to qsos.jsonl")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var levelFraction: Double {
        // Map -60…0 dBFS to 0…1
        min(1, max(0, (Double(controller.audioLevelDB) + 60) / 60))
    }

    private func bandName(_ mhz: Double) -> String {
        switch mhz {
        case 1.8..<2.1: return "160m"
        case 3.5..<4.0: return "80m"
        case 5.0..<5.5: return "60m"
        case 7.0..<7.3: return "40m"
        case 10.1..<10.15: return "30m"
        case 14.0..<14.35: return "20m"
        case 18.0..<18.2: return "17m"
        case 21.0..<21.45: return "15m"
        case 24.8..<25.0: return "12m"
        case 28.0..<29.7: return "10m"
        case 50.0..<54.0: return "6m"
        case 144.0..<148.0: return "2m"
        case 420.0..<450.0: return "70cm"
        default: return "?"
        }
    }
}
