import SwiftUI
import AppKit

/// Settings in the macOS System Settings shape: groups in a searchable
/// sidebar, the selected group's controls in a detail form.
struct SettingsView: View {
    @ObservedObject var cat: CATController
    @ObservedObject var location: LocationProvider
    @ObservedObject var controller: DecodeController
    @ObservedObject var wsprNet: WSPRNetService
    @ObservedObject var updater: UpdateChecker
    @ObservedObject var js8: JS8Session

    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = ""
    @AppStorage(SettingsKeys.licenseClass) private var licenseClassRaw = LicenseClass.technician.rawValue
    @AppStorage(SettingsKeys.catPortPath) private var catPortPath = ""
    @AppStorage(SettingsKeys.catBaud) private var catBaud = 4800
    @AppStorage(SettingsKeys.myGrid) private var myGrid = ""
    @AppStorage(SettingsKeys.arrlSection) private var arrlSection = ""
    @AppStorage(SettingsKeys.audioDeviceUID) private var audioDeviceUID = ""
    @AppStorage(SettingsKeys.audioOutputUID) private var audioOutputUID = ""
    @AppStorage(SettingsKeys.pttPortPath) private var pttPortPath = ""
    @AppStorage(SettingsKeys.txOffsetHz) private var txOffsetHz = 1500.0

    @State private var devices: [AudioDevice] = []
    @State private var outputDevices: [AudioDevice] = []
    @State private var serialPorts: [String] = []
    @State private var selection: Pane? = .station
    @State private var searchText = ""

    /// One sidebar group. Keywords make search find settings that live
    /// inside a pane, not just the pane names.
    enum Pane: String, CaseIterable, Identifiable {
        case station, display, audio, transmit, js8, wspr, cat, updates

        var id: String { rawValue }

        var title: String {
            switch self {
            case .station: return "Station"
            case .display: return "Display"
            case .audio: return "Audio Input"
            case .transmit: return "Transmit"
            case .js8: return "JS8"
            case .wspr: return "WSPR Beacon"
            case .cat: return "CAT Control"
            case .updates: return "Updates"
            }
        }

        var icon: String {
            switch self {
            case .station: return "person.crop.square"
            case .display: return "clock"
            case .audio: return "waveform"
            case .transmit: return "antenna.radiowaves.left.and.right"
            case .js8: return "bubble.left.and.bubble.right"
            case .wspr: return "dot.radiowaves.up.forward"
            case .cat: return "cable.connector"
            case .updates: return "arrow.triangle.2.circlepath"
            }
        }

        var tint: Color {
            switch self {
            case .station: return .blue
            case .display: return .indigo
            case .audio: return .green
            case .transmit: return .red
            case .js8: return .orange
            case .wspr: return .teal
            case .cat: return .gray
            case .updates: return .purple
            }
        }

        var keywords: [String] {
            switch self {
            case .station: return ["callsign", "license", "grid", "maidenhead", "location", "arrl", "section", "cabrillo"]
            case .display: return ["time", "utc", "local", "distance", "miles", "kilometers", "units"]
            case .audio: return ["input", "device", "digirig", "level", "meter", "microphone", "silent"]
            case .transmit: return ["output", "ptt", "serial", "offset", "tune", "alc", "rts", "tx"]
            case .js8: return ["word table", "dictionary", "heartbeat", "acknowledge", "auto-reply", "snr", "query", "jsc"]
            case .wspr: return ["beacon", "power", "dbm", "duty", "cycle", "upload", "wsprnet", "spots"]
            case .cat: return ["serial", "baud", "ft-891", "radio", "frequency", "vfo", "connect"]
            case .updates: return ["update", "version", "check", "github", "release"]
            }
        }

        func matches(_ query: String) -> Bool {
            let q = query.lowercased()
            return title.lowercased().contains(q) || keywords.contains { $0.contains(q) }
        }
    }

    private var visiblePanes: [Pane] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? Pane.allCases : Pane.allCases.filter { $0.matches(q) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(visiblePanes) { pane in
                    HStack(spacing: 8) {
                        Image(systemName: pane.icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 6))
                        Text(pane.title)
                    }
                    .tag(pane)
                }
            }
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 175, ideal: 185, max: 220)
            .onChange(of: searchText) { _, _ in
                // Keep the detail on a pane the search can still see
                if let selection, !visiblePanes.contains(selection), let first = visiblePanes.first {
                    self.selection = first
                }
            }
        } detail: {
            Form {
                switch selection ?? .station {
                case .station: stationSection
                case .display: displaySection
                case .audio: audioSection
                case .transmit: transmitSection
                case .js8: js8Section
                case .wspr: wsprSection
                case .cat: catSection
                case .updates: updatesSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle((selection ?? .station).title)
        }
        .frame(width: 760, height: 560)
        .onAppear {
            devices = AudioDevices.inputDevices()
            refreshTX()
            if pttPortPath.isEmpty, let guess = SerialPTT.likelyPTTPort(in: serialPorts) {
                pttPortPath = guess
            }
            if catPortPath.isEmpty, let guess = CATController.likelyCATPort(in: serialPorts), guess != pttPortPath {
                catPortPath = guess
            }
            // Auto-select when unset, and re-select when the stored UID no
            // longer matches anything (USB port moves change device UIDs)
            if audioOutputUID.isEmpty || txOutputStale,
               let resolved = AudioDevices.resolveTXOutput(
                   storedOutputUID: audioOutputUID,
                   storedInputUID: audioDeviceUID,
                   outputs: outputDevices,
                   inputs: devices
               ) {
                audioOutputUID = resolved.device.uid
            }
        }
    }

    // MARK: - Panes (contents unchanged from the single-form layout)

    @ViewBuilder
    private var stationSection: some View {
        Section {
                TextField("Callsign", text: $myCallsign, prompt: Text("e.g. W1AW"))

                Picker("License class", selection: $licenseClassRaw) {
                    ForEach(LicenseClass.allCases) { license in
                        Text(license.rawValue).tag(license.rawValue)
                    }
                }
                .help("Sets the TX frequency lock and the frequency menu's transmit/receive-only split (Advanced holders: pick General)")

                HStack {
                    TextField("Grid square", text: $myGrid, prompt: Text("e.g. EN35"))
                        .help("Your station position — map dot and distances come from this")
                    Button {
                        location.queryGridFromLocation()
                    } label: {
                        if location.isQuerying {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Use My Location", systemImage: "location.fill")
                        }
                    }
                    .disabled(location.isQuerying)
                    .help("One-shot Location Services fix, converted to a Maidenhead grid")
                }
                if let error = location.queryError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if !myGrid.isEmpty && !Maidenhead.isValidGrid(myGrid) {
                    Text("Not a valid Maidenhead grid (expected like EN35 or EN35fd)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                TextField("ARRL/RAC section", text: $arrlSection, prompt: Text("e.g. CO — or DX outside US/Canada"))
                    .help("Cabrillo LOCATION: line for contest entries (WW Digi, ARRL contests). US/Canadian stations give their ARRL/RAC section; everyone else DX.")
            }
    }

    @ViewBuilder
    private var displaySection: some View {
        Section {
                Picker("Time", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: SettingsKeys.timeDisplay) ?? TimeDisplay.local.rawValue },
                    set: { UserDefaults.standard.set($0, forKey: SettingsKeys.timeDisplay) }
                )) {
                    ForEach(TimeDisplay.allCases) { choice in
                        Text(choice.rawValue).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .help("FT8 convention is UTC — what other operators and logs use — but Local can be easier to read")

                Picker("Distance", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: SettingsKeys.distanceUnit) ?? DistanceUnit.miles.rawValue },
                    set: { UserDefaults.standard.set($0, forKey: SettingsKeys.distanceUnit) }
                )) {
                    ForEach(DistanceUnit.allCases) { choice in
                        Text(choice.rawValue).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
    }

    @ViewBuilder
    private var audioSection: some View {
        Section {
                Picker("Device", selection: $audioDeviceUID) {
                    Text("System default").tag("")
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Button("Refresh Devices") {
                    devices = AudioDevices.inputDevices()
                }
                HStack(spacing: 8) {
                    Text("Input level")
                    CapsuleBar(
                        fraction: min(1, max(0, (Double(controller.audioLevelDB) + 60) / 60)),
                        tint: controller.audioLevelDB > -6 ? .red : .green
                    )
                    .frame(width: 160, height: 5)
                    if controller.isRunning {
                        Text(String(format: "%.0f dBFS", controller.audioLevelDB))
                            .font(.caption)
                            .foregroundStyle(.primary.opacity(0.6))
                            .monospacedDigit()
                    } else {
                        // A dead meter with a passive hint was a first-run
                        // trap — make starting the decoder one click away
                        Button("Start decoding") {
                            devices = AudioDevices.inputDevices()
                            controller.start(device: devices.first { $0.uid == audioDeviceUID })
                        }
                        .controlSize(.small)
                        .help("The meter shows live input only while decoding runs")
                    }
                }
                if controller.micDenied {
                    HStack(spacing: 8) {
                        Label("Microphone access is denied — Squelch can't hear the radio.", systemImage: "mic.slash.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button("Open Privacy Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
                if controller.isRunning, controller.inputSilent {
                    Label("Input is silent — check the Digirig connection, the device above, and the radio's volume.", systemImage: "waveform.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("The Digirig usually appears as “USB PnP Sound Device” or “USB Audio Device”. Restart decoding after changing this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private var transmitSection: some View {
        Section {
                Picker("Audio output", selection: $audioOutputUID) {
                    Text("System default").tag("")
                    ForEach(outputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .help("Must be the Digirig's output — TX audio on your Mac speakers won't key anything but your ego")
                if txOutputStale {
                    Label("The saved TX output device wasn't found — it may be unplugged or on a different USB port. Pick it again above.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Picker("PTT serial port", selection: $pttPortPath) {
                    Text("None (TX disabled)").tag("")
                    ForEach(serialPorts, id: \.self) { port in
                        Text(port.replacingOccurrences(of: "/dev/", with: "")).tag(port)
                    }
                }
                .help("Fallback PTT via RTS on this port — only used when CAT is not connected. With CAT up (DR-891), PTT is keyed by CAT command automatically, regardless of the radio's DATA PTT SELECT menu.")

                TextField("TX audio offset (Hz)", value: $txOffsetHz, format: .number.precision(.fractionLength(0)))
                    .help("Where your signal sits in the audio passband, 200–3000 Hz. Pick a spot clear of other traffic on the waterfall.")

                Button("Refresh Ports & Devices") {
                    refreshTX()
                }

                Text("Auto-reply (answering stations that call \(myCallsign), hunting new ones) is in the toolbar under Hunt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("First TX checklist: dial on 28.074 MHz (Technician-legal), radio in DATA-USB, menu 08-05 DATA PTT SELECT = RTS (radio-USB PTT) or DAKY (Digirig PTT), dummy load connected, then use Tune and raise Mac output volume until ALC just barely moves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private var js8Section: some View {
        Section {
                HStack {
                    Image(systemName: js8.wordTableInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(js8.wordTableInstalled ? .green : .orange)
                    Text(js8.wordTableInstalled ? "Word table installed" : "Word table not installed")
                    Spacer()
                    if js8.installingWordTable {
                        ProgressView().controlSize(.small)
                    }
                    Button("Download") {
                        js8.downloadWordTable()
                    }
                    .disabled(js8.installingWordTable)
                    Button("Choose File…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.cSource, .plainText]
                        panel.message = "Pick JS8Call's JSC_map.cpp"
                        if panel.runModal() == .OK, let url = panel.url {
                            js8.installWordTable(from: url)
                        }
                    }
                    .disabled(js8.installingWordTable)
                }
                Toggle("Auto-reply to queries addressed to me (SNR?, GRID?)", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: SettingsKeys.js8AutoReply) },
                    set: { UserDefaults.standard.set($0, forKey: SettingsKeys.js8AutoReply) }
                ))
                .help("Answers directed SNR?/GRID? queries automatically in the next slot — this keys the radio unattended. Rate-limited to one reply per station per 15 minutes. Off by default.")
                Toggle("Acknowledge heartbeats with a signal report", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: SettingsKeys.js8HBAck) },
                    set: { UserDefaults.standard.set($0, forKey: SettingsKeys.js8HBAck) }
                ))
                .help("Replies \"CALL HEARTBEAT SNR ±NN\" to heartbeats you decode — the report that tells a station you hear them, and what makes the HB network work. Keys the radio unattended (only while decoding runs in a JS8 mode); rate-limited to one ack per station per 15 minutes. On by default — turn off for receive-only monitoring.")
                if let status = js8.wordTableStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("JS8 compresses free text against a 262,144-word table that ships with JS8Call, not with Squelch. Without it, heartbeats, CQs and commands still decode, but message text shows as [JS8 word table not installed] and transmissions use the slower letter-by-letter coding. Download fetches JSC_map.cpp from the JS8Call-improved repository.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private var wsprSection: some View {
        Section {
                Picker("Reported power", selection: Binding(
                    get: { UserDefaults.standard.integer(forKey: SettingsKeys.wsprPowerDBm) },
                    set: { UserDefaults.standard.set($0, forKey: SettingsKeys.wsprPowerDBm) }
                )) {
                    Text("23 dBm (0.2 W)").tag(23)
                    Text("27 dBm (0.5 W)").tag(27)
                    Text("30 dBm (1 W)").tag(30)
                    Text("33 dBm (2 W)").tag(33)
                    Text("37 dBm (5 W)").tag(37)
                    Text("40 dBm (10 W)").tag(40)
                    Text("43 dBm (20 W)").tag(43)
                }
                .help("Encoded in the beacon message. With CAT connected this follows the radio's power setting automatically (read-only — the app never changes the radio); set it manually only when CAT is unavailable.")

                Picker("Duty cycle", selection: Binding(
                    get: { UserDefaults.standard.integer(forKey: SettingsKeys.wsprDutyPct) },
                    set: { UserDefaults.standard.set($0, forKey: SettingsKeys.wsprDutyPct) }
                )) {
                    Text("10%").tag(10)
                    Text("20%").tag(20)
                    Text("25%").tag(25)
                    Text("33%").tag(33)
                    Text("50%").tag(50)
                }
                .help("Fraction of 2-minute windows that transmit; the rest receive. 20% is the community norm.")

                Toggle("Upload received spots to WSPRnet", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: SettingsKeys.wsprUpload) },
                    set: { UserDefaults.standard.set($0, forKey: SettingsKeys.wsprUpload) }
                ))
                .help("Contribute every WSPR decode to wsprnet.org under your callsign and grid — the community propagation map runs on these. Off by default; nothing leaves the app until you opt in.")
                if UserDefaults.standard.bool(forKey: SettingsKeys.wsprUpload), wsprNet.uploadedCount > 0 {
                    Text("Uploaded \(wsprNet.uploadedCount) spot\(wsprNet.uploadedCount == 1 ? "" : "s") this session")
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.6))
                }

                Text("Beacon runs in WSPR mode (dial 28.1246 MHz) while decoding is started. Each transmission is 110.6 s at a random offset in the WSPR sub-band. While the beacon is armed, the sidebar shows who's hearing you (reports fetched from the WSPRnet database).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private var catSection: some View {
        Section {
                Picker("CAT serial port", selection: $catPortPath) {
                    Text("None").tag("")
                    ForEach(serialPorts, id: \.self) { port in
                        Text(port.replacingOccurrences(of: "/dev/", with: "")).tag(port)
                    }
                }
                .help("The radio's first USB serial port (Enhanced). With two cu.usbserial ports, CAT is the one ending in 0.")

                Picker("Baud rate", selection: $catBaud) {
                    Text("Auto").tag(0)
                    ForEach(CATController.baudCandidates.sorted(), id: \.self) { baud in
                        Text("\(baud)").tag(baud)
                    }
                }
                .help("Auto tries every rate the FT-891 supports; or pin it to radio menu 05-06 CAT RATE")
                if catBaud == 0, let detected = cat.detectedBaud {
                    Text("Detected \(detected) baud")
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.6))
                }

                HStack {
                    Button(cat.isConnected ? "Disconnect" : "Connect") {
                        if cat.isConnected {
                            cat.disconnectManually()
                        } else {
                            cat.connect()
                        }
                    }
                    .disabled(catPortPath.isEmpty)

                    if cat.isConnected {
                        Label(
                            "\(mhzText(cat.radioFrequencyMHz ?? 0)) MHz · \(cat.radioModeName ?? "—")",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    } else if let error = cat.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }

                Text("When connected, the app's dial frequency follows the radio's VFO, and the frequency menu QSYs the radio directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private var updatesSection: some View {
        Section {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: SettingsKeys.autoUpdateCheck) },
                    set: { UserDefaults.standard.set($0, forKey: SettingsKeys.autoUpdateCheck) }
                ))
                .help("Every 6 hours, quietly — skipped on hotspots and in Low Data Mode. Nothing installs until you click the restart chip.")

                Button("Check Now") {
                    updater.checkNow()
                }

                Text("Updates come from the app's GitHub Releases page, and the download is verified against this app's code signature before the restart chip appears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }

    /// A saved TX output UID that matches no current output device — it
    /// would render as an empty picker with no explanation otherwise.
    private var txOutputStale: Bool {
        !audioOutputUID.isEmpty && !outputDevices.contains { $0.uid == audioOutputUID }
    }

    private func refreshTX() {
        outputDevices = AudioDevices.outputDevices()
        serialPorts = SerialPTT.availablePorts()
    }
}
