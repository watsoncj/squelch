import SwiftUI
import CoreLocation
import AppKit

/// Apple Maps-style detail card for one heard station: identity, stats,
/// worked-before badge, primary Reply action, and the message thread —
/// which is where per-message raw data (exact time, DT, freq) lives.
struct StationDetailView: View {
    let callsign: String
    @ObservedObject var store: DecodeStore
    @ObservedObject var stateResolver: StateResolver
    @ObservedObject var qsoLog: QSOLog
    var location: LocationProvider
    var onClose: () -> Void
    var onReply: ((DecodedMessage) -> Void)? = nil
    var replyEnabled = true

    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = "W0CJW"
    @AppStorage(SettingsKeys.timeDisplay) private var timeDisplayRaw = TimeDisplay.utc.rawValue
    @AppStorage(SettingsKeys.distanceUnit) private var distanceUnitRaw = DistanceUnit.miles.rawValue
    @State private var ageNow = Date()
    @ObservedObject private var directory = CallsignDirectory.shared

    private static let ageTick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var station: Station? { store.stations[callsign] }

    /// Thread: every decode where the station is sender or addressee.
    private var thread: [DecodedMessage] {
        store.messages
            .filter { $0.callsign == callsign || $0.addressee == callsign }
            .prefix(200)
            .map { $0 }
    }

    private var latestAnswerable: DecodedMessage? {
        store.messages.first { $0.callsign == callsign && $0.isAnswerable(by: myCallsign) }
    }

    private var workedBefore: QSORecord? {
        qsoLog.records.first { $0.partner == callsign }
    }

    private var placeText: String? {
        guard let country = CallsignCountry.lookup(callsign) else { return nil }
        if FT8MessageParser.isUSCallsign(callsign),
           let grid = station?.grid,
           let state = stateResolver.state(forGrid: grid, isUS: true) {
            return "\(country.flag) \(state), USA"
        }
        return "\(country.flag) \(country.name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    statStrip
                    if let record = workedBefore {
                        workedBadge(record)
                    }
                    replyButton
                    Divider()
                    threadSection
                }
                .padding(12)
            }
        }
        .onReceive(Self.ageTick) { ageNow = $0 }
        .onAppear { directory.lookup(callsign) }
        .onChange(of: callsign) { _, call in directory.lookup(call) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(callsign)
                    .font(.title2.monospaced().bold())
                HStack(spacing: 6) {
                    if let placeText {
                        Text(placeText)
                    }
                    if let grid = station?.grid {
                        Text(grid.uppercased())
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)

                // HamDB (FCC/ISED) operator info — keyless, cached
                if case .found(let entry) = directory.lookups[callsign.uppercased()] {
                    Text([entry.name,
                          entry.city,
                          entry.licenseClass]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.75))
                }
            }
            Spacer()
            // QRZ web lookup: free, worldwide, no API key — the richest
            // "who is this" answer available for a callsign
            Button {
                if let url = URL(string: "https://www.qrz.com/db/\(callsign)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("QRZ", systemImage: "arrow.up.right.square")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Look up \(callsign) on QRZ.com")

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction) // Esc closes the card
            .help("Close (Esc)")
        }
        .padding(12)
    }

    private var statStrip: some View {
        let unit = DistanceUnit.current(distanceUnitRaw)
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                stat("Distance", station?.distanceKm.map { unit.text(fromKm: $0) } ?? "—")
                stat("Bearing", bearingText ?? "—")
                stat("Last SNR", station.map { String(format: "%+.0f dB", $0.lastSNR) } ?? "—")
            }
            GridRow {
                stat("Heard", station.map { "\($0.heardCount)×" } ?? "—")
                stat("First", station.map { relativeAgeText(for: $0.firstHeard, now: ageNow) } ?? "—")
                stat("Last", station.map { relativeAgeText(for: $0.lastHeard, now: ageNow) } ?? "—")
            }
        }
    }

    private var bearingText: String? {
        guard let me = location.effectiveCoordinate(),
              let them = station?.coordinate else { return nil }
        let deg = Maidenhead.bearingDegrees(from: me, to: them)
        let compass = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                       "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let idx = Int((deg + 11.25) / 22.5) % 16
        return String(format: "%.0f° %@", deg, compass[idx])
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.primary.opacity(0.6))
            Text(value)
                .font(.callout.monospacedDigit())
        }
        .gridColumnAlignment(.leading)
    }

    private func workedBadge(_ record: QSORecord) -> some View {
        Label {
            Text("Worked \(TimeDisplay.current(timeDisplayRaw).dateFormatter.string(from: record.start)) · sent \(record.reportSent)\(record.reportReceived.map { ", got \($0)" } ?? "")")
        } icon: {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
        }
        .font(.callout)
    }

    private var replyButton: some View {
        Group {
            if let message = latestAnswerable, let onReply {
                Button {
                    onReply(message)
                } label: {
                    Label(message.isCQ ? "Reply to CQ" : "Answer", systemImage: "arrowshape.turn.up.left.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!replyEnabled)
                .help(replyEnabled ? "Run the QSO exchange automatically" : "Start decoding (and check TX legality) first")
            }
        }
    }

    private var threadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Messages")
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.6))
            ForEach(thread) { msg in
                VStack(alignment: .leading, spacing: 1) {
                    Text(msg.text)
                        .font(.callout.monospaced())
                        .foregroundStyle(msg.callsign == callsign ? Color.primary : Color.secondary)
                    Text("\(TimeDisplay.current(timeDisplayRaw).logTimestamp(for: msg.slotStart)) · \(String(format: "%+.0f dB · DT %.1f · %.0f Hz", msg.snr, msg.timeOffset, msg.audioFrequency))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.primary.opacity(0.65))
                }
            }
        }
    }
}
