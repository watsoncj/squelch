import SwiftUI

/// All completed contacts — auto-sequenced and manually logged.
struct QSOLogView: View {
    @ObservedObject var qsoLog: QSOLog
    @AppStorage(SettingsKeys.timeDisplay) private var timeDisplayRaw = TimeDisplay.utc.rawValue

    @State private var selection = Set<UUID>()
    @State private var showingAdd = false
    @State private var editingRecord: QSORecord?

    var body: some View {
        Table(qsoLog.records, selection: $selection) {
            TableColumn("Date") { record in
                Text(Self.dateFormatter.string(from: record.start))
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 90)

            TableColumn(TimeDisplay.current(timeDisplayRaw).rawValue) { record in
                Text(TimeDisplay.current(timeDisplayRaw).formatter.string(from: record.start))
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 70)

            TableColumn("Callsign") { record in
                Text(record.partner)
                    .font(.body.monospaced().bold())
            }
            .width(min: 80, ideal: 90)

            TableColumn("Grid") { record in
                Text(record.partnerGrid ?? "")
                    .monospaced()
            }
            .width(min: 44, ideal: 50)

            TableColumn("Country") { record in
                if let country = CallsignCountry.lookup(record.partner) {
                    Text("\(country.flag) \(country.name)")
                        .lineLimit(1)
                }
            }
            .width(min: 70, ideal: 120)

            TableColumn("Sent") { record in
                Text(record.reportSent).monospacedDigit()
            }
            .width(min: 40, ideal: 46)

            TableColumn("Rcvd") { record in
                Text(record.reportReceived ?? "").monospacedDigit()
            }
            .width(min: 40, ideal: 46)

            TableColumn("Band") { record in
                Text("\(bandName(forMHz: record.dialFrequencyMHz)) · \(record.mode)")
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let record = qsoLog.records.first(where: { $0.id == ids.first }) {
                Button("Edit QSO") {
                    editingRecord = record
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
            ToolbarItemGroup {
                Text("\(qsoLog.records.count) QSO\(qsoLog.records.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
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
        .frame(minWidth: 620, minHeight: 320)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

/// Manual QSO entry and editing — for contacts the sequencer didn't run,
/// or fixing ones it did.
private struct QSOFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    let existing: QSORecord?
    let onSave: (QSORecord) -> Void

    @AppStorage(SettingsKeys.dialFrequencyMHz) private var dialFrequencyMHz = 28.074

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
