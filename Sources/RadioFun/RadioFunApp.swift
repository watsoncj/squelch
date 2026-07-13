import SwiftUI

/// Owns the long-lived model objects and wires decode results into the store.
final class AppModel: ObservableObject {
    let store = DecodeStore()
    let location = LocationProvider()
    let controller = DecodeController()
    let transmit = TransmitController()
    let sequencer = QSOSequencer()
    let qsoLog = QSOLog()

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
        let parity = Int(slotStart.timeIntervalSince1970 / 15) % 2
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
        sequencer.myCall = UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? "W0CJW"
        sequencer.myGrid4 = String((location.effectiveGrid ?? "").prefix(4))
        // Transmit in whichever slot parity we hear less traffic (less QRM)
        let recent = store.messages.prefix(200)
        let evenCount = recent.filter { $0.slotParity == 0 }.count
        let parity = evenCount <= recent.count - evenCount ? 0 : 1
        sequencer.startCQ(parity: parity)
    }

    func reply(to message: DecodedMessage) {
        guard let call = message.callsign else { return }
        sequencer.myCall = UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? "W0CJW"
        sequencer.myGrid4 = String((location.effectiveGrid ?? "").prefix(4))
        sequencer.replyTo(call: call, snr: message.snr, cqParity: message.slotParity)
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
                actions: model
            )
            .frame(minWidth: 950, minHeight: 620)
        }
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView()
        }
    }
}
