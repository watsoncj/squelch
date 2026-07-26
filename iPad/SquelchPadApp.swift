import SwiftUI

/// iPad model: the receive chain only. No TransmitController, no CAT, no
/// sequencer — iPadOS has no USB serial, so the radio can't be keyed or
/// tuned from here. Decode, map, log, and WSPRnet spot uploads all run.
final class PadModel: ObservableObject {
    let store = DecodeStore()
    let location = LocationProvider()
    let controller = DecodeController()
    let waterfall = WaterfallProcessor()
    let stateResolver = StateResolver()
    let qsoLog = QSOLog()
    let wsprNet = WSPRNetService()

    init() {
        controller.audioTap = { [waterfall] samples in
            waterfall.ingest(samples)
        }
        controller.onSlotDecoded = { [weak self] results, slotStart in
            guard let self else { return }
            let dial = UserDefaults.standard.double(forKey: SettingsKeys.dialFrequencyMHz)
            self.store.ingest(
                results: results,
                slotStart: slotStart,
                myCoordinate: self.location.effectiveCoordinate(),
                dialFrequencyMHz: dial > 0 ? dial : 14.074
            )
            if self.controller.mode == .wspr,
               UserDefaults.standard.bool(forKey: SettingsKeys.wsprUpload) {
                self.wsprNet.uploadSpots(
                    results: results,
                    slotStart: slotStart,
                    dialMHz: dial > 0 ? dial : 28.1246
                )
            }
        }
    }
}

@main
struct SquelchPadApp: App {
    @StateObject private var model = PadModel()

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKeys.dialFrequencyMHz: 14.074,
            SettingsKeys.digiMode: DigiMode.ft8.rawValue,
            SettingsKeys.wsprPowerDBm: 37,
            SettingsKeys.wsprDutyPct: 20,
        ])
    }

    var body: some Scene {
        WindowGroup {
            PadContentView(model: model)
        }
    }
}
