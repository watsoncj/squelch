import SwiftUI
import AppKit

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

    var body: some View {
        Form {
            Section("Station") {
                TextField("Callsign", text: $myCallsign, prompt: Text("e.g. W1AW"))
                    .textCase(.uppercase)

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
                    .textCase(.uppercase)
                    .help("Cabrillo LOCATION: line for contest entries (WW Digi, ARRL contests). US/Canadian stations give their ARRL/RAC section; everyone else DX.")
            }

            Section("Display") {
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

            Section("Audio Input") {
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

            Section("Transmit") {
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

            Section("WSPR Beacon") {
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

            Section("JS8") {
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
                .help("Replies \"CALL HEARTBEAT SNR ±NN\" to heartbeats you decode — the ack you've seen other stations send. Keys the radio unattended; rate-limited per station. Off by default.")
                if let status = js8.wordTableStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("JS8 compresses free text against a 262,144-word table that ships with JS8Call, not with Squelch. Without it, heartbeats, CQs and commands still decode, but message text shows as [JS8 word table not installed] and transmissions use the slower letter-by-letter coding. Download fetches JSC_map.cpp from the JS8Call-improved repository.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("CAT Control (FT-891)") {
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

            Section("Updates") {
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
        .formStyle(.grouped)
        .frame(width: 480)
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
