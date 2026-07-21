import SwiftUI

struct ContentView: View {
    @ObservedObject var store: DecodeStore
    @ObservedObject var controller: DecodeController
    @ObservedObject var location: LocationProvider
    @ObservedObject var transmit: TransmitController
    @ObservedObject var sequencer: QSOSequencer
    @ObservedObject var qsoLog: QSOLog
    @ObservedObject var cat: CATController
    @ObservedObject var actions: AppModel

    @AppStorage(SettingsKeys.audioDeviceUID) private var audioDeviceUID = ""
    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = "W0CJW"
    @AppStorage(SettingsKeys.dialFrequencyMHz) private var dialFrequencyMHz = 28.074
    @AppStorage(SettingsKeys.digiMode) private var digiMode = DigiMode.ft8.rawValue
    @AppStorage(SettingsKeys.showWaterfall) private var showWaterfall = true
    @AppStorage(SettingsKeys.mapStyle) private var mapStyleRaw = MapStyleChoice.standard.rawValue
    @AppStorage(SettingsKeys.licenseClass) private var licenseClassRaw = LicenseClass.technician.rawValue
    @AppStorage(SettingsKeys.showGridCells) private var showGridCells = true
    @State private var devices: [AudioDevice] = []
    @State private var selectedMessageID: DecodedMessage.ID?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                MapPane(store: store, location: location, stateResolver: actions.stateResolver, selectedMessage: selectedMessage)
                    .ignoresSafeArea(edges: .top) // bleed under the transparent toolbar
                    .frame(minWidth: 400)
                    .layoutPriority(1)
                LogPane(
                    store: store,
                    stateResolver: actions.stateResolver,
                    selection: $selectedMessageID,
                    onReply: { message in actions.reply(to: message) },
                    replyEnabled: txAvailable && sequencer.mode == .idle
                )
                .frame(minWidth: 490, idealWidth: 540)
            }
            if showWaterfall {
                Divider()
                WaterfallPane(processor: actions.waterfall, transmit: transmit, controller: controller)
            }
            Divider()
            StatusBar(controller: controller, store: store, location: location, sequencer: sequencer, qsoLog: qsoLog, cat: cat)
        }
        .overlay(alignment: .topLeading) {
            QSOStatusPanel(sequencer: sequencer, transmit: transmit, model: actions)
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            // Map style picker leads (over the map, next to the traffic
            // lights); the flexible space pushes everything else to the
            // trailing edge over the log pane.
            ToolbarItemGroup {
                Picker("Map style", selection: $mapStyleRaw) {
                    ForEach(MapStyleChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Map appearance")

                Toggle(isOn: $showGridCells) {
                    Label("Grids", systemImage: "square.grid.3x3")
                }
                .toggleStyle(.button)
                .help("Show heard stations as highlighted grid squares")

                Spacer()

                Menu {
                    let txList = QSYPreset.transmitLegal(for: licenseClass)
                    ForEach(txList) { preset in
                        Button(preset.label) {
                            actions.qsy(to: preset)
                        }
                    }
                    let rxOnly = QSYPreset.receiveOnly(for: licenseClass)
                    if !rxOnly.isEmpty {
                        if !txList.isEmpty {
                            Divider()
                        }
                        // No "Receive only" header needed when everything is
                        // (license class None — the whole menu is RX)
                        if txList.isEmpty {
                            ForEach(rxOnly) { preset in
                                Button(preset.label) {
                                    actions.qsy(to: preset)
                                }
                            }
                        } else {
                            Section("Receive only") {
                                ForEach(rxOnly) { preset in
                                    Button(preset.label) {
                                        actions.qsy(to: preset)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label("\(mhzText(dialFrequencyMHz)) MHz", systemImage: "dial.medium")
                        .monospacedDigit()
                        .labelStyle(.titleAndIcon)
                }
                .help(cat.isConnected
                      ? "QSY the radio via CAT (connected)"
                      : "Set the working frequency. Connect CAT in Settings to also tune the radio.")

                Toggle(isOn: $showWaterfall) {
                    Label("Waterfall", systemImage: "rectangle.bottomthird.inset.filled")
                }
                .toggleStyle(.button)
                .help("Show the waterfall strip (double-click it to move your TX offset)")

                Button {
                    openWindow(id: "qso-log")
                } label: {
                    Label("QSO Log", systemImage: "checkmark.seal")
                }
                .help("Completed contacts (⌘L) — add off-app QSOs from there")

                Button {
                    toggleRunning()
                } label: {
                    if controller.isRunning {
                        Label("Stop", systemImage: "stop.fill")
                    } else {
                        Label("Start", systemImage: "play.fill")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .help(controller.isRunning ? "Stop decoding" : "Start decoding FT8")

                if isWSPRMode {
                    Button {
                        actions.setWSPRBeacon(!actions.wsprBeaconEnabled)
                    } label: {
                        Label(actions.wsprBeaconEnabled ? "Stop Beacon" : "Beacon",
                              systemImage: "dot.radiowaves.up.forward")
                    }
                    .disabled(!actions.wsprBeaconEnabled && !txAvailable)
                    .help(txDisabledReason ?? "Transmit WSPR at the configured duty cycle; spots of your signal appear on wsprnet receivers worldwide")
                } else {
                    Button {
                        if let message = selectedMessage {
                            actions.reply(to: message)
                        }
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                    }
                    .disabled(!canReplyToSelection)
                    .help(txDisabledReason ?? "Answer the selected CQ and run the QSO exchange automatically")

                    Button {
                        if sequencer.mode == .idle {
                            actions.startCQ()
                        } else {
                            actions.haltTX()
                        }
                    } label: {
                        Label(sequencer.mode == .idle ? "Call CQ" : "Stop CQ",
                              systemImage: sequencer.mode == .idle ? "megaphone.fill" : "megaphone")
                    }
                    .disabled(sequencer.mode == .idle && !txAvailable)
                    .help(txDisabledReason ?? "Call CQ repeatedly and answer stations that come back")
                }
            }
        }
        .onChange(of: digiMode) { _, raw in
            if raw != DigiMode.wspr.rawValue {
                actions.setWSPRBeacon(false)
            }
            if let mode = DigiMode(rawValue: raw) {
                actions.digiModeChanged(to: mode)
            }
        }
        .onAppear {
            devices = AudioDevices.inputDevices()
            autoSelectDigirig()
            location.requestLocation()
            if !cat.portPath.isEmpty {
                cat.connect()
            }
            if CommandLine.arguments.contains("--demo") {
                // Exercise the click-to-map path in demo screenshots:
                // prefer a directed message whose addressee is also mapped
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let twoPin = store.messages.first {
                        $0.coordinate != nil && !$0.isCQ
                            && $0.addressee.map { a in
                                a != "W0CJW" && store.stations[a] != nil
                            } == true
                    }
                    selectedMessageID = (twoPin ?? store.messages.first { $0.coordinate != nil })?.id
                }
                // Show the QSO status panel (AppModel.demoMode guarantees
                // demo never keys the radio)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    actions.startCQ()
                }
            }
        }
        .navigationTitle("Squelch")
    }

    private var selectedMessage: DecodedMessage? {
        guard let id = selectedMessageID else { return nil }
        return store.messages.first { $0.id == id }
    }

    private var isWSPRMode: Bool {
        digiMode == DigiMode.wspr.rawValue
    }

    private var licenseClass: LicenseClass {
        LicenseClass(rawValue: licenseClassRaw) ?? .technician
    }

    private var txLegal: Bool {
        TransmitController.isTXLegalMHz(dialFrequencyMHz, license: licenseClass)
    }

    private var txAvailable: Bool {
        controller.isRunning && txLegal
    }

    private var canReplyToSelection: Bool {
        guard txAvailable, sequencer.mode == .idle, !transmit.anyTXActive,
              let message = selectedMessage else { return false }
        return message.isAnswerable(by: myCallsign)
    }

    private var txDisabledReason: String? {
        if licenseClass == .unlicensed {
            return "License class is None — receive only (set yours in Settings)"
        }
        if !txLegal {
            return String(format: "%.3f MHz is outside %@ data privileges — TX disabled", dialFrequencyMHz, licenseClass.rawValue)
        }
        if !controller.isRunning {
            return "Start decoding first — the QSO sequencer needs receive slots"
        }
        return nil
    }

    private func toggleRunning() {
        if controller.isRunning {
            // A stopped decoder can't drive the sequencer — halt any
            // session/pending reply instead of leaving them armed and dead
            actions.haltTX()
            controller.stop()
        } else {
            // Re-enumerate at start so a just-plugged Digirig is found;
            // the device itself is chosen in Settings → Audio Input
            devices = AudioDevices.inputDevices()
            let device = devices.first { $0.uid == audioDeviceUID }
            controller.start(device: device)
            // Pre-start the TX engine so its device reconfiguration hits
            // now, while the capture's config-change handler can absorb it
            transmit.warmUp()
        }
    }

    /// On first launch, pre-select what looks like the Digirig.
    private func autoSelectDigirig() {
        guard audioDeviceUID.isEmpty else { return }
        if let digirig = AudioDevices.likelyDigirig(in: devices) {
            audioDeviceUID = digirig.uid
        }
    }
}
