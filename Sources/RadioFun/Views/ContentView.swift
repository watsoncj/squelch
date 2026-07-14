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
    @AppStorage(SettingsKeys.dialFrequencyMHz) private var dialFrequencyMHz = 28.074
    @AppStorage(SettingsKeys.digiMode) private var digiMode = DigiMode.ft8.rawValue
    @AppStorage(SettingsKeys.showWaterfall) private var showWaterfall = true
    @State private var devices: [AudioDevice] = []
    @State private var selectedMessageID: DecodedMessage.ID?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                MapPane(store: store, location: location, selectedMessage: selectedMessage)
                    .frame(minWidth: 400)
                    .layoutPriority(1)
                LogPane(store: store, selection: $selectedMessageID) { message in
                    actions.reply(to: message)
                }
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
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    ForEach(QSYPreset.all) { preset in
                        Button(preset.label) {
                            actions.qsy(to: preset)
                        }
                    }
                } label: {
                    Label(String(format: "%.3f MHz", dialFrequencyMHz), systemImage: "dial.medium")
                        .monospacedDigit()
                        .labelStyle(.titleAndIcon)
                }
                .help(cat.isConnected
                      ? "QSY the radio via CAT (connected)"
                      : "Set the working frequency. Connect CAT in Settings to also tune the radio.")

                Picker("Mode", selection: $digiMode) {
                    ForEach(DigiMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(controller.isRunning)
                .help(controller.isRunning ? "Stop decoding to switch modes" : "FT8: 15 s slots · FT4: 7.5 s slots, ~2.5× faster QSOs")

                Divider()

                Picker("Input", selection: $audioDeviceUID) {
                    Text("Default input").tag("")
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .frame(minWidth: 180)
                .disabled(controller.isRunning)
                .help("Audio input device (the Digirig's USB sound card)")

                Button {
                    devices = AudioDevices.inputDevices()
                } label: {
                    Label("Refresh Devices", systemImage: "arrow.clockwise")
                }
                .disabled(controller.isRunning)

                Toggle(isOn: $showWaterfall) {
                    Label("Waterfall", systemImage: "water.waves")
                }
                .help("Show the passband spectrogram (double-click it to move your TX offset)")

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

                Divider()

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

                Button {
                    if transmit.isTuning {
                        transmit.stopTune()
                    } else {
                        transmit.startTune()
                    }
                } label: {
                    Label(transmit.isTuning ? "Stop Tune" : "Tune",
                          systemImage: "dot.radiowaves.right")
                }
                .disabled(!transmit.isTuning && (!txLegal || transmit.isTransmitting))
                .help(txDisabledReason ?? "Key the radio with a steady tone to set drive level (watch the ALC)")
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
        .navigationTitle("RadioFun — FT8 Monitor")
    }

    private var selectedMessage: DecodedMessage? {
        guard let id = selectedMessageID else { return nil }
        return store.messages.first { $0.id == id }
    }

    private var txLegal: Bool {
        TransmitController.isTechLegalMHz(dialFrequencyMHz)
    }

    private var txAvailable: Bool {
        controller.isRunning && txLegal
    }

    private var canReplyToSelection: Bool {
        guard txAvailable, sequencer.mode == .idle, !transmit.anyTXActive,
              let message = selectedMessage else { return false }
        return message.isCQ && message.callsign != nil
    }

    private var txDisabledReason: String? {
        if !txLegal {
            return String(format: "%.3f MHz is outside Technician data privileges — TX disabled", dialFrequencyMHz)
        }
        if !controller.isRunning {
            return "Start decoding first — the QSO sequencer needs receive slots"
        }
        return nil
    }

    private func toggleRunning() {
        if controller.isRunning {
            controller.stop()
        } else {
            devices = AudioDevices.inputDevices()
            let device = devices.first { $0.uid == audioDeviceUID }
            controller.start(device: device)
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
