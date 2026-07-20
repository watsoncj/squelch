import SwiftUI

struct StatusBar: View {
    @ObservedObject var controller: DecodeController
    @ObservedObject var store: DecodeStore
    @ObservedObject var location: LocationProvider
    var sequencer: QSOSequencer? = nil
    var qsoLog: QSOLog? = nil
    var cat: CATController? = nil
    @AppStorage(SettingsKeys.dialFrequencyMHz) private var dialFrequencyMHz = 28.074
    @AppStorage(SettingsKeys.digiMode) private var digiMode = DigiMode.ft8.rawValue

    private var slotPeriod: Double {
        (DigiMode(rawValue: digiMode) ?? .ft8).slotSeconds
    }

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

                // Input level meter (plain capsule: Gauge/ProgressView
                // animate via AppKit and keep whole-window layout running
                // every frame)
                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2")
                    CapsuleBar(fraction: levelFraction, tint: levelFraction > 0.9 ? .red : .green)
                        .frame(width: 90, height: 4)
                }
                .help(String(format: "Input level: %.0f dBFS", controller.audioLevelDB))

                // Slot progress
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let seconds = context.date.timeIntervalSince1970.truncatingRemainder(dividingBy: slotPeriod)
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                        CapsuleBar(fraction: seconds / slotPeriod, tint: .blue)
                            .frame(width: 70, height: 4)
                        Text(String(format: "%04.1fs", seconds))
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                .help("Time within the current \(digiMode) slot (\(String(format: "%g", slotPeriod)) s)")

                if let count = controller.lastSlotCount {
                    Text("Last slot: \(count) decode\(count == 1 ? "" : "s")")
                        .monospacedDigit()
                }
            }

            Spacer()

            Text(String(format: "%@ · %.3f MHz (%@)", digiMode, dialFrequencyMHz, bandName(forMHz: dialFrequencyMHz)))
                .monospacedDigit()

            if let cat {
                if cat.isConnected {
                    Divider().frame(height: 14)
                    Label(cat.radioModeName ?? "CAT", systemImage: "cable.connector")
                        .foregroundStyle(cat.radioModeName == "DATA-USB" ? Color.secondary : Color.orange)
                        .help(cat.radioModeName == "DATA-USB"
                              ? "CAT connected — dial follows the radio"
                              : "CAT connected — radio is in \(cat.radioModeName ?? "?"), not DATA-USB")
                } else if !cat.portPath.isEmpty {
                    Divider().frame(height: 14)
                    Label("CAT", systemImage: "cable.connector.slash")
                        .foregroundStyle(.orange)
                        .help(cat.lastError ?? "CAT not connected — radio off? Retrying automatically.")
                }
            }

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

    /// Animation-free progress bar: draws in one pass, invalidates nothing.
    private struct CapsuleBar: View {
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

}
