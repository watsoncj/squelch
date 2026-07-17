import SwiftUI

/// All completed contacts — auto-sequenced and manually logged.
struct QSOLogView: View {
    @ObservedObject var qsoLog: QSOLog
    @AppStorage(SettingsKeys.timeDisplay) private var timeDisplayRaw = TimeDisplay.utc.rawValue

    @State private var selection = Set<UUID>()
    @State private var showingAdd = false

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
            if !ids.isEmpty {
                Button("Delete \(ids.count == 1 ? "QSO" : "\(ids.count) QSOs")", role: .destructive) {
                    qsoLog.delete(ids)
                }
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
            AddQSOSheet { record in
                qsoLog.append(record)
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

/// Manual QSO entry — for contacts the sequencer didn't run.
private struct AddQSOSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (QSORecord) -> Void

    @AppStorage(SettingsKeys.dialFrequencyMHz) private var dialFrequencyMHz = 28.074

    @State private var callsign = ""
    @State private var grid = ""
    @State private var when = Date()
    @State private var mode = "FT8"
    @State private var frequencyMHz = 0.0
    @State private var reportSent = ""
    @State private var reportReceived = ""

    private static let modes = ["FT8", "FT4", "SSB", "CW", "FM", "AM", "RTTY"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Log a QSO")
                .font(.headline)

            Form {
                TextField("Callsign", text: $callsign)
                    .textCase(.uppercase)
                TextField("Grid (optional)", text: $grid, prompt: Text("e.g. EN34"))
                DatePicker("When", selection: $when)
                Picker("Mode", selection: $mode) {
                    ForEach(Self.modes, id: \.self) { Text($0) }
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
                    let record = QSORecord(
                        id: UUID(),
                        partner: callsign.trimmingCharacters(in: .whitespaces).uppercased(),
                        partnerGrid: grid.isEmpty ? nil : grid.uppercased(),
                        reportSent: reportSent,
                        reportReceived: reportReceived.isEmpty ? nil : reportReceived,
                        start: when,
                        end: when,
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
            frequencyMHz = dialFrequencyMHz
        }
    }
}
