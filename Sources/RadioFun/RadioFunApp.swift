import SwiftUI

/// Owns the long-lived model objects and wires decode results into the store.
/// A canonical digital-mode frequency the radio can QSY to.
struct QSYPreset: Identifiable {
    let label: String
    let mhz: Double
    let mode: DigiMode
    var id: String { label }

    /// Standard FT8/FT4 calling frequencies. TX stays hard-blocked outside
    /// Technician privileges; HF entries below 28 MHz are for listening.
    static let all: [QSYPreset] = [
        QSYPreset(label: "10m FT8 — 28.074", mhz: 28.074, mode: .ft8),
        QSYPreset(label: "10m FT4 — 28.180", mhz: 28.180, mode: .ft4),
        QSYPreset(label: "6m FT8 — 50.313", mhz: 50.313, mode: .ft8),
        QSYPreset(label: "6m FT4 — 50.318", mhz: 50.318, mode: .ft4),
        QSYPreset(label: "2m FT8 — 144.174", mhz: 144.174, mode: .ft8),
        QSYPreset(label: "15m FT8 — 21.074 (RX only)", mhz: 21.074, mode: .ft8),
        QSYPreset(label: "17m FT8 — 18.100 (RX only)", mhz: 18.100, mode: .ft8),
        QSYPreset(label: "20m FT8 — 14.074 (RX only)", mhz: 14.074, mode: .ft8),
        QSYPreset(label: "20m FT4 — 14.080 (RX only)", mhz: 14.080, mode: .ft4),
        QSYPreset(label: "40m FT8 — 7.074 (RX only)", mhz: 7.074, mode: .ft8),
        QSYPreset(label: "80m FT8 — 3.573 (RX only)", mhz: 3.573, mode: .ft8),
    ]
}

final class AppModel: ObservableObject {
    let store = DecodeStore()
    let location = LocationProvider()
    let controller = DecodeController()
    let transmit = TransmitController()
    let sequencer = QSOSequencer()
    let qsoLog = QSOLog()
    let cat = CATController()

    init() {
        sequencer.onQSOComplete = { [qsoLog] record in
            qsoLog.append(record)
        }
        controller.onSlotDecoded = { [weak self] results, slotStart in
            guard let self else { return }
            let dial = UserDefaults.standard.double(forKey: SettingsKeys.dialFrequencyMHz)
            self.store.ingest(
                results: results,
                slotStart: slotStart,
                myCoordinate: self.location.effectiveCoordinate(),
                dialFrequencyMHz: dial > 0 ? dial : 28.074
            )
            self.runSequencer(results: results, slotStart: slotStart)
        }
        if CommandLine.arguments.contains("--demo") {
            seedDemoData()
        }
    }

    /// After each receive slot: update the QSO state machine and, if it wants
    /// the upcoming slot, key up. The encoded audio's 0.5 s lead keeps us
    /// inside FT8's timing tolerance even though we start slightly late.
    private func runSequencer(results: [FT8Result], slotStart: Date) {
        guard sequencer.mode != .idle else { return }
        let parity = Int(slotStart.timeIntervalSince1970 / controller.mode.slotSeconds) % 2
        sequencer.myCall = UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? "W0CJW"
        sequencer.myGrid4 = String((location.effectiveGrid ?? "").prefix(4))
        sequencer.ingest(
            decodes: results.map { QSOSequencer.Decode(text: $0.text, snr: $0.snr) },
            slotParity: parity
        )
        if let text = sequencer.transmission(forSlotParity: 1 - parity) {
            if !transmit.transmitNow(text: text) {
                sequencer.stop() // TX blocked (legality/config) — don't keep trying
            }
        }
    }

    func startCQ() {
        let period = controller.mode.slotSeconds
        sequencer.myCall = UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? "W0CJW"
        sequencer.myGrid4 = String((location.effectiveGrid ?? "").prefix(4))
        // Transmit in whichever slot parity we hear less traffic (less QRM)
        let recent = store.messages.prefix(200)
        let evenCount = recent.filter { $0.slotParity(slotSeconds: period) == 0 }.count
        let parity = evenCount <= recent.count - evenCount ? 0 : 1
        sequencer.startCQ(parity: parity)
    }

    func reply(to message: DecodedMessage) {
        guard let call = message.callsign else { return }
        let period = controller.mode.slotSeconds
        sequencer.myCall = UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? "W0CJW"
        sequencer.myGrid4 = String((location.effectiveGrid ?? "").prefix(4))
        sequencer.replyTo(call: call, snr: message.snr, cqParity: message.slotParity(slotSeconds: period))
    }

    /// Change frequency (and app mode). QSYs the radio when CAT is up.
    func qsy(to preset: QSYPreset) {
        haltTX()
        UserDefaults.standard.set(preset.mhz, forKey: SettingsKeys.dialFrequencyMHz)
        let modeChanged = preset.mode != DigiMode.current
        UserDefaults.standard.set(preset.mode.rawValue, forKey: SettingsKeys.digiMode)
        cat.setFrequency(mhz: preset.mhz)
        if controller.isRunning, modeChanged {
            // Slot timing differs between FT8 and FT4 — restart decoding
            controller.stop()
            controller.statusText = "Mode changed to \(preset.mode.rawValue) — press Start"
        }
    }

    func haltTX() {
        sequencer.stop()
        transmit.haltAll()
    }

    /// Fake decodes for developing/verifying the UI without a radio.
    private func seedDemoData() {
        store.persistToDisk = false
        let fakes: [(Float, Float, String)] = [
            (-3, 1210, "CQ K1ABC FN42"),
            (-11, 743, "CQ DX JA3XYZ PM74"),
            (-18, 1502, "W0CJW K5DEF EM12"),
            (-7, 2010, "CQ POTA N0GHI DN70"),
            (-14, 987, "K1ABC G4JKL IO91"),
            (-1, 1650, "W0CJW VE3MNO FN03"),
            (-20, 455, "CQ KH6PQR BL11"),
        ]
        let results = fakes.map { FT8Result(snr: $0.0, timeOffset: 0.4, freqHz: $0.1, text: $0.2) }
        store.ingest(
            results: results,
            slotStart: Date(),
            myCoordinate: location.effectiveCoordinate(),
            dialFrequencyMHz: 28.074
        )
    }
}

@main
struct RadioFunApp: App {
    @StateObject private var model = AppModel()

    init() {
        // First-run defaults
        UserDefaults.standard.register(defaults: [
            SettingsKeys.myCallsign: "W0CJW",
            SettingsKeys.dialFrequencyMHz: 28.074,
            SettingsKeys.digiMode: DigiMode.ft8.rawValue,
            SettingsKeys.catBaud: 4800,
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                store: model.store,
                controller: model.controller,
                location: model.location,
                transmit: model.transmit,
                sequencer: model.sequencer,
                qsoLog: model.qsoLog,
                cat: model.cat,
                actions: model
            )
            .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView(cat: model.cat)
        }
    }
}
