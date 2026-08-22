import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

/// Wraps generated export text (ADIF or Cabrillo) for the save panel.
/// Export-only.
struct LogExportDocument: FileDocument {
    static let adiType = UTType(filenameExtension: "adi", conformingTo: .plainText) ?? .plainText
    static let cabrilloType = UTType(filenameExtension: "log", conformingTo: .plainText) ?? .plainText
    static let readableContentTypes = [adiType, cabrilloType]

    let text: String
    let contentType: UTType
    let defaultFilename: String

    init(text: String, contentType: UTType, defaultFilename: String) {
        self.text = text
        self.contentType = contentType
        self.defaultFilename = defaultFilename
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// All completed contacts — auto-sequenced and manually logged.
/// Sortable, searchable, with resolved state/country per contact.
struct QSOLogView: View {
    @ObservedObject var qsoLog: QSOLog
    @ObservedObject var stateResolver: StateResolver
    @AppStorage(SettingsKeys.timeDisplay) private var timeDisplayRaw = TimeDisplay.local.rawValue
    @AppStorage(SettingsKeys.myGrid) private var myGrid = ""
    @AppStorage(SettingsKeys.distanceUnit) private var distanceUnitRaw = DistanceUnit.miles.rawValue

    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = ""
    @AppStorage(SettingsKeys.activeContest) private var activeContest = ""
    @State private var selection = Set<UUID>()
    @State private var showingAdd = false
    @State private var showingNewContest = false
    @State private var newContestName = ""
    @State private var exportDocument: LogExportDocument?
    @StateObject private var backfiller = QSOBackfiller()
    @State private var editingRecord: QSORecord?
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\QSORecord.start, order: .reverse)]
    @Environment(\.openURL) private var openURL

    private var visibleRecords: [QSORecord] {
        var records = qsoLog.records
        let query = searchText.trimmingCharacters(in: .whitespaces).uppercased()
        if !query.isEmpty {
            records = records.filter {
                $0.partner.contains(query)
                    || ($0.partnerGrid ?? "").uppercased().contains(query)
                    || $0.mode.uppercased().contains(query)
                    || ($0.name ?? "").uppercased().contains(query)
                    || ($0.notes ?? "").uppercased().contains(query)
                    || ($0.contest ?? "").uppercased().contains(query)
                    || (locationText(for: $0)?.uppercased().contains(query) ?? false)
            }
        }
        return records.sorted(using: sortOrder)
    }

    /// "CO, USA" — the state/country stored on the record (lookup or
    /// hand-entered) wins; a grid-center geocode is the fallback for older
    /// records, and it can miss near state borders.
    private func locationText(for record: QSORecord) -> String? {
        let storedCountry = record.country.map { $0 == "United States" ? "USA" : $0 }
        if let state = record.state {
            return "\(state), \(storedCountry ?? "USA")"
        }
        if let storedCountry {
            return storedCountry
        }
        guard let country = CallsignCountry.lookup(record.partner) else { return nil }
        if FT8MessageParser.isUSCallsign(record.partner),
           let grid = record.partnerGrid,
           let state = stateResolver.state(forGrid: grid, isUS: true) {
            return "\(state), USA"
        }
        return country.name
    }

    private var subtitle: String {
        let records = qsoLog.records
        var parts = ["\(records.count) QSO\(records.count == 1 ? "" : "s")"]
        let states = Set(records.compactMap { record -> String? in
            if let state = record.state {
                // Provinces and other countries' subdivisions aren't WAS states
                let country = record.country
                return (country == nil || country == "United States") ? state : nil
            }
            guard FT8MessageParser.isUSCallsign(record.partner),
                  let grid = record.partnerGrid else { return nil }
            return stateResolver.state(forGrid: grid, isUS: true)
        })
        if !states.isEmpty {
            parts.append("\(states.count) state\(states.count == 1 ? "" : "s")")
        }
        let countries = Set(records.compactMap { CallsignCountry.lookup($0.partner)?.name })
        if countries.count > 1 {
            parts.append("\(countries.count) countries")
        }
        return parts.joined(separator: " · ")
    }

    private var loggedContests: [(name: String, count: Int)] {
        Dictionary(grouping: qsoLog.records.compactMap(\.contest), by: { $0 })
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.name < $1.name }
    }

    /// Selector choices: contests already in the log, plus the active one
    /// (it may be freshly named with no QSOs logged to it yet).
    private var contestOptions: [String] {
        var names = Set(loggedContests.map(\.name))
        if !activeContest.isEmpty { names.insert(activeContest) }
        return names.sorted()
    }

    // Documents are generated on demand — not per render
    private func exportADIF() {
        exportDocument = LogExportDocument(
            text: ADIFExporter.adi(
                records: qsoLog.records,
                stationCallsign: myCallsign.uppercased(),
                myGrid: myGrid.isEmpty ? nil : myGrid.uppercased()
            ),
            contentType: LogExportDocument.adiType,
            defaultFilename: "squelch-log.adi"
        )
    }

    /// nil exports everything; a contest name exports just that contest's
    /// QSOs with the CONTEST: header pre-filled.
    private func exportCabrillo(contest: String?) {
        let records = contest.map { name in qsoLog.records.filter { $0.contest == name } }
            ?? qsoLog.records
        let slug = contest.map { "-" + $0.lowercased().replacingOccurrences(of: " ", with: "-") } ?? ""
        exportDocument = LogExportDocument(
            text: CabrilloExporter.log(
                records: records,
                stationCallsign: myCallsign.uppercased(),
                myGrid: myGrid.isEmpty ? nil : myGrid.uppercased(),
                contest: contest
            ),
            contentType: LogExportDocument.cabrilloType,
            defaultFilename: "squelch\(slug).log"
        )
    }

    /// Selected rows as tab-separated text (visible-column order, current
    /// sort) — pastes cleanly into a spreadsheet or a message.
    private func selectionText(_ ids: Set<UUID>) -> String? {
        let rows = visibleRecords.filter { ids.contains($0.id) }
        guard !rows.isEmpty else { return nil }
        let unit = DistanceUnit.current(distanceUnitRaw)
        return rows.map { record in
            let geo = geo(for: record)
            return [
                whenText(for: record),
                record.partner,
                record.name ?? "",
                locationText(for: record) ?? "",
                record.partnerGrid ?? "",
                geo.map { unit.text(fromKm: $0.km) } ?? "",
                geo.map { compassBearingText(degrees: $0.bearing) } ?? "",
                "\(record.reportSent) / \(record.reportReceived ?? "—")",
                "\(bandName(forMHz: record.dialFrequencyMHz)) · \(record.mode)",
            ].joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// Great-circle distance/bearing from my grid — computed at display
    /// time so a Settings grid change updates every row.
    private func geo(for record: QSORecord) -> (km: Double, bearing: Double)? {
        guard let partnerGrid = record.partnerGrid,
              let me = Maidenhead.coordinate(forGrid: myGrid),
              let them = Maidenhead.coordinate(forGrid: partnerGrid) else { return nil }
        let meters = CLLocation(latitude: me.latitude, longitude: me.longitude)
            .distance(from: CLLocation(latitude: them.latitude, longitude: them.longitude))
        return (meters / 1000, Maidenhead.bearingDegrees(from: me, to: them))
    }

    private func whenText(for record: QSORecord) -> String {
        let display = TimeDisplay.current(timeDisplayRaw)
        return "\(display.dateFormatter.string(from: record.start))  \(display.formatter.string(from: record.start))"
    }

    var body: some View {
        Table(visibleRecords, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("When", value: \.start) { record in
                Text(whenText(for: record))
                    .monospacedDigit()
            }
            .width(min: 130, ideal: 150)

            TableColumn("Callsign", value: \.partner) { record in
                HStack(spacing: 6) {
                    Text(CallsignCountry.lookup(record.partner)?.flag ?? " ")
                    Text(record.partner)
                        .font(.body.monospaced().bold())
                }
            }
            .width(min: 90, ideal: 110)

            TableColumn("Name") { record in
                Text(record.name ?? "")
                    .lineLimit(1)
                    .help(record.notes.map { "\(record.name ?? record.partner) — \($0)" }
                          ?? record.name ?? "")
            }
            .width(min: 70, ideal: 110)

            TableColumn("Location") { record in
                if let text = locationText(for: record) {
                    Text(text)
                        .lineLimit(1)
                        .help(text)
                }
            }
            .width(min: 80, ideal: 130)

            TableColumn("Grid") { record in
                Text(record.partnerGrid ?? "—")
                    .monospaced()
                    .foregroundStyle(record.partnerGrid == nil ? .tertiary : .primary)
            }
            .width(min: 44, ideal: 52)

            TableColumn("Distance") { record in
                if let geo = geo(for: record) {
                    Text(DistanceUnit.current(distanceUnitRaw).text(fromKm: geo.km))
                        .monospacedDigit()
                }
            }
            .width(min: 58, ideal: 70)

            TableColumn("Bearing") { record in
                if let geo = geo(for: record) {
                    Text(compassBearingText(degrees: geo.bearing))
                        .monospacedDigit()
                }
            }
            .width(min: 64, ideal: 82)

            TableColumn("Report") { record in
                Text("\(record.reportSent) / \(record.reportReceived ?? "—")")
                    .monospacedDigit()
                    .help("Sent / received")
            }
            .width(min: 74, ideal: 84)

            TableColumn("Power") { record in
                Text(record.txPowerWatts.map { "\($0) W" } ?? "—")
                    .monospacedDigit()
            }
            .width(min: 48, ideal: 56)

            TableColumn("Band", value: \.dialFrequencyMHz) { record in
                Text("\(bandName(forMHz: record.dialFrequencyMHz)) · \(record.mode)")
            }
            .width(min: 70, ideal: 90)
        }
        .searchable(text: $searchText, prompt: "Search call, name, notes, grid, state, or mode")
#if os(macOS)
        // ⌘C / Edit ▸ Copy on the focused table
        .onCopyCommand {
            guard let text = selectionText(selection) else { return [] }
            return [NSItemProvider(object: text as NSString)]
        }
#endif
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                Button("Copy \(ids.count == 1 ? "QSO" : "\(ids.count) QSOs")") {
                    if let text = selectionText(ids) {
                        copyToClipboard(text)
                    }
                }
            }
            if ids.count == 1, let record = qsoLog.records.first(where: { $0.id == ids.first }) {
                Button("Edit QSO") {
                    editingRecord = record
                }
                Button("Look Up on QRZ") {
                    if let url = URL(string: "https://www.qrz.com/db/\(record.partner)") {
                        openURL(url)
                    }
                }
            }
            if !ids.isEmpty {
                Button("Delete \(ids.count == 1 ? "QSO" : "\(ids.count) QSOs")", role: .destructive) {
                    qsoLog.delete(ids)
                }
            }
        } primaryAction: { ids in
            // Double-click a row to edit it
            if let id = ids.first, let record = qsoLog.records.first(where: { $0.id == id }) {
                editingRecord = record
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Log new QSOs to", selection: $activeContest) {
                        Text("Off").tag("")
                        ForEach(contestOptions, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("New Contest…") {
                        newContestName = ""
                        showingNewContest = true
                    }
                } label: {
                    Label(activeContest.isEmpty ? "Contest" : activeContest,
                          systemImage: activeContest.isEmpty ? "tag" : "tag.fill")
                        .labelStyle(.titleAndIcon) // the active name should be visible, not hidden behind the icon
                }
                .help(activeContest.isEmpty
                      ? "Pick a contest to tag every new QSO with it — on-air and manual alike"
                      : "New QSOs are being tagged \(activeContest) — set to Off when the contest ends")
            }
            ToolbarItem {
                if let progress = backfiller.progress {
                    Button {
                        backfiller.cancel()
                    } label: {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("\(progress.done)/\(progress.total)")
                                .monospacedDigit()
                        }
                    }
                    .help("Looking up missing operator info — click to stop")
                } else {
                    Button {
                        backfiller.start(log: qsoLog)
                    } label: {
                        Label("Look Up Missing Info", systemImage: "person.crop.circle.badge.questionmark")
                    }
                    .disabled(!qsoLog.records.contains(where: QSOBackfiller.needsBackfill))
                    .help("Fill missing names, states, and grids from HamDB (US/Canada callsigns). Never overwrites what you've entered.")
                }
            }
            ToolbarItem {
                Menu {
                    Button("ADIF (.adi) — LoTW, QRZ, eQSL, POTA…") {
                        exportADIF()
                    }
                    Button("Cabrillo (.log) — all QSOs") {
                        exportCabrillo(contest: nil)
                    }
                    if !loggedContests.isEmpty {
                        Divider()
                        ForEach(loggedContests, id: \.name) { entry in
                            Button("Cabrillo — \(entry.name) (\(entry.count) QSO\(entry.count == 1 ? "" : "s"))") {
                                exportCabrillo(contest: entry.name)
                            }
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(qsoLog.records.isEmpty)
                .help("Export all QSOs — ADIF for LoTW, QRZ Logbook, eQSL, POTA; Cabrillo for contest entries")
            }
            ToolbarItem {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add QSO", systemImage: "plus")
                }
                .help("Log a contact made off-app (voice, another rig, a missed exchange)")
            }
        }
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil },
                set: { if !$0 { exportDocument = nil } }
            ),
            document: exportDocument,
            contentType: exportDocument?.contentType ?? LogExportDocument.adiType,
            defaultFilename: exportDocument?.defaultFilename ?? "squelch-log.adi"
        ) { _ in exportDocument = nil }
        .sheet(isPresented: $showingAdd) {
            QSOFormSheet(existing: nil, allRecords: qsoLog.records, defaultContest: activeContest) { record in
                qsoLog.append(record)
            }
        }
        .alert("New Contest", isPresented: $showingNewContest) {
            TextField("Name", text: $newContestName, prompt: Text("e.g. WW-DIGI"))
            Button("Start Logging") {
                let name = newContestName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { activeContest = name }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every QSO you log is tagged with this name until you set the selector back to Off. Use the contest's Cabrillo name so the export header is right.")
        }
        .sheet(item: $editingRecord) { record in
            QSOFormSheet(existing: record, allRecords: qsoLog.records) { updated in
                qsoLog.update(updated)
            }
        }
        .navigationTitle("QSO Log")
        .navigationSubtitle(subtitle)
        .frame(minWidth: 640, minHeight: 320)
    }
}

/// Manual QSO entry and editing — for contacts the sequencer didn't run,
/// or fixing ones it did. Typing a callsign fires a HamDB lookup that
/// auto-fills grid and name (never over anything typed by hand).
private struct QSOFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    let existing: QSORecord?
    let allRecords: [QSORecord]
    let onSave: (QSORecord) -> Void

    @AppStorage(SettingsKeys.dialFrequencyMHz) private var dialFrequencyMHz = 14.074
    @AppStorage(SettingsKeys.timeDisplay) private var timeDisplayRaw = TimeDisplay.local.rawValue
    @ObservedObject private var directory = CallsignDirectory.shared

    @State private var callsign: String
    @State private var grid: String
    @State private var when: Date
    @State private var mode: String
    @State private var frequencyMHz: Double
    @State private var reportSent: String
    @State private var reportReceived: String
    @State private var powerWatts: String
    @State private var name: String
    @State private var notes: String
    @State private var contest: String
    @State private var state: String
    @State private var country: String
    @State private var lookupDebounce: DispatchWorkItem?
    // Autofill may replace its own earlier fill (callsign corrected),
    // never a value the user typed
    @State private var lastAutoFilledGrid = ""
    @State private var lastAutoFilledName = ""
    @State private var lastAutoFilledState = ""
    @State private var lastAutoFilledCountry = ""

    private static let standardModes = ["FT8", "FT4", "SSB", "CW", "FM", "AM", "RTTY"]

    private var modes: [String] {
        // An edited record may carry a mode outside the standard list
        Self.standardModes.contains(mode) ? Self.standardModes : Self.standardModes + [mode]
    }

    init(existing: QSORecord?, allRecords: [QSORecord], defaultContest: String = "",
         onSave: @escaping (QSORecord) -> Void) {
        self.existing = existing
        self.allRecords = allRecords
        self.onSave = onSave
        _callsign = State(initialValue: existing?.partner ?? "")
        _grid = State(initialValue: existing?.partnerGrid ?? "")
        _when = State(initialValue: existing?.start ?? Date())
        _mode = State(initialValue: existing?.mode ?? "FT8")
        _frequencyMHz = State(initialValue: existing?.dialFrequencyMHz ?? 0)
        _reportSent = State(initialValue: existing?.reportSent ?? "")
        _reportReceived = State(initialValue: existing?.reportReceived ?? "")
        _powerWatts = State(initialValue: existing?.txPowerWatts.map(String.init) ?? "")
        _name = State(initialValue: existing?.name ?? "")
        _notes = State(initialValue: existing?.notes ?? "")
        _contest = State(initialValue: existing?.contest ?? defaultContest)
        _state = State(initialValue: existing?.state ?? "")
        _country = State(initialValue: existing?.country ?? "")
    }

    /// Contest names already in the log — one tap beats retyping
    /// "ARRL-VHF" three slightly different ways.
    private var knownContests: [String] {
        Array(Set(allRecords.compactMap(\.contest))).sorted()
    }

    private var normalizedCall: String {
        callsign.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// "five nine" on phone, 599 on CW, dB on the digital modes.
    private var reportHint: String {
        switch mode {
        case "FT8", "FT4": return "e.g. -05"
        case "CW", "RTTY": return "e.g. 599"
        default: return "e.g. 59"
        }
    }

    private var workedBefore: [QSORecord] {
        let call = normalizedCall
        guard !call.isEmpty else { return [] }
        return allRecords.filter { $0.partner == call && $0.id != existing?.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "Log a QSO" : "Edit QSO")
                .font(.headline)

            Form {
                TextField("Callsign", text: $callsign)
                    .textCase(.uppercase)
                    .onSubmit { fireLookup() }
                lookupStatusRow
                workedBeforeRow
                TextField("Name", text: $name)
                TextField("Grid (optional)", text: $grid, prompt: Text("e.g. EN34"))
                TextField("State (optional)", text: $state, prompt: Text("e.g. CO"))
                    .help("Filled by the callsign lookup — set it yourself when the callsign isn't in HamDB")
                TextField("Country (optional)", text: $country, prompt: Text("e.g. United States"))
                DatePicker("When", selection: $when)
                Picker("Mode", selection: $mode) {
                    ForEach(modes, id: \.self) { Text($0) }
                }
                TextField("Frequency (MHz)", value: $frequencyMHz, format: .number.precision(.fractionLength(3)))
                TextField("Report sent", text: $reportSent, prompt: Text(reportHint))
                TextField("Report received", text: $reportReceived, prompt: Text(reportHint))
                TextField("Power (optional, W)", text: $powerWatts, prompt: Text("e.g. 10"))
                HStack(spacing: 4) {
                    TextField("Contest (optional)", text: $contest)
                        .help("Tag contest QSOs so the Cabrillo export can bundle just this contest")
                    if !knownContests.isEmpty {
                        Menu {
                            ForEach(knownContests, id: \.self) { known in
                                Button(known) { contest = known }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Contests already in the log")
                    }
                }
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...4)
            }
            .formStyle(.columns)

            if !grid.isEmpty && !Maidenhead.isValidGrid(grid) {
                Text("Grid doesn't look like a Maidenhead locator")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(builtRecord)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(normalizedCall.isEmpty
                          || (!grid.isEmpty && !Maidenhead.isValidGrid(grid)))
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if existing == nil {
                frequencyMHz = dialFrequencyMHz
            }
        }
        .onChange(of: callsign) {
            lookupDebounce?.cancel()
            guard normalizedCall.count >= 3 else { return }
            let work = DispatchWorkItem { fireLookup() }
            lookupDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        }
    }

    @ViewBuilder private var lookupStatusRow: some View {
        switch directory.lookups[normalizedCall] {
        case .found(let entry):
            Text([entry.name, entry.city, entry.state]
                .compactMap { $0 }
                .joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .pending:
            ProgressView()
                .controlSize(.small)
        case .missing:
            Text("No US/Canada license record")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .failed:
            HStack(spacing: 6) {
                Text("Lookup failed — offline?")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Retry") { directory.retry(normalizedCall) }
                    .linkButton()
                    .font(.caption)
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var workedBeforeRow: some View {
        if let last = workedBefore.max(by: { $0.start < $1.start }) {
            Label {
                Text("Worked \(workedBefore.count)× — last \(TimeDisplay.current(timeDisplayRaw).dateFormatter.string(from: last.start)) on \(bandName(forMHz: last.dialFrequencyMHz)) \(last.mode)")
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func fireLookup() {
        let call = normalizedCall
        guard call.count >= 3 else { return }
        // Completion fires immediately when the session cache already has
        // an answer — .onReceive would miss that case
        CallsignDirectory.shared.lookup(call) { _ in applyLookup() }
    }

    private func applyLookup() {
        guard case .found(let entry) = directory.lookups[normalizedCall] else { return }
        if let g = entry.grid, grid.isEmpty || grid == lastAutoFilledGrid {
            grid = g
            lastAutoFilledGrid = g
        }
        if name.isEmpty || name == lastAutoFilledName {
            name = entry.name
            lastAutoFilledName = entry.name
        }
        if let s = entry.state, state.isEmpty || state == lastAutoFilledState {
            state = s
            lastAutoFilledState = s
        }
        if let c = entry.country, country.isEmpty || country == lastAutoFilledCountry {
            country = c
            lastAutoFilledCountry = c
        }
    }

    private var builtRecord: QSORecord {
        let call = normalizedCall
        let duration = existing.map { $0.end.timeIntervalSince($0.start) } ?? 0
        let state = state.trimmingCharacters(in: .whitespaces).uppercased()
        let country = country.trimmingCharacters(in: .whitespaces)
        return QSORecord(
            id: existing?.id ?? UUID(),
            partner: call,
            partnerGrid: grid.isEmpty ? nil : grid.uppercased(),
            reportSent: reportSent,
            reportReceived: reportReceived.isEmpty ? nil : reportReceived,
            start: when,
            end: when.addingTimeInterval(duration),
            dialFrequencyMHz: frequencyMHz,
            mode: mode,
            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name,
            notes: notes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : notes,
            state: state.isEmpty ? nil : state,
            country: country.isEmpty ? nil : country,
            contest: {
                let trimmed = contest.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }(),
            txPowerWatts: Int(powerWatts.trimmingCharacters(in: .whitespaces))
        )
    }
}
