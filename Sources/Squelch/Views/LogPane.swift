import SwiftUI
import AppKit

/// The standard mac search input (magnifier icon, built-in clear button,
/// Esc clears) — SwiftUI's .searchable insists on toolbar placement, which
/// doesn't fit a floating panel.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String = "Search"

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        // Chromeless, Apple Maps style: the SwiftUI wrapper draws the
        // translucent capsule; the field keeps its magnifier + clear button
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

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

    var body: some View {
        VStack(spacing: 6) {
            SearchField(text: $searchText, prompt: "Search call or message…")
                .frame(height: 20) // chromeless field needs an explicit height or its text overflows the capsule
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)

            List(visibleRows, selection: $selection) { msg in
                FeedRow(
                    message: msg,
                    myCall: myCallsign,
                    countryText: countryText(for: msg),
                    distanceText: msg.distanceKm.map { DistanceUnit.current(distanceUnitRaw).text(fromKm: $0) }
                )
                .listRowSeparator(.hidden)
                .listRowBackground(
                    msg.mentions(myCallsign)
                        ? Color.accentColor.opacity(0.14)
                        : Color.clear
                )
                .help(msg.text) // raw FT8 text one hover away
            }
            .listStyle(.plain)
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
            // Let the floating sidebar's material show through
            .scrollContentBackground(.hidden)
            // The panel ignores the top safe area (flush to the window top),
            // which makes the NSTableView-backed List extend its canvas
            // upward and draw scrolled rows over the header — unlike Maps,
            // nothing may show north of the list. Hard clip.
            .clipped()
        }
    }

    /// Two-line feed row: who + how strong, then what it means + when.
    private struct FeedRow: View {
        let message: DecodedMessage
        let myCall: String
        let countryText: String?
        let distanceText: String?

        private var callColor: Color {
            if message.mentions(myCall) && message.callsign != myCall { return .accentColor }
            if message.callsign == myCall { return .blue }
            if message.isCQ { return .green }
            return .primary
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(message.country?.flag ?? " ")
                    Text(message.callsign ?? "—")
                        .font(.body.monospaced().bold())
                        .foregroundStyle(callColor)
                    if message.callsign == myCall {
                        Text("you")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.25), in: Capsule())
                    }
                    Spacer(minLength: 8)
                    Text(String(format: "%+.0f dB", message.snr))
                        .font(.caption.monospaced())
                        .foregroundStyle(message.snr >= 0 ? .green : .secondary)
                }
                HStack(spacing: 4) {
                    Text(secondLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(relativeAgeText(for: message.slotStart))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 2)
        }

        private var secondLine: String {
            var parts = [message.feedSummary(myCall: myCall)]
            if let countryText { parts.append(countryText) }
            if let distanceText { parts.append(distanceText) }
            return parts.joined(separator: " · ")
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

    /// "UT, USA" once a US station's grid has resolved to a state; otherwise
    /// the country name. No flag — line 1 already carries it.
    private func countryText(for msg: DecodedMessage) -> String? {
        guard let country = msg.country else { return nil }
        if let call = msg.callsign, FT8MessageParser.isUSCallsign(call),
           let grid = msg.grid,
           let state = stateResolver.state(forGrid: grid, isUS: true) {
            return "\(state), USA"
        }
        return country.name
    }
}
