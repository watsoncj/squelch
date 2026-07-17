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

/// A station calling us that auto-answer has armed, pending its countdown.
struct PendingReply: Equatable {
    let call: String
    let grid: String?    // they sent their grid → we enter as caller
    let report: String?  // they sent a report → we enter as answerer
    let snr: Float
    let theirParity: Int
    let fireAt: Date     // the TX slot the reply goes out in (unless canceled)
}

final class AppModel: ObservableObject {
    let store = DecodeStore()
    let location = LocationProvider()
    let controller = DecodeController()
    let transmit = TransmitController()
    let sequencer = QSOSequencer()
    let qsoLog = QSOLog()
    let cat = CATController()
    let waterfall = WaterfallProcessor()
    let stateResolver = StateResolver()

    @Published var pendingReply: PendingReply?

    /// Partner we gave up on mid-exchange; their straggling reply within
    /// the grace window re-engages even with auto-answer off — the user
    /// already chose to work this station.
    private var recentlyAbandoned: (call: String, at: Date)?
    private static let abandonGraceSeconds: TimeInterval = 120

    /// Demo mode must never key the radio, even with PTT configured.
    let demoMode = CommandLine.arguments.contains("--demo")

    init() {
        sequencer.onQSOComplete = { [qsoLog] record in
            qsoLog.append(record)
        }
        sequencer.onQSOAbandoned = { [weak self] partner in
            self?.recentlyAbandoned = (partner, Date())
        }
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
        let period = controller.mode.slotSeconds
        let parity = Int(slotStart.timeIntervalSince1970 / period) % 2
        sequencer.myCall = UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? "W0CJW"
        sequencer.myGrid4 = String((location.effectiveGrid ?? "").prefix(4))

        if sequencer.mode != .idle {
            sequencer.ingest(
                decodes: results.map { QSOSequencer.Decode(text: $0.text, snr: $0.snr) },
                slotParity: parity
            )
        } else {
            considerAutoAnswer(results: results, theirParity: parity, period: period)
        }

        firePendingReplyIfDue(upcomingParity: 1 - parity, period: period)

        if let text = sequencer.transmission(forSlotParity: 1 - parity) {
            if demoMode {
                // Simulate success; never key the radio from demo data
            } else if !transmit.transmitNow(text: text) {
                sequencer.stop() // TX blocked (legality/config) — don't keep trying
            }
        }
    }

    /// While idle: someone calling W0CJW with a grid or report arms a
    /// countdown-gated reply (user sees it and can cancel before it fires).
    /// Auto-answer must be enabled — EXCEPT for a partner we just gave up
    /// on, whose late reply re-engages within the grace window regardless.
    private func considerAutoAnswer(results: [FT8Result], theirParity: Int, period: Double) {
        guard pendingReply == nil else { return }
        let myCall = (UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? "W0CJW").uppercased()
        guard let candidate = Self.callCandidate(in: results, myCall: myCall) else { return }

        let autoAnswerOn = UserDefaults.standard.bool(forKey: SettingsKeys.autoAnswer)
        let isGraceReturn: Bool = {
            guard let abandoned = recentlyAbandoned else { return false }
            return abandoned.call == candidate.call
                && Date().timeIntervalSince(abandoned.at) < Self.abandonGraceSeconds
        }()
        guard autoAnswerOn || isGraceReturn else { return }

        recentlyAbandoned = nil
        pendingReply = PendingReply(
            call: candidate.call,
            grid: candidate.grid,
            report: candidate.report,
            snr: candidate.snr,
            theirParity: theirParity,
            fireAt: QSOSequencer.nextTXWindow(parity: 1 - theirParity, period: period, after: Date(), minLead: 5)
        )
    }

    /// First decode addressed to us carrying a grid or report — someone
    /// calling us. Pure and testable.
    static func callCandidate(
        in results: [FT8Result],
        myCall: String
    ) -> (call: String, grid: String?, report: String?, snr: Float)? {
        for result in results {
            let tokens = result.text.uppercased().split(separator: " ").map(String.init)
            guard tokens.count >= 3, tokens[0] == myCall.uppercased() else { continue }
            let from = tokens[1].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            guard FT8MessageParser.isCallsign(from) else { continue }
            let payload = tokens[2]

            let grid = FT8MessageParser.isGrid(payload) ? payload : nil
            let report = QSOSequencer.isReport(payload) ? payload : nil
            guard grid != nil || report != nil else { continue }
            return (from, grid, report, result.snr)
        }
        return nil
    }

    private func firePendingReplyIfDue(upcomingParity: Int, period: Double) {
        guard let pending = pendingReply else { return }
        let now = Date()
        // Stale (decoder was stopped past its window) — drop silently
        if now > pending.fireAt.addingTimeInterval(period) {
            pendingReply = nil
            return
        }
        guard sequencer.mode == .idle,
              upcomingParity == 1 - pending.theirParity,
              now >= pending.fireAt.addingTimeInterval(-1) else { return }

        pendingReply = nil
        if let grid = pending.grid {
            sequencer.engageAsCaller(call: pending.call, grid: grid, snr: pending.snr, theirParity: pending.theirParity)
        } else if let report = pending.report {
            sequencer.engageAsAnswerer(call: pending.call, report: report, snr: pending.snr, theirParity: pending.theirParity)
        }
    }

    func cancelPendingReply() {
        pendingReply = nil
    }

    func startCQ() {
        pendingReply = nil
        let period = controller.mode.slotSeconds
        let myCall = UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? "W0CJW"
        sequencer.myCall = myCall
        sequencer.myGrid4 = String((location.effectiveGrid ?? "").prefix(4))
        let lastParity = UserDefaults.standard.integer(forKey: SettingsKeys.lastCQParity)
        let parity = Self.quieterParity(
            messages: Array(store.messages.prefix(400)),
            myCall: myCall,
            period: period,
            fallback: lastParity
        )
        UserDefaults.standard.set(parity, forKey: SettingsKeys.lastCQParity)
        sequencer.startCQ(parity: parity)
    }

    /// Slot parity with less recent traffic — where our CQ competes least.
    /// Our own decodes (monitor loopback) are excluded so a CQ session
    /// doesn't make its own parity look busy and flip the next session;
    /// stale rows are ignored; ties keep the previous session's parity.
    static func quieterParity(
        messages: [DecodedMessage],
        myCall: String,
        period: Double,
        now: Date = Date(),
        fallback: Int
    ) -> Int {
        let cutoff = now.addingTimeInterval(-600)
        let relevant = messages.filter {
            $0.slotStart > cutoff && $0.callsign?.uppercased() != myCall.uppercased()
        }
        let evenCount = relevant.filter { $0.slotParity(slotSeconds: period) == 0 }.count
        let oddCount = relevant.count - evenCount
        if evenCount == oddCount {
            return fallback
        }
        return evenCount < oddCount ? 0 : 1
    }

    func reply(to message: DecodedMessage) {
        guard let call = message.callsign else { return }
        pendingReply = nil
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
        pendingReply = nil
        recentlyAbandoned = nil
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

        Window("QSO Log", id: "qso-log") {
            QSOLogView(qsoLog: model.qsoLog)
        }
        .defaultSize(width: 720, height: 420)
        .keyboardShortcut("l", modifiers: .command)

        Settings {
            SettingsView(cat: model.cat)
        }
    }
}
