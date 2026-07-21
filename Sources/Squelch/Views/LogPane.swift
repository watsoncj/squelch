import SwiftUI
import AppKit

/// SwiftUI list rows re-diff on every update; 5,000 rows at the UI tick
/// rate pegged the main thread. Filters and search still scan the full
/// log — only the rendered window is capped. (File-scope: generic types
/// can't hold static stored properties.)
private let maxFeedRows = 1200

/// Height of the sidebar header inset (toggle row 48 + search capsule 40);
/// the under-scroll fade mask must match it.
private let headerInsetHeight: CGFloat = 88

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
        // Chromeless mode draws the magnifier without reserving space for
        // it — drop it entirely; the SwiftUI wrapper supplies the icon
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
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

struct LogPane<Header: View>: View {
    @ObservedObject var store: DecodeStore
    @ObservedObject var stateResolver: StateResolver
    @Binding var selection: DecodedMessage.ID?
    var onReply: ((DecodedMessage) -> Void)? = nil
    var replyEnabled = true
    /// Rendered above the search field inside the glass header inset
    /// (the sidebar toggle row in the main window).
    @ViewBuilder var header: () -> Header
    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = "W0CJW"
    @AppStorage(SettingsKeys.timeDisplay) private var timeDisplayRaw = TimeDisplay.utc.rawValue
    @AppStorage(SettingsKeys.distanceUnit) private var distanceUnitRaw = DistanceUnit.miles.rawValue

    @State private var searchText = ""

    var body: some View {
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
        // The Maps under-scroll fade, done deterministically: rows lose
        // opacity as they climb into the header region and are gone by
        // its midpoint. (The macOS 26 scroll-edge-effect API doesn't touch
        // NSTableView-backed Lists.) Applied BEFORE the header inset so
        // the header itself stays fully opaque.
        .mask {
            // The gradient must sit ABOVE the list's resting top (over the
            // header region, where rows under-scroll): extend the mask up
            // by the header height. Resting rows get the solid section.
            VStack(spacing: 0) {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.35),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: headerInsetHeight)
                Color.black
            }
            .padding(.top, -headerInsetHeight)
        }
        // Maps-style under-scroll: the header is the list's top inset, so
        // rows rest below it but slide beneath its glass while scrolling
        .safeAreaInset(edge: .top, spacing: 0) {
            // No extra material here: rows show through the panel's own
            // glass while under-scrolling, exactly like Maps — the search
            // capsule's fill provides its own contrast
            VStack(spacing: 0) {
                header()
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    SearchField(text: $searchText, prompt: "Search call or message…")
                        .frame(height: 20) // chromeless field needs an explicit height or its text overflows the capsule
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
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

    private var visibleRows: [DecodedMessage] {
        Array(filtered.prefix(maxFeedRows))
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
