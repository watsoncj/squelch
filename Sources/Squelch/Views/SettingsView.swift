import SwiftUI

struct SettingsView: View {
    @ObservedObject var cat: CATController
    @ObservedObject var location: LocationProvider
    @ObservedObject var controller: DecodeController

    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = ""
    @AppStorage(SettingsKeys.licenseClass) private var licenseClassRaw = LicenseClass.technician.rawValue
    @AppStorage(SettingsKeys.catPortPath) private var catPortPath = ""
    @AppStorage(SettingsKeys.catBaud) private var catBaud = 4800
    @AppStorage(SettingsKeys.myGrid) private var myGrid = ""
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
                    Text(controller.isRunning
                         ? String(format: "%.0f dBFS", controller.audioLevelDB)
                         : "start decoding for live level")
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.6))
                        .monospacedDigit()
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

                Toggle("Auto-answer stations calling \(myCallsign)", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: SettingsKeys.autoAnswer) },
                    set: { UserDefaults.standard.set($0, forKey: SettingsKeys.autoAnswer) }
                ))
                .help("When idle, a station calling you arms a reply with an on-screen countdown — cancel it before it fires to stay silent. You remain the control operator.")

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

                Text("Beacon runs in WSPR mode (dial 28.1246 MHz) while decoding is started. Each transmission is 110.6 s at a random offset in the WSPR sub-band.")
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
            if audioOutputUID.isEmpty, let digirig = AudioDevices.likelyDigirig(in: outputDevices) {
                audioOutputUID = digirig.uid
            }
        }
    }

    private func refreshTX() {
        outputDevices = AudioDevices.outputDevices()
        serialPorts = SerialPTT.availablePorts()
    }
}
