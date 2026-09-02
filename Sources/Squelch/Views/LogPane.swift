import SwiftUI
#if os(macOS)
import AppKit
#endif

/// SwiftUI list rows re-diff on every update; 5,000 rows at the UI tick
/// rate pegged the main thread. Filters and search still scan the full
/// log — only the rendered window is capped. (File-scope: generic types
/// can't hold static stored properties.)
private let maxFeedRows = 1200

/// Row ages ("45s", "12m") are computed at render time — without a tick
/// they freeze whenever no new decodes arrive (decoder stopped, WSPR's
/// 2-minute slots). One re-diff per 15 s matches the FT8 slot cadence.
/// (File-scope: generic types can't hold static stored properties.)
private let feedAgeTick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

extension View {
    /// Top header over a scrolling view, with the system scroll edge
    /// effect (progressive blur) beneath it. safeAreaBar is the macOS 26
    /// API that enables the effect; safeAreaInset (the fallback) does not.
    @ViewBuilder
    func headerBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26.0, *) {
            self.safeAreaBar(edge: .top, spacing: 0, content: bar)
        } else {
            self.safeAreaInset(edge: .top, spacing: 0, content: bar)
        }
    }

    /// A slim invisible bottom bar so the system draws the same soft
    /// scroll-edge fade where rows leave the panel's bottom edge.
    @ViewBuilder
    func bottomFadeBar() -> some View {
        if #available(macOS 26.0, *) {
            self.safeAreaBar(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 14)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            self
        }
    }
}

#if !os(macOS)
/// iPad: a plain SwiftUI field inside the same translucent capsule — the
/// magnifier and clear button come from the wrapper, like the mac version.
struct SearchField: View {
    @Binding var text: String
    var prompt: String = "Search"

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
            .font(.system(size: 13))
    }
}
#else
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
        // Chromeless mode breaks the cell's own button layout/hit-testing —
        // drop both built-ins; the SwiftUI wrapper supplies icon and clear
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
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
#endif

/// Deep link to the mic permission fix — the OS Settings surface differs.
func openMicrophonePrivacySettings() {
    #if os(macOS)
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
        NSWorkspace.shared.open(url)
    }
    #else
    if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
    }
    #endif
}

/// Cross-platform clipboard write for the Copy Message action.
func copyToClipboard(_ string: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
    #else
    UIPasteboard.general.string = string
    #endif
}

struct LogPane<Header: View>: View {
    @ObservedObject var store: DecodeStore
    @ObservedObject var stateResolver: StateResolver
    @Binding var selection: DecodedMessage.ID?
    var onReply: ((DecodedMessage) -> Void)? = nil
    /// JS8 rows: open the composer addressed to this row's sender.
    var onJS8Compose: ((DecodedMessage) -> Void)? = nil
    var replyEnabled = true
    /// Mic permission was refused: the empty state becomes the fix-it
    /// guide — a fresh install otherwise fails silently (dead meter, no
    /// decodes, nothing explaining why).
    var micDenied = false
    /// Uppercased calls anywhere in the QSO log — rows get a worked-before
    /// seal. Defaulted so callers without a log (iPad) need no change.
    var workedCalls: Set<String> = []
    /// The subset that are dupes right now — same band, same contest
    /// context (`CQHunter.dupeCalls`, the hunter's own predicate, so the
    /// feed and the hunt never disagree). Filled seal; everything else in
    /// `workedCalls` gets an outline: known station, still workable here.
    var dupeCalls: Set<String> = []
    /// Active contest name, for the seal's tooltip wording.
    var contestName: String? = nil
    /// JS8 messages still arriving — shown above the feed until complete.
    var js8Pending: [JS8Receiver.Pending] = []
    /// Joined JS8 groups — traffic addressed to them highlights like
    /// traffic addressed to the operator.
    var js8Groups: Set<String> = []
    /// Rendered above the search field inside the glass header inset
    /// (the sidebar toggle row in the main window).
    @ViewBuilder var header: () -> Header
    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = ""
    @AppStorage(SettingsKeys.timeDisplay) private var timeDisplayRaw = TimeDisplay.local.rawValue
    @AppStorage(SettingsKeys.distanceUnit) private var distanceUnitRaw = DistanceUnit.miles.rawValue

    @State private var searchText = ""
    @State private var ageNow = Date()

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: selection) { _, id in
                    // Reveal externally-driven selections (toolbar chip
                    // callsign click). A nil anchor is a no-op for rows
                    // already on screen, so user clicks never jump.
                    guard let id else { return }
                    if !visibleRows.contains(where: { $0.id == id }),
                       store.messages.contains(where: { $0.id == id }) {
                        searchText = "" // row hidden by the search filter
                    }
                    withAnimation {
                        proxy.scrollTo(id)
                    }
                }
        }
    }

    private var list: some View {
        List(visibleRows, selection: $selection) { msg in
                FeedRow(
                    message: msg,
                    myCall: myCallsign,
                    countryText: countryText(for: msg),
                    distanceText: msg.distanceKm.map { DistanceUnit.current(distanceUnitRaw).text(fromKm: $0) },
                    worked: WorkedState.of(msg.callsign, dupes: dupeCalls, worked: workedCalls),
                    contestName: contestName,
                    now: ageNow
                )
                .listRowSeparator(.hidden)
                .listRowBackground(
                    msg.mentions(myCallsign) || (msg.isJS8 && js8Groups.contains(msg.addressee ?? ""))
                        ? Color.accentColor.opacity(0.14)
                        : Color.clear
                )
                .help(msg.text) // raw FT8 text one hover away
            }
            .listStyle(.plain)
            .contextMenu(forSelectionType: DecodedMessage.ID.self) { ids in
                if let id = ids.first, let message = store.messages.first(where: { $0.id == id }) {
                    if message.isJS8, let to = message.addressee, to.hasPrefix("@"),
                       !["@HB", "@ALLCALL"].contains(to), JS8Fields.isGroupAllowed(to) {
                        if js8Groups.contains(to) {
                            Button("Leave \(to)") {
                                let updated = js8Groups.subtracting([to]).sorted().joined(separator: ", ")
                                UserDefaults.standard.set(updated, forKey: SettingsKeys.js8Groups)
                            }
                        } else {
                            Button("Join \(to)") {
                                let updated = js8Groups.union([to]).sorted().joined(separator: ", ")
                                UserDefaults.standard.set(updated, forKey: SettingsKeys.js8Groups)
                            }
                        }
                    }
                    if message.isJS8, let call = message.callsign, call != myCallsign, let onJS8Compose {
                        Button("Message \(call)…") {
                            onJS8Compose(message)
                        }
                        Button("Query \(call) SNR") {
                            var m = message
                            _ = m // reuse the compose path with a prefilled query
                            onJS8Compose(DecodedMessage(
                                id: message.id, slotStart: message.slotStart, snr: message.snr,
                                timeOffset: message.timeOffset, audioFrequency: message.audioFrequency,
                                dialFrequencyMHz: message.dialFrequencyMHz, text: "\(call) SNR?",
                                callsign: message.callsign, grid: message.grid, latitude: message.latitude,
                                longitude: message.longitude, distanceKm: message.distanceKm, mode: message.mode))
                        }
                    }
                    if message.isAnswerable(by: myCallsign), let call = message.callsign, let onReply {
                        Button(replyEnabled
                               ? (message.isCQ ? "Reply to \(call)" : "Answer \(call)")
                               : "Reply requires decoding (press Start)") {
                            onReply(message)
                        }
                        .disabled(!replyEnabled)
                    }
                    Button("Copy Message") {
                        copyToClipboard(message.text)
                    }
                }
            }
        // Let the floating sidebar's material show through
        .scrollContentBackground(.hidden)
        // The idiomatic Maps under-scroll: a safe-area BAR (not inset)
        // makes the scroll view apply the system's progressive blur+fade
        // edge effect beneath the header automatically (macOS 26).
        .headerBar {
            headerContent
        }
        // Symmetry: same soft fade where rows exit at the panel's bottom
        .bottomFadeBar()
        .onReceive(feedAgeTick) { ageNow = $0 }
        .overlay {
            if visibleRows.isEmpty {
                emptyState
            }
        }
    }

    #if os(macOS)
    private static var startHint: String {
        "Connect your radio's audio interface, set your callsign and grid square, then press Start (⌘R)."
    }
    #else
    private static var startHint: String {
        "Connect your radio's USB audio interface, set your callsign and grid square, then tap Start."
    }
    #endif

    /// First-run guidance (or an empty search result).
    private var emptyState: some View {
        VStack(spacing: 10) {
            if store.messages.isEmpty, micDenied {
                Image(systemName: "mic.slash.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.red.opacity(0.8))
                Text("Microphone access needed")
                    .font(.headline)
                Text("Squelch can't hear the radio until microphone access is allowed — that's why the level meter is dead and nothing decodes.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.7))
                    .multilineTextAlignment(.center)
                Button("Open Privacy Settings") {
                    openMicrophonePrivacySettings()
                }
                .controlSize(.small)
                Text("Then press Start again.")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.6))
            } else if store.messages.isEmpty {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.largeTitle)
                    .foregroundStyle(.primary.opacity(0.4))
                Text("No decodes yet")
                    .font(.headline)
                Text(Self.startHint)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.7))
                    .multilineTextAlignment(.center)
                #if os(macOS)
                SettingsLink {
                    Text("Open Settings…")
                }
                .controlSize(.small)
                #endif
            } else {
                Text("No matches")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.6))
            }
        }
        .padding(24)
        .allowsHitTesting(store.messages.isEmpty) // let the settings link click
    }

    private var headerContent: some View {
        VStack(spacing: 0) {
            header()
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                SearchField(text: $searchText, prompt: "Search call or message…")
                    .frame(height: 20) // chromeless field needs an explicit height or its text overflows the capsule
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10)
            .padding(.bottom, js8Pending.isEmpty ? 8 : 4)
            ForEach(js8Pending, id: \.offsetHz) { p in
                HStack(spacing: 6) {
                    Image(systemName: "ellipsis.message")
                        .foregroundStyle(.secondary)
                    Text(pendingLabel(p))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 4)
                    Text("\(Int(p.offsetHz)) Hz")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .help("Still receiving — JS8 text arrives one frame per slot; the row moves into the feed when the last frame lands")
            }
            if !js8Pending.isEmpty {
                Spacer().frame(height: 6)
            }
        }
    }

    private func pendingLabel(_ p: JS8Receiver.Pending) -> String {
        var s = ""
        if let from = p.from { s += from + ": " }
        if let to = p.to { s += to + " " }
        s += p.textSoFar
        return s.isEmpty ? "receiving…" : s + "…"
    }

    /// Two-line feed row: who + how strong, then what it means + when.
    private struct FeedRow: View {
        let message: DecodedMessage
        let myCall: String
        let countryText: String?
        let distanceText: String?
        let worked: WorkedState
        let contestName: String?
        let now: Date

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
                    if worked != .no, message.callsign != myCall {
                        Image(systemName: worked == .dupe ? "checkmark.seal.fill" : "checkmark.seal")
                            .font(.caption2)
                            .foregroundStyle(worked == .dupe ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                            .help(worked.help(contestName: contestName))
                    }
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
                        .foregroundStyle(message.snr >= 0 ? AnyShapeStyle(.green) : AnyShapeStyle(.primary.opacity(0.75)))
                }
                HStack(spacing: 4) {
                    // .secondary gets vibrancy-dimmed on the panel material;
                    // plain primary at reduced opacity keeps more contrast
                    Text(secondLine)
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(relativeAgeText(for: message.slotStart, now: now))
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.65))
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

/// A feed row's worked-before standing, from the QSO log.
enum WorkedState: Equatable {
    case no
    /// In the log, but not on this band in the current contest context —
    /// a contest wants them again, and a new band is a new contact.
    case elsewhere
    /// Already worked on this band in this contest context.
    case dupe

    static func of(_ call: String?, dupes: Set<String>, worked: Set<String>) -> WorkedState {
        guard let call = call?.uppercased() else { return .no }
        if dupes.contains(call) { return .dupe }
        return worked.contains(call) ? .elsewhere : .no
    }

    func help(contestName: String?) -> String {
        switch (self, contestName) {
        case (.dupe, let contest?): return "Dupe — worked in \(contest) on this band"
        case (.dupe, nil): return "Worked before on this band"
        case (.elsewhere, let contest?): return "Worked before, but not yet in \(contest) on this band — still workable"
        case (.elsewhere, nil): return "Worked before — on another band or in a contest; new here"
        case (.no, _): return ""
        }
    }
}
