import SwiftUI
import AppKit

struct LogPane: View {
    @ObservedObject var store: DecodeStore
    @ObservedObject var stateResolver: StateResolver
    @Binding var selection: DecodedMessage.ID?
    var onReply: ((DecodedMessage) -> Void)? = nil
    var replyEnabled = true
    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = "W0CJW"
    @AppStorage(SettingsKeys.timeDisplay) private var timeDisplayRaw = TimeDisplay.utc.rawValue
    @AppStorage(SettingsKeys.distanceUnit) private var distanceUnitRaw = DistanceUnit.miles.rawValue

    @State private var searchText = ""
    @State private var showCheatsheet = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField("Search call or message…", text: $searchText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))

                Button {
                    showCheatsheet.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("How to read FT8 messages")
                .popover(isPresented: $showCheatsheet, arrowEdge: .bottom) {
                    CheatsheetView()
                }
                .onAppear {
                    if CommandLine.arguments.contains("--demo") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { showCheatsheet = true }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            Table(visibleRows, selection: $selection) {
                TableColumn(TimeDisplay.current(timeDisplayRaw).rawValue) { msg in
                    Text(TimeDisplay.current(timeDisplayRaw).logTimestamp(for: msg.slotStart))
                        .monospacedDigit()
                }
                .width(min: 60, ideal: 70, max: 110)

                TableColumn("SNR") { msg in
                    Text(String(format: "%+.0f", msg.snr))
                        .monospacedDigit()
                        .foregroundStyle(msg.snr >= 0 ? .green : .secondary)
                }
                .width(min: 36, ideal: 42, max: 50)

                TableColumn("DT") { msg in
                    Text(String(format: "%.1f", msg.timeOffset))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 32, ideal: 36, max: 44)

                TableColumn("Freq") { msg in
                    Text(String(format: "%.0f", msg.audioFrequency))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 42, ideal: 48, max: 60)

                TableColumn("Message") { msg in
                    Text(msg.text)
                        .font(.body.monospaced())
                        .fontWeight(msg.mentions(myCallsign) ? .bold : .regular)
                        .foregroundStyle(msg.mentions(myCallsign) ? Color.accentColor : (msg.isCQ ? Color.green : Color.primary))
                }
                .width(min: 220, ideal: 320)

                TableColumn("Country") { msg in
                    if let text = countryText(for: msg) {
                        Text(text)
                            .lineLimit(1)
                            .help(text)
                    } else {
                        Text("").accessibilityHidden(true)
                    }
                }
                .width(min: 50, ideal: 110, max: 160)

                TableColumn("Grid") { msg in
                    Text(msg.grid ?? "")
                        .monospaced()
                }
                .width(min: 40, ideal: 46, max: 60)

                TableColumn("Distance") { msg in
                    if let km = msg.distanceKm {
                        Text(DistanceUnit.current(distanceUnitRaw).text(fromKm: km))
                            .monospacedDigit()
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .width(min: 56, ideal: 64, max: 90)
            }
            .contextMenu(forSelectionType: DecodedMessage.ID.self) { ids in
                if let id = ids.first, let message = store.messages.first(where: { $0.id == id }) {
                    if message.isAnswerable(by: myCallsign), let call = message.callsign, let onReply {
                        Button(replyEnabled
                               ? (message.isCQ ? "Reply to \(call)" : "Answer \(call)")
                               : "Reply requires decoding (press Start)") {
                            onReply(message)
                        }
                        .disabled(!replyEnabled)
                    }
                    Button("Copy Message") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    }
                }
            }
            // Let the floating sidebar's material show through the table:
            // hide the scroll background AND the opaque alternating row stripes
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds(.disabled)
        }
    }

    private var filtered: [DecodedMessage] {
        var result = store.messages
        let query = searchText.trimmingCharacters(in: .whitespaces).uppercased()
        if !query.isEmpty {
            result = result.filter { $0.text.uppercased().contains(query) }
        }
        return result
    }

    /// SwiftUI Table re-diffs every row on each update; 5,000 rows at the
    /// UI tick rate pegged the main thread. Filters and search still scan
    /// the full log — only the rendered window is capped.
    private static let maxTableRows = 1200

    private var visibleRows: [DecodedMessage] {
        Array(filtered.prefix(Self.maxTableRows))
    }

    /// "🇺🇸 UT, USA" once a US station's grid has resolved to a state;
    /// otherwise the country name.
    private func countryText(for msg: DecodedMessage) -> String? {
        guard let country = msg.country else { return nil }
        if let call = msg.callsign, FT8MessageParser.isUSCallsign(call),
           let grid = msg.grid,
           let state = stateResolver.state(forGrid: grid, isUS: true) {
            return "\(country.flag) \(state), USA"
        }
        return "\(country.flag) \(country.name)"
    }
}
