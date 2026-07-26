import SwiftUI
import AVFAudio

/// iPad settings sheet. No audio-device picker (AVAudioSession routes to
/// USB audio automatically), no CAT/PTT/TX sections — receive only.
struct PadSettingsView: View {
    @ObservedObject var location: LocationProvider
    @ObservedObject var controller: DecodeController
    @ObservedObject var wsprNet: WSPRNetService

    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = ""
    @AppStorage(SettingsKeys.myGrid) private var myGrid = ""
    @AppStorage(SettingsKeys.dialFrequencyMHz) private var dialFrequencyMHz = 14.074
    @AppStorage(SettingsKeys.wsprUpload) private var wsprUpload = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Station") {
                    TextField("Callsign", text: $myCallsign, prompt: Text("e.g. W1AW"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    HStack {
                        TextField("Grid square", text: $myGrid, prompt: Text("e.g. EN35"))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
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
                    }
                    if let error = location.queryError {
                        Text(error).font(.caption).foregroundStyle(.red)
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
                    LabeledContent("Input", value: currentInput)
                    HStack(spacing: 8) {
                        Text("Level")
                        CapsuleBar(
                            fraction: min(1, max(0, (Double(controller.audioLevelDB) + 60) / 60)),
                            tint: controller.audioLevelDB > -6 ? .red : .green
                        )
                        .frame(width: 160, height: 5)
                        Text(controller.isRunning
                             ? String(format: "%.0f dBFS", controller.audioLevelDB)
                             : "start decoding for live level")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text("Plug the Digirig (or any USB audio interface) into the USB-C port — it's used automatically. Set the radio's dial by hand to match the frequency chosen in the toolbar; iPadOS has no USB serial, so CAT and transmit stay Mac features.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("WSPR") {
                    Toggle("Upload received spots to WSPRnet", isOn: $wsprUpload)
                    if wsprUpload, wsprNet.uploadedCount > 0 {
                        Text("Uploaded \(wsprNet.uploadedCount) spot\(wsprNet.uploadedCount == 1 ? "" : "s") this session")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Spots are contributed under your callsign and grid while decoding WSPR (dial on a WSPR frequency).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var currentInput: String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "Built-in microphone"
    }
}
