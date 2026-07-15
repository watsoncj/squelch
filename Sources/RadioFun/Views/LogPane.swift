import SwiftUI
import AppKit

struct LogPane: View {
    @ObservedObject var store: DecodeStore
    @ObservedObject var stateResolver: StateResolver
    @Binding var selection: DecodedMessage.ID?
    var onReply: ((DecodedMessage) -> Void)? = nil
    @AppStorage(SettingsKeys.usDisplay) private var usDisplayRaw = USDisplay.country.rawValue
    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = "W0CJW"
    @AppStorage(SettingsKeys.timeDisplay) private var timeDisplayRaw = TimeDisplay.utc.rawValue
    @AppStorage(SettingsKeys.distanceUnit) private var distanceUnitRaw = DistanceUnit.miles.rawValue

    @State private var filter: LogFilter = .all
    @State private var searchText = ""
    @State private var showCheatsheet = false

    enum LogFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case cq = "CQ"
        case mentionsMe = "Me"
        case withGrid = "Grid"
        case international = "Intl"
        var id: String { rawValue }

        var help: String {
            switch self {
            case .all: return "All decodes"
            case .cq: return "CQ calls only"
            case .mentionsMe: return "Messages calling me"
            case .withGrid: return "Messages carrying a grid square"
            case .international: return "Stations outside the US (by callsign prefix)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("Filter", selection: $filter) {
                    ForEach(LogFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(filter.help)

                Spacer(minLength: 8)

                Text("\(filtered.count) of \(store.messages.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

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

            TextField("Search call or message…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)

            Table(filtered, selection: $selection) {
                TableColumn(TimeDisplay.current(timeDisplayRaw).rawValue) { msg in
                    Text(TimeDisplay.current(timeDisplayRaw).formatter.string(from: msg.slotStart))
                        .monospacedDigit()
                }
                .width(min: 60, ideal: 65, max: 80)

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
                    if message.isCQ, message.callsign != nil, let onReply {
                        Button("Reply to \(message.callsign!)") {
                            onReply(message)
                        }
                    }
                    Button("Copy Message") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    }
                }
            }
        }
    }

    private var filtered: [DecodedMessage] {
        var result = store.messages
        switch filter {
        case .all: break
        case .cq: result = result.filter(\.isCQ)
        case .mentionsMe: result = result.filter { $0.mentions(myCallsign) }
        case .withGrid: result = result.filter { $0.grid != nil }
        case .international:
            result = result.filter { $0.callsign.map { !FT8MessageParser.isUSCallsign($0) } == true }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).uppercased()
        if !query.isEmpty {
            result = result.filter { $0.text.uppercased().contains(query) }
        }
        return result
    }

    /// "🇺🇸 UT, USA" when the State preference is on and the grid has
    /// resolved; otherwise the country name.
    private func countryText(for msg: DecodedMessage) -> String? {
        guard let country = msg.country else { return nil }
        if USDisplay.current(usDisplayRaw) == .state,
           let call = msg.callsign, FT8MessageParser.isUSCallsign(call),
           let grid = msg.grid,
           let state = stateResolver.state(forGrid: grid, isUS: true) {
            return "\(country.flag) \(state), USA"
        }
        return "\(country.flag) \(country.name)"
    }
}
