import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

/// Wraps generated ADIF text for the save panel. Export-only.
struct ADIFDocument: FileDocument {
    static let adiType = UTType(filenameExtension: "adi", conformingTo: .plainText) ?? .plainText
    static let readableContentTypes = [adiType]

    let text: String

    init(text: String) {
        self.text = text
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
    @State private var selection = Set<UUID>()
    @State private var showingAdd = false
    @State private var exportDocument: ADIFDocument?
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
                    || (locationText(for: $0)?.uppercased().contains(query) ?? false)
            }
        }
        return records.sorted(using: sortOrder)
    }

    /// "CO, USA" — the license state stored at log time wins (exact); a
    /// grid-center geocode is the fallback for older records, and it can
    /// miss near state borders.
    private func locationText(for record: QSORecord) -> String? {
        if let state = record.state {
            return "\(state), \(record.country == "Canada" ? "Canada" : "USA")"
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
                return record.country == "Canada" ? nil : state
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

            TableColumn("Band", value: \.dialFrequencyMHz) { record in
                Text("\(bandName(forMHz: record.dialFrequencyMHz)) · \(record.mode)")
            }
            .width(min: 70, ideal: 90)
        }
        .searchable(text: $searchText, prompt: "Search call, name, notes, grid, state, or mode")
        .contextMenu(forSelectionType: UUID.self) { ids in
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
                Button {
                    // Generated on demand — not per render
                    exportDocument = ADIFDocument(text: ADIFExporter.adi(
                        records: qsoLog.records,
                        stationCallsign: myCallsign.uppercased(),
                        myGrid: myGrid.isEmpty ? nil : myGrid.uppercased()
                    ))
                } label: {
                    Label("Export ADIF", systemImage: "square.and.arrow.up")
                }
                .disabled(qsoLog.records.isEmpty)
                .help("Export all QSOs as an ADIF (.adi) file for LoTW, QRZ Logbook, eQSL, POTA…")
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
            contentType: ADIFDocument.adiType,
            defaultFilename: "squelch-log.adi"
        ) { _ in exportDocument = nil }
        .sheet(isPresented: $showingAdd) {
            QSOFormSheet(existing: nil, allRecords: qsoLog.records) { record in
                qsoLog.append(record)
            }
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
    @State private var name: String
    @State private var notes: String
    @State private var lookupDebounce: DispatchWorkItem?
    // Autofill may replace its own earlier fill (callsign corrected),
    // never a value the user typed
    @State private var lastAutoFilledGrid = ""
    @State private var lastAutoFilledName = ""

    private static let standardModes = ["FT8", "FT4", "SSB", "CW", "FM", "AM", "RTTY"]

    private var modes: [String] {
        // An edited record may carry a mode outside the standard list
        Self.standardModes.contains(mode) ? Self.standardModes : Self.standardModes + [mode]
    }

    init(existing: QSORecord?, allRecords: [QSORecord], onSave: @escaping (QSORecord) -> Void) {
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
        _name = State(initialValue: existing?.name ?? "")
        _notes = State(initialValue: existing?.notes ?? "")
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
                DatePicker("When", selection: $when)
                Picker("Mode", selection: $mode) {
                    ForEach(modes, id: \.self) { Text($0) }
                }
                TextField("Frequency (MHz)", value: $frequencyMHz, format: .number.precision(.fractionLength(3)))
                TextField("Report sent", text: $reportSent, prompt: Text(reportHint))
                TextField("Report received", text: $reportReceived, prompt: Text(reportHint))
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
    }

    private var builtRecord: QSORecord {
        let call = normalizedCall
        let duration = existing.map { $0.end.timeIntervalSince($0.start) } ?? 0
        // License state/country: keep what the record had (same call), let a
        // fresh lookup win
        var state = existing?.partner == call ? existing?.state : nil
        var country = existing?.partner == call ? existing?.country : nil
        if case .found(let entry) = directory.lookups[call] {
            state = entry.state
            country = entry.country
        }
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
            state: state,
            country: country
        )
    }
}
