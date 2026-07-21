import SwiftUI

/// Owns the long-lived model objects and wires decode results into the store.
/// A canonical digital-mode frequency the radio can QSY to.
struct QSYPreset: Identifiable {
    let label: String
    let mhz: Double
    let mode: DigiMode
    var id: String { label }

    /// Menu row in the same order as the selection display — left-aligned,
    /// every frequency with the same digit count (4 decimals).
    var menuTitle: String {
        "\(String(format: "%.4f", mhz)) MHz · \(mode.rawValue) · \(bandName(forMHz: mhz))"
    }

    /// Standard calling frequencies: 10m first (the workhorse band here),
    /// up through VHF, then down through HF; FT8 → FT4 → WSPR within each
    /// band. The transmit/receive-only split comes from the license class.
    static let all: [QSYPreset] = [
        QSYPreset(label: "10m FT8 — 28.074", mhz: 28.074, mode: .ft8),
        QSYPreset(label: "10m FT4 — 28.180", mhz: 28.180, mode: .ft4),
        QSYPreset(label: "10m WSPR — 28.1246", mhz: 28.1246, mode: .wspr),
        QSYPreset(label: "6m FT8 — 50.313", mhz: 50.313, mode: .ft8),
        QSYPreset(label: "6m FT4 — 50.318", mhz: 50.318, mode: .ft4),
        QSYPreset(label: "6m WSPR — 50.293", mhz: 50.293, mode: .wspr),
        QSYPreset(label: "2m FT8 — 144.174", mhz: 144.174, mode: .ft8),
        QSYPreset(label: "15m FT8 — 21.074", mhz: 21.074, mode: .ft8),
        QSYPreset(label: "15m WSPR — 21.0946", mhz: 21.0946, mode: .wspr),
        QSYPreset(label: "17m FT8 — 18.100", mhz: 18.100, mode: .ft8),
        QSYPreset(label: "20m FT8 — 14.074", mhz: 14.074, mode: .ft8),
        QSYPreset(label: "20m FT4 — 14.080", mhz: 14.080, mode: .ft4),
        QSYPreset(label: "20m WSPR — 14.0956", mhz: 14.0956, mode: .wspr),
        QSYPreset(label: "40m FT8 — 7.074", mhz: 7.074, mode: .ft8),
        QSYPreset(label: "40m WSPR — 7.0386", mhz: 7.0386, mode: .wspr),
        QSYPreset(label: "80m FT8 — 3.573", mhz: 3.573, mode: .ft8),
    ]

    static func transmitLegal(for license: LicenseClass) -> [QSYPreset] {
        all.filter { license.canTransmitData(mhz: $0.mhz) }
    }

    /// Listening is unrestricted; TX on these stays hard-blocked by the
    /// legality guard.
    static func receiveOnly(for license: LicenseClass) -> [QSYPreset] {
        all.filter { !license.canTransmitData(mhz: $0.mhz) }
    }
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
    @Published private(set) var wsprBeaconEnabled = false
    /// Decided one window ahead so the panel can announce it (pure
    /// per-window randomness read as "broken" during dry streaks).
    @Published private(set) var beaconNextWindowWillTX = false
    private var beaconWindowsSinceTX = 0
    private var beaconWork: DispatchWorkItem?

    /// Partner we gave up on mid-exchange; their straggling reply within
    /// the grace window re-engages even with auto-answer off — the user
    /// already chose to work this station.
    private var recentlyAbandoned: (call: String, at: Date)?
    private static let abandonGraceSeconds: TimeInterval = 120

    /// Demo mode must never key the radio, even with PTT configured.
    let demoMode = CommandLine.arguments.contains("--demo")

    init() {
        sequencer.onQSOComplete = { [qsoLog, store] record in
            var record = record
            // The exchange itself often never carries the grid (answerer
            // side, mid-exchange entries) — backfill from the station cache
            if record.partnerGrid == nil, let grid = store.stations[record.partner]?.grid {
                record = QSORecord(
                    id: record.id, partner: record.partner,
                    partnerGrid: String(grid.prefix(4)).uppercased(),
                    reportSent: record.reportSent, reportReceived: record.reportReceived,
                    start: record.start, end: record.end,
                    dialFrequencyMHz: record.dialFrequencyMHz, mode: record.mode
                )
            }
            qsoLog.append(record)
        }
        sequencer.onQSOAbandoned = { [weak self] partner in
            self?.recentlyAbandoned = (partner, Date())
        }
        transmit.preTransmitHook = { [cat] in
            cat.ensureDataUSB()
        }
        transmit.catPTT = { [cat] keyed in
            guard cat.isConnected else { return false }
            cat.setPTT(keyed)
            return true
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

    // MARK: - WSPR beacon

    func setWSPRBeacon(_ on: Bool) {
        beaconWork?.cancel()
        beaconWork = nil
        wsprBeaconEnabled = on
        if on {
            beaconWindowsSinceTX = 0
            decideNextBeaconWindow()
            scheduleBeaconTick()
        }
    }

    /// Force the upcoming window to transmit (verification / impatience).
    func forceBeaconNextWindow() {
        guard wsprBeaconEnabled else { return }
        beaconNextWindowWillTX = true
    }

    /// Duty-cycle roll with a bounded gap: after ~2× the expected interval
    /// without a TX, the next window transmits regardless.
    private func decideNextBeaconWindow() {
        let duty = max(UserDefaults.standard.integer(forKey: SettingsKeys.wsprDutyPct), 1)
        let maxGapWindows = max(2, 2 * Int((100.0 / Double(duty)).rounded()))
        if beaconWindowsSinceTX + 1 >= maxGapWindows {
            beaconNextWindowWillTX = true
        } else {
            beaconNextWindowWillTX = Double.random(in: 0..<100) < Double(duty)
        }
    }

    private func scheduleBeaconTick() {
        guard wsprBeaconEnabled else { return }
        let period = DigiMode.wspr.slotSeconds
        let now = Date().timeIntervalSince1970
        var next = (now / period).rounded(.up) * period
        if next - now < 0.5 { next += period } // too close to key up cleanly
        let work = DispatchWorkItem { [weak self] in
            self?.beaconWindowFired()
        }
        beaconWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (next - now + 0.1), execute: work)
    }

    /// Fires just after each even-minute boundary; transmits when this
    /// window was pre-selected. The encoded audio's 1 s lead keeps us
    /// inside WSPR's ±2 s tolerance.
    private func beaconWindowFired() {
        defer {
            decideNextBeaconWindow()
            scheduleBeaconTick()
        }
        guard wsprBeaconEnabled,
              DigiMode.current == .wspr,
              controller.isRunning,
              !transmit.anyTXActive,
              !demoMode,
              beaconNextWindowWillTX else {
            beaconWindowsSinceTX += 1
            return
        }

        let call = UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? "W0CJW"
        let grid4 = String((location.effectiveGrid ?? "").prefix(4))
        guard grid4.count == 4 else {
            beaconWindowsSinceTX += 1
            return
        }
        let dbm = UserDefaults.standard.integer(forKey: SettingsKeys.wsprPowerDBm)
        let power = dbm > 0 ? dbm : 37
        let offset = Double.random(in: 1420...1580)
        if transmit.transmitWSPR(call: call, grid4: grid4, dbm: power, offsetHz: offset) {
            beaconWindowsSinceTX = 0
            // No synthetic "TX WSPR" log row: the RF loopback decode of our
            // own beacon lands in the feed with a real SNR, and the toolbar
            // chip shows the transmission live — the extra row was noise.
        } else {
            beaconWindowsSinceTX += 1
        }
    }

    func startCQ() {
        guard requireDecoding() else { return }
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

    /// The sequencer only transmits from the decode loop's slot boundaries;
    /// arming it with the decoder stopped yields a countdown that never
    /// fires. Refuse loudly instead. WSPR is a beacon mode with no QSOs.
    private func requireDecoding() -> Bool {
        guard controller.mode.supportsQSO || !controller.isRunning else {
            transmit.txError = "WSPR is a beacon mode — switch to FT8/FT4 for QSOs"
            return false
        }
        if controller.isRunning { return true }
        transmit.txError = "Start decoding first — the QSO sequencer transmits from receive slot boundaries"
        return false
    }

    /// Reply to a CQ (answer with our grid), or to a message calling us —
    /// entering mid-exchange at the right step for its payload.
    func reply(to message: DecodedMessage) {
        guard requireDecoding() else { return }
        guard let call = message.callsign else { return }
        pendingReply = nil
        let period = controller.mode.slotSeconds
        sequencer.myCall = UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? "W0CJW"
        sequencer.myGrid4 = String((location.effectiveGrid ?? "").prefix(4))
        let theirParity = message.slotParity(slotSeconds: period)

        if message.isCQ {
            sequencer.replyTo(call: call, snr: message.snr, cqParity: theirParity, grid: message.grid)
        } else if QSOSequencer.isReport(message.payloadToken) {
            // They sent us a report — we owe a roger
            sequencer.engageAsAnswerer(call: call, report: message.payloadToken, snr: message.snr, theirParity: theirParity)
        } else {
            // They called us with a grid (or bare call) — we owe a report
            sequencer.engageAsCaller(call: call, grid: message.grid, snr: message.snr, theirParity: theirParity)
        }
    }

    /// Standard frequency for a mode on the same band as `dialMHz`, from
    /// the preset table (nil when the band has no entry for that mode).
    static func standardFrequency(near dialMHz: Double, mode: DigiMode) -> Double? {
        let band = bandName(forMHz: dialMHz)
        guard band != "?" else { return nil }
        return QSYPreset.all.first { $0.mode == mode && bandName(forMHz: $0.mhz) == band }?.mhz
    }

    /// The user switched digital modes: if CAT is connected and we're on a
    /// standard calling frequency, follow to the new mode's frequency on
    /// the same band (switching to WSPR while parked on 28.074 would
    /// otherwise decode silence).
    func digiModeChanged(to newMode: DigiMode) {
        guard cat.isConnected else { return }
        let dial = UserDefaults.standard.double(forKey: SettingsKeys.dialFrequencyMHz)
        // Only retune when sitting on some mode's standard frequency —
        // never yank a deliberately hand-tuned dial
        let onAStandardFreq = QSYPreset.all.contains { abs($0.mhz - dial) < 0.0005 }
        guard onAStandardFreq,
              let target = Self.standardFrequency(near: dial, mode: newMode),
              abs(target - dial) > 0.0005 else { return }
        UserDefaults.standard.set(target, forKey: SettingsKeys.dialFrequencyMHz)
        cat.setFrequency(mhz: target)
    }

    /// Change frequency (and app mode). QSYs the radio when CAT is up.
    func qsy(to preset: QSYPreset) {
        haltTX()
        if preset.mode != .wspr {
            setWSPRBeacon(false)
        }
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
struct SquelchApp: App {
    @StateObject private var model = AppModel()

    init() {
        Self.migrateRadioFunSettings()
        // First-run defaults
        UserDefaults.standard.register(defaults: [
            SettingsKeys.myCallsign: "W0CJW",
            SettingsKeys.dialFrequencyMHz: 28.074,
            SettingsKeys.digiMode: DigiMode.ft8.rawValue,
            SettingsKeys.catBaud: 4800,
            SettingsKeys.wsprPowerDBm: 37,
            SettingsKeys.wsprDutyPct: 20,
        ])
    }

    /// The bundle-ID change moved us to a fresh defaults domain; pull the
    /// RadioFun-era settings across once so nothing resets.
    private static func migrateRadioFunSettings() {
        let marker = "didMigrateFromRadioFun"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: marker),
              let legacy = UserDefaults(suiteName: "com.watsoncj.radiofun") else { return }
        let keys = [
            SettingsKeys.myCallsign, SettingsKeys.myGrid, SettingsKeys.dialFrequencyMHz,
            SettingsKeys.audioDeviceUID, SettingsKeys.audioOutputUID, SettingsKeys.pttPortPath,
            SettingsKeys.txOffsetHz, SettingsKeys.digiMode, SettingsKeys.catPortPath,
            SettingsKeys.catBaud, SettingsKeys.mapStyle, SettingsKeys.autoAnswer,
            SettingsKeys.showWaterfall, SettingsKeys.timeDisplay, SettingsKeys.distanceUnit,
            SettingsKeys.lastCQParity, SettingsKeys.wsprPowerDBm, SettingsKeys.wsprDutyPct,
        ]
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: marker)
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
        // Apple Maps treatment: no title bar, content to the top edge,
        // toolbar items floating over the map
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)

        Window("QSO Log", id: "qso-log") {
            QSOLogView(qsoLog: model.qsoLog)
        }
        .defaultSize(width: 720, height: 420)
        .keyboardShortcut("l", modifiers: .command)

        Settings {
            SettingsView(cat: model.cat, location: model.location)
        }
    }
}
