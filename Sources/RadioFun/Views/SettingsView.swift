import SwiftUI

struct SettingsView: View {
    @ObservedObject var cat: CATController

    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = "W0CJW"
    @AppStorage(SettingsKeys.catPortPath) private var catPortPath = ""
    @AppStorage(SettingsKeys.catBaud) private var catBaud = 4800
    @AppStorage(SettingsKeys.myGrid) private var myGrid = ""
    @AppStorage(SettingsKeys.dialFrequencyMHz) private var dialFrequencyMHz = 28.074
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
                TextField("Callsign", text: $myCallsign)
                    .textCase(.uppercase)

                TextField("Grid square (fallback)", text: $myGrid, prompt: Text("e.g. EN35"))
                    .help("Used for your map position and distances when Location Services is unavailable")
                if !myGrid.isEmpty && !Maidenhead.isValidGrid(myGrid) {
                    Text("Not a valid Maidenhead grid (expected like EN35 or EN35fd)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Display") {
                Picker("Time", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: SettingsKeys.timeDisplay) ?? TimeDisplay.utc.rawValue },
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

                Picker("US stations", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: SettingsKeys.usDisplay) ?? USDisplay.country.rawValue },
                    set: { UserDefaults.standard.set($0, forKey: SettingsKeys.usDisplay) }
                )) {
                    ForEach(USDisplay.allCases) { choice in
                        Text(choice.rawValue).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .help("State shows e.g. 🇺🇸 CO, USA instead of 🇺🇸 USA, resolved from each station's grid square (fills in as lookups complete; needs network once per grid)")
            }

            Section("Radio") {
                TextField("Dial frequency (MHz)", value: $dialFrequencyMHz, format: .number.precision(.fractionLength(3)))
                    .help("Set to match the FT-891's VFO so log entries record the band. FT8 on 10m is 28.074 MHz.")
                Text("Common FT8 frequencies: 28.074 (10m, Technician-legal), 21.074 (15m), 14.074 (20m), 7.074 (40m)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                .help("PTT is keyed by asserting RTS on this port. FT-891 USB: the radio exposes two ports — use the second (Standard) one, with menu 08-05 DATA PTT SELECT = RTS. Digirig serial: the single cu.usbserial port, with DATA PTT SELECT = DAKY.")

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

            Section("CAT Control (FT-891)") {
                Picker("CAT serial port", selection: $catPortPath) {
                    Text("None").tag("")
                    ForEach(serialPorts, id: \.self) { port in
                        Text(port.replacingOccurrences(of: "/dev/", with: "")).tag(port)
                    }
                }
                .help("The radio's first USB serial port (Enhanced). With two cu.usbserial ports, CAT is the one ending in 0.")

                Picker("Baud rate", selection: $catBaud) {
                    ForEach([4800, 9600, 19200, 38400], id: \.self) { baud in
                        Text("\(baud)").tag(baud)
                    }
                }
                .help("Must match radio menu 05-06 CAT RATE (factory default 4800)")

                HStack {
                    Button(cat.isConnected ? "Disconnect" : "Connect") {
                        if cat.isConnected {
                            cat.disconnect()
                        } else {
                            cat.connect()
                        }
                    }
                    .disabled(catPortPath.isEmpty)

                    if cat.isConnected {
                        Label(
                            String(format: "%.3f MHz · %@", cat.radioFrequencyMHz ?? 0, cat.radioModeName ?? "—"),
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
