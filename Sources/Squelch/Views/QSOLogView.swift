import SwiftUI

/// All completed contacts — auto-sequenced and manually logged.
/// Sortable, searchable, with resolved state/country per contact.
struct QSOLogView: View {
    @ObservedObject var qsoLog: QSOLog
    @ObservedObject var stateResolver: StateResolver
    @AppStorage(SettingsKeys.timeDisplay) private var timeDisplayRaw = TimeDisplay.local.rawValue

    @State private var selection = Set<UUID>()
    @State private var showingAdd = false
    @State private var editingRecord: QSORecord?
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\QSORecord.start, order: .reverse)]

    private var visibleRecords: [QSORecord] {
        var records = qsoLog.records
        let query = searchText.trimmingCharacters(in: .whitespaces).uppercased()
        if !query.isEmpty {
            records = records.filter {
                $0.partner.contains(query)
                    || ($0.partnerGrid ?? "").uppercased().contains(query)
                    || $0.mode.uppercased().contains(query)
                    || (locationText(for: $0)?.uppercased().contains(query) ?? false)
            }
        }
        return records.sorted(using: sortOrder)
    }

    /// "CO, USA" once a US partner's grid resolves; else the country name.
    private func locationText(for record: QSORecord) -> String? {
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
        .searchable(text: $searchText, prompt: "Search call, grid, state, or mode")
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let record = qsoLog.records.first(where: { $0.id == ids.first }) {
                Button("Edit QSO") {
                    editingRecord = record
                }
                Button("Look Up on QRZ") {
                    if let url = URL(string: "https://www.qrz.com/db/\(record.partner)") {
                        NSWorkspace.shared.open(url)
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
                    showingAdd = true
                } label: {
                    Label("Add QSO", systemImage: "plus")
                }
                .help("Log a contact made off-app (voice, another rig, a missed exchange)")
            }
        }
        .sheet(isPresented: $showingAdd) {
            QSOFormSheet(existing: nil) { record in
                qsoLog.append(record)
            }
        }
        .sheet(item: $editingRecord) { record in
            QSOFormSheet(existing: record) { updated in
                qsoLog.update(updated)
            }
        }
        .navigationTitle("QSO Log")
        .navigationSubtitle(subtitle)
        .frame(minWidth: 640, minHeight: 320)
    }
}

/// Manual QSO entry and editing — for contacts the sequencer didn't run,
/// or fixing ones it did.
private struct QSOFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    let existing: QSORecord?
    let onSave: (QSORecord) -> Void

    @AppStorage(SettingsKeys.dialFrequencyMHz) private var dialFrequencyMHz = 14.074

    @State private var callsign: String
    @State private var grid: String
    @State private var when: Date
    @State private var mode: String
    @State private var frequencyMHz: Double
    @State private var reportSent: String
    @State private var reportReceived: String

    private static let standardModes = ["FT8", "FT4", "SSB", "CW", "FM", "AM", "RTTY"]

    private var modes: [String] {
        // An edited record may carry a mode outside the standard list
        Self.standardModes.contains(mode) ? Self.standardModes : Self.standardModes + [mode]
    }

    init(existing: QSORecord?, onSave: @escaping (QSORecord) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _callsign = State(initialValue: existing?.partner ?? "")
        _grid = State(initialValue: existing?.partnerGrid ?? "")
        _when = State(initialValue: existing?.start ?? Date())
        _mode = State(initialValue: existing?.mode ?? "FT8")
        _frequencyMHz = State(initialValue: existing?.dialFrequencyMHz ?? 0)
        _reportSent = State(initialValue: existing?.reportSent ?? "")
        _reportReceived = State(initialValue: existing?.reportReceived ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "Log a QSO" : "Edit QSO")
                .font(.headline)

            Form {
                TextField("Callsign", text: $callsign)
                    .textCase(.uppercase)
                TextField("Grid (optional)", text: $grid, prompt: Text("e.g. EN34"))
                DatePicker("When", selection: $when)
                Picker("Mode", selection: $mode) {
                    ForEach(modes, id: \.self) { Text($0) }
                }
                TextField("Frequency (MHz)", value: $frequencyMHz, format: .number.precision(.fractionLength(3)))
                TextField("Report sent", text: $reportSent, prompt: Text("-05 / 59 …"))
                TextField("Report received", text: $reportReceived)
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
                    let duration = existing.map { $0.end.timeIntervalSince($0.start) } ?? 0
                    let record = QSORecord(
                        id: existing?.id ?? UUID(),
                        partner: callsign.trimmingCharacters(in: .whitespaces).uppercased(),
                        partnerGrid: grid.isEmpty ? nil : grid.uppercased(),
                        reportSent: reportSent,
                        reportReceived: reportReceived.isEmpty ? nil : reportReceived,
                        start: when,
                        end: when.addingTimeInterval(duration),
                        dialFrequencyMHz: frequencyMHz,
                        mode: mode
                    )
                    onSave(record)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(callsign.trimmingCharacters(in: .whitespaces).isEmpty
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
    }
}
