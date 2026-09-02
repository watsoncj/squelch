import SwiftUI
import CoreLocation

extension View {
    /// `.buttonStyle(.link)` is mac-only; borderless reads the same on iPad.
    @ViewBuilder
    func linkButton() -> some View {
        #if os(macOS)
        self.buttonStyle(.link)
        #else
        self.buttonStyle(.borderless)
        #endif
    }
}

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
    /// JS8 mode: send a directed query/message line to this station.
    var onJS8Query: ((String) -> Void)? = nil
    var js8QueryEnabled = false

    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = ""
    @AppStorage(SettingsKeys.activeContest) private var activeContest = ""
    @AppStorage(SettingsKeys.dialFrequencyMHz) private var dialFrequencyMHz = 14.074
    @AppStorage(SettingsKeys.timeDisplay) private var timeDisplayRaw = TimeDisplay.local.rawValue
    @AppStorage(SettingsKeys.distanceUnit) private var distanceUnitRaw = DistanceUnit.miles.rawValue
    @State private var ageNow = Date()
    @ObservedObject private var directory = CallsignDirectory.shared
    @Environment(\.openURL) private var openURL

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

    /// Worked on this band in the current contest context — the same
    /// predicate as the feed's filled seal and the hunter's dupe filter.
    private var isDupeHere: Bool {
        CQHunter.dupeCalls(
            records: qsoLog.records.filter { $0.partner == callsign },
            dialMHz: dialFrequencyMHz,
            contest: activeContest.isEmpty ? nil : activeContest
        ).contains(callsign.uppercased())
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
                    js8QueryRow
                    Divider()
                    threadSection
                }
                .padding(12)
            }
        }
        .onReceive(Self.ageTick) { ageNow = $0 }
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

                // HamDB (FCC/ISED) operator info — fetched only on demand,
                // then cached for the session
                switch directory.lookups[callsign.uppercased()] {
                case .found(let entry):
                    Text([entry.name,
                          entry.city,
                          entry.licenseClass]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.75))
                case .pending:
                    ProgressView()
                        .controlSize(.small)
                case .missing:
                    Text("No US/Canada license record")
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.6))
                case .failed:
                    HStack(spacing: 6) {
                        Text("Lookup failed — offline?")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Retry") {
                            directory.retry(callsign)
                        }
                        .linkButton()
                        .font(.caption)
                    }
                case nil:
                    Button("Look up operator") {
                        directory.lookup(callsign)
                    }
                    .linkButton()
                    .font(.callout)
                    .help("Fetch name, city, and license class from HamDB (FCC/ISED)")
                }
            }
            Spacer()
            // QRZ web lookup: free, worldwide, no API key — the richest
            // "who is this" answer available for a callsign
            Button {
                if let url = URL(string: "https://www.qrz.com/db/\(callsign)") {
                    openURL(url)
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
        return compassBearingText(degrees: Maidenhead.bearingDegrees(from: me, to: them))
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
        let dupe = isDupeHere
        let sent = record.reportSent.isEmpty ? "" : " · sent \(record.reportSent)"
        var text = "Worked \(TimeDisplay.current(timeDisplayRaw).dateFormatter.string(from: record.start))\(sent)\(record.reportReceived.map { ", got \($0)" } ?? "")"
        if !activeContest.isEmpty {
            // During a contest the question is "dupe or not?" — say so
            text += dupe
                ? " · dupe in \(activeContest) on \(bandName(forMHz: dialFrequencyMHz))"
                : " · not yet in \(activeContest) on \(bandName(forMHz: dialFrequencyMHz))"
        }
        return Label {
            Text(text)
        } icon: {
            Image(systemName: dupe ? "checkmark.seal.fill" : "checkmark.seal")
                .foregroundStyle(dupe ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        }
        .font(.callout)
    }

    /// One-click JS8 queries at this station — the machine-answerable set
    /// plus the human "how copy".
    @ViewBuilder
    private var js8QueryRow: some View {
        if let onJS8Query {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ForEach(["SNR?", "GRID?", "HW CPY?"], id: \.self) { q in
                        js8QueryChip(q, onJS8Query)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(["INFO?", "STATUS?", "HEARING?", "QUERY MSGS"], id: \.self) { q in
                        js8QueryChip(q, onJS8Query)
                    }
                }
            }
        }
    }

    private func js8QueryChip(_ query: String, _ send: @escaping (String) -> Void) -> some View {
        Button {
            send("\(callsign) \(query)")
        } label: {
            Text(query)
                .font(.caption.monospaced())
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!js8QueryEnabled)
        .help(js8QueryEnabled
              ? "Transmit \"\(callsign) \(query)\" in the next slot"
              : "Start decoding (and check TX legality) first")
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
