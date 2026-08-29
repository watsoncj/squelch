import SwiftUI
import os

/// Owns the long-lived model objects and wires decode results into the store.
/// An armed, countdown-pending transmission: a station calling us that
/// auto-answer picked up, or a CQ the hunter wants to chase.
struct PendingReply: Equatable {
    enum Kind: Equatable {
        case callingUs                  // they addressed us — answer per grid/report
        case huntedCQ(CQHunter.Reason)  // their CQ matched the hunt criteria
    }

    let call: String
    let kind: Kind
    let grid: String?    // they sent their grid → we enter as caller
    let report: String?  // they sent a report → we enter as answerer
    let snr: Float
    let theirParity: Int
    let fireAt: Date     // the TX slot the reply goes out in (unless canceled)
    /// They rogered our grid with theirs ("R EN52") — the grid-only
    /// contest exchange is complete; we owe an RR73, nothing more.
    var rogerGrid: String? = nil
}

final class AppModel: ObservableObject {
    let store = DecodeStore()
    let location = LocationProvider()
    let controller = DecodeController()
    let transmit = TransmitController()
    let sequencer = QSOSequencer()
    /// Stations heard using the contest exchange this session — gates
    /// whether the sequencer leads with "R GRID" or a report.
    let contestSpeakers = ContestSpeakers()
    let qsoLog = QSOLog()
    let cat = CATController()
    let waterfall = WaterfallProcessor()
    let stateResolver = StateResolver()
    let wsprNet = WSPRNetService()
    let updater = UpdateChecker()

    @Published var pendingReply: PendingReply?
    /// One-shot request from a toolbar chip's callsign: select and reveal
    /// this decode in the sidebar list (ContentView consumes and clears).
    @Published var focusedMessageID: DecodedMessage.ID?
    @Published private(set) var wsprBeaconEnabled = false
    /// Decided one window ahead so the panel can announce it (pure
    /// per-window randomness read as "broken" during dry streaks).
    @Published private(set) var beaconNextWindowWillTX = false
    private var beaconWindowsSinceTX = 0
    private var beaconWork: DispatchWorkItem?
    private var lastBeaconWindow: Double = -1
    static let beaconLog = Logger(subsystem: "com.watsoncj.squelch", category: "beacon")

    /// Partner we gave up on mid-exchange; their straggling reply within
    /// the grace window re-engages even with auto-answer off — the user
    /// already chose to work this station.
    private var recentlyAbandoned: (call: String, at: Date)?
    private static let abandonGraceSeconds: TimeInterval = 120

    /// Calls the hunter must leave alone this session: hunts the user
    /// canceled, and partners who never answered — without this the same
    /// CQ re-arms every 15 s slot.
    private var huntPassedCalls: Set<String> = []

    /// Demo mode must never key the radio, even with PTT configured.
    let demoMode = CommandLine.arguments.contains("--demo")

    init() {
        // Contest time pressure zeroes the sequencer's busy-pass patience;
        // read live so flipping the selector mid-session takes effect
        sequencer.isContestActive = {
            let contest = UserDefaults.standard.string(forKey: SettingsKeys.activeContest) ?? ""
            return !contest.trimmingCharacters(in: .whitespaces).isEmpty
        }
        // Grid-only exchange (WW Digi / VHF style) follows the active
        // contest: the same predicate that shapes its Cabrillo lines and
        // withholds license grids from its log — nothing to remember to
        // switch on, nothing to leak into everyday QSOs
        sequencer.isContestExchange = {
            let contest = UserDefaults.standard.string(forKey: SettingsKeys.activeContest) ?? ""
            return CabrilloExporter.exchangeStyle(for: contest) == .gridOnly
        }
        sequencer.modeName = { DigiMode.current == .ft4 ? "FT4" : "FT8" }
        sequencer.speaksContestExchange = { [contestSpeakers] in contestSpeakers.speaks($0) }
        sequencer.onQSOComplete = { [qsoLog, store, cat] record in
            var record = record
            // The exchange itself often never carries the grid (answerer
            // side, mid-exchange entries) — backfill from the station cache
            if record.partnerGrid == nil, let grid = store.stations[record.partner]?.grid {
                record.partnerGrid = grid.uppercased()
            }
            // Active contest (QSO log window's selector) stamps every
            // auto-logged QSO so the per-contest Cabrillo export just works
            if record.contest == nil,
               let contest = UserDefaults.standard.string(forKey: SettingsKeys.activeContest)?
                   .trimmingCharacters(in: .whitespaces),
               !contest.isEmpty {
                record.contest = contest
            }
            // Radio's power setting at completion — the log's TX-health
            // trail (the August asymmetry hunt earned this field)
            if record.txPowerWatts == nil {
                record.txPowerWatts = cat.radioPowerWatts
            }
            qsoLog.append(record)
            // Enrich with license data (name, state, precise grid) — one
            // session-cached HamDB request; DX calls just come back missing
            CallsignDirectory.shared.lookup(record.partner) { [qsoLog] result in
                guard case .found(let entry) = result,
                      // Re-read by id: the user may have edited it meanwhile
                      var current = qsoLog.records.first(where: { $0.id == record.id })
                else { return }
                if current.merge(entry) {
                    qsoLog.update(current)
                }
            }
        }
        sequencer.onQSOAbandoned = { [weak self] partner in
            self?.recentlyAbandoned = (partner, Date())
            // A station that never came back is a station the hunter
            // shouldn't chase again this session
            self?.huntPassedCalls.insert(partner)
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
            if self.controller.mode == .wspr,
               !self.demoMode,
               UserDefaults.standard.bool(forKey: SettingsKeys.wsprUpload) {
                self.wsprNet.uploadSpots(
                    results: results,
                    slotStart: slotStart,
                    dialMHz: dial > 0 ? dial : 28.1246
                )
            }
            self.runSequencer(results: results, slotStart: slotStart)
        }
        if CommandLine.arguments.contains("--demo") {
            seedDemoData()
        } else {
            // Demo runs stay pristine for screenshots/GUI driving — no
            // update chip materializing mid-capture
            Task { @MainActor [updater] in
                updater.startAutomaticChecks()
            }
        }
    }

    /// After each receive slot: update the QSO state machine and, if it wants
    /// the upcoming slot, key up. The encoded audio's 0.5 s lead keeps us
    /// inside FT8's timing tolerance even though we start slightly late.
    private func runSequencer(results: [FT8Result], slotStart: Date) {
        let period = controller.mode.slotSeconds
        let parity = Int(slotStart.timeIntervalSince1970 / period) % 2
        sequencer.myCall = UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? ""
        sequencer.myGrid4 = String((location.effectiveGrid ?? "").prefix(4))
        // Refreshed every slot like the call/grid, so flyout changes to
        // the CQ flavor and duty cycle apply mid-run
        sequencer.cqModifier = Self.activeCQModifier()
        sequencer.cqSlotInterval = max(1, UserDefaults.standard.integer(forKey: SettingsKeys.cqSlotInterval))

        // Who's been heard speaking the contest exchange — must precede
        // ingest, so a "CQ WW" answered this very slot already counts
        contestSpeakers.note(results.map(\.text), myCall: sequencer.myCall)
        // Always ingest — even idle, a straggling RR73 from an abandoned
        // exchange can complete and log a QSO (ingest no-ops otherwise)
        sequencer.ingest(
            decodes: results.map { QSOSequencer.Decode(text: $0.text, snr: $0.snr) },
            slotParity: parity
        )
        if sequencer.mode == .idle {
            considerAutoAnswer(results: results, theirParity: parity, period: period)
            considerHunt(results: results, theirParity: parity, period: period)
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
        let myCall = (UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? "").uppercased()
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
            kind: .callingUs,
            grid: candidate.grid,
            report: candidate.report,
            snr: candidate.snr,
            theirParity: theirParity,
            fireAt: QSOSequencer.nextTXWindow(parity: 1 - theirParity, period: period, after: Date(), minLead: 5),
            rogerGrid: candidate.rogerGrid
        )
    }

    /// While idle with hunt mode on: a CQ from a "new one" (DX, unworked
    /// state, unworked country) arms the same countdown-gated reply as
    /// auto-answer — the chip announces the catch and Cancel keeps us
    /// quiet. Auto-answer wins when both trigger in a slot (someone
    /// calling us beats someone calling everyone).
    private func considerHunt(results: [FT8Result], theirParity: Int, period: Double) {
        guard pendingReply == nil,
              UserDefaults.standard.bool(forKey: SettingsKeys.huntEnabled),
              DigiMode.current.supportsQSO else { return }
        let myCall = (UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? "").uppercased()
        guard !myCall.isEmpty else { return }
        // A hunt that fires into a TX-illegal band would error out every
        // slot — don't arm at all
        let dial = UserDefaults.standard.double(forKey: SettingsKeys.dialFrequencyMHz)
        guard TransmitController.isTXLegalMHz(dial) else { return }

        let flags = CQHunter.Flags(
            dx: UserDefaults.standard.bool(forKey: SettingsKeys.huntDX),
            newStates: UserDefaults.standard.bool(forKey: SettingsKeys.huntNewStates),
            newCountries: UserDefaults.standard.bool(forKey: SettingsKeys.huntNewCountries),
            ww: UserDefaults.standard.bool(forKey: SettingsKeys.huntWW)
        )
        let stateForGrid: (String) -> String? = { [stateResolver] grid in
            stateResolver.state(forGrid: grid, isUS: true)
        }
        let worked = CQHunter.workedSets(records: qsoLog.records, stateForGrid: stateForGrid)
        let contest = (UserDefaults.standard.string(forKey: SettingsKeys.activeContest) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard let candidate = CQHunter.pick(
            decodes: results.map { ($0.text, $0.snr) },
            myCall: myCall,
            flags: flags,
            workedCalls: CQHunter.dupeCalls(
                records: qsoLog.records,
                dialMHz: dial,
                contest: contest.isEmpty ? nil : contest
            ),
            workedStates: worked.states,
            workedCountries: worked.countries,
            passedCalls: huntPassedCalls,
            stateForGrid: stateForGrid
        ) else { return }

        pendingReply = PendingReply(
            call: candidate.call,
            kind: .huntedCQ(candidate.reason),
            grid: candidate.grid,
            report: nil,
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
    ) -> (call: String, grid: String?, report: String?, snr: Float, rogerGrid: String?)? {
        for result in results {
            let tokens = result.text.uppercased().split(separator: " ").map(String.init)
            // Brackets stripped: our call arrives hashed ("<W0CJW/AG> …")
            // from partners when it's nonstandard
            let addressee = tokens[0].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            guard tokens.count >= 3, addressee == myCall.uppercased() else { continue }
            let from = tokens[1].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            guard FT8MessageParser.isCallsign(from) else { continue }
            let payload = tokens.dropFirst(2).joined(separator: " ")

            let grid = FT8MessageParser.isGrid(payload) ? payload : nil
            let report = QSOSequencer.isReport(payload) ? payload : nil
            let rogerGrid = QSOSequencer.rogerGridValue(payload)
            guard grid != nil || report != nil || rogerGrid != nil else { continue }
            return (from, grid, report, result.snr, rogerGrid)
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
        switch pending.kind {
        case .huntedCQ:
            sequencer.replyTo(call: pending.call, snr: pending.snr, cqParity: pending.theirParity, grid: pending.grid)
        case .callingUs:
            if let grid = pending.rogerGrid {
                sequencer.engageWithRogerGrid(call: pending.call, grid: grid, snr: pending.snr, theirParity: pending.theirParity)
            } else if let grid = pending.grid {
                sequencer.engageAsCaller(call: pending.call, grid: grid, snr: pending.snr, theirParity: pending.theirParity)
            } else if let report = pending.report {
                sequencer.engageAsAnswerer(call: pending.call, report: report, snr: pending.snr, theirParity: pending.theirParity)
            }
        }
    }

    /// Toolbar chip callsign clicked: hand the list this station's most
    /// recent decode to select and reveal.
    func focusMostRecent(callsign: String) {
        let call = callsign.uppercased()
        focusedMessageID = store.messages.first { $0.callsign?.uppercased() == call }?.id
    }

    func cancelPendingReply() {
        // Canceling a hunt means "not this one" — don't re-arm on their
        // next CQ this session
        if let pending = pendingReply, case .huntedCQ = pending.kind {
            huntPassedCalls.insert(pending.call)
        }
        pendingReply = nil
    }

    /// Re-arming the hunt starts fresh: passed-over stations are back in
    /// season.
    func huntToggled(on: Bool) {
        if on { huntPassedCalls.removeAll() }
    }

    // MARK: - WSPR beacon

    func setWSPRBeacon(_ on: Bool) {
        beaconWork?.cancel()
        beaconWork = nil
        let changed = wsprBeaconEnabled != on
        wsprBeaconEnabled = on
        if changed {
            wsprNet.beaconStateChanged(enabled: on)
        }
        if on {
            beaconWindowsSinceTX = 0
            decideNextBeaconWindow()
            scheduleBeaconTick()
            syncWSPRPowerFromRadio()
        }
    }

    /// Honest advertising, radio-is-truth: read the rig's operative power
    /// via CAT and advertise the nearest standard WSPR dBm. NEVER writes to
    /// the radio — the power knob belongs to the operator.
    private func syncWSPRPowerFromRadio() {
        guard cat.isConnected, let watts = cat.radioPowerWatts, watts > 0 else { return }
        UserDefaults.standard.set(Self.wsprDBm(forWatts: watts), forKey: SettingsKeys.wsprPowerDBm)
    }

    /// Nearest value on WSPR's conventional power ladder (…, 30, 33, 37,
    /// 40, 43, 47, 50 dBm — i.e. 1, 2, 5, 10, 20, 50, 100 W).
    static func wsprDBm(forWatts watts: Int) -> Int {
        let ladder = [0, 3, 7, 10, 13, 17, 20, 23, 27, 30, 33, 37, 40, 43, 47, 50, 53, 57, 60]
        let dbm = 10.0 * log10(Double(watts)) + 30.0
        return ladder.min(by: { abs(Double($0) - dbm) < abs(Double($1) - dbm) }) ?? 37
    }

    /// Force the upcoming window to transmit (verification / impatience).
    func forceBeaconNextWindow() {
        guard wsprBeaconEnabled else { return }
        beaconNextWindowWillTX = true
        Self.beaconLog.info("user forced TX next window")
    }

    /// Pure decision for one upcoming window. `justTransmitted` always
    /// skips (listen after you transmit — no back-to-back beacon windows);
    /// then the bounded-gap force; then the duty roll.
    static func beaconDecision(dutyPct: Int, windowsSinceTX: Int, justTransmitted: Bool, roll: Double) -> Bool {
        if justTransmitted { return false }
        let duty = max(dutyPct, 1)
        let maxGapWindows = max(2, 2 * Int((100.0 / Double(duty)).rounded()))
        if windowsSinceTX + 1 >= maxGapWindows { return true }
        return roll < Double(duty)
    }

    /// Duty-cycle roll with a bounded gap: after ~2× the expected interval
    /// without a TX, the next window transmits regardless.
    private func decideNextBeaconWindow() {
        let duty = UserDefaults.standard.integer(forKey: SettingsKeys.wsprDutyPct)
        beaconNextWindowWillTX = Self.beaconDecision(
            dutyPct: duty,
            windowsSinceTX: beaconWindowsSinceTX,
            justTransmitted: transmit.anyTXActive && beaconWindowsSinceTX == 0,
            roll: Double.random(in: 0..<100)
        )
        Self.beaconLog.info("decide: willTX=\(self.beaconNextWindowWillTX) quietWindows=\(self.beaconWindowsSinceTX) duty=\(duty)")
    }

    private func scheduleBeaconTick() {
        guard wsprBeaconEnabled else { return }
        // Exactly ONE live chain: an un-cancelled pending tick here would
        // fork a parallel timer chain — each one inflating the quiet-window
        // counter and re-rolling the TX decision every window (seen in the
        // field as way-over-duty transmit rates)
        beaconWork?.cancel()
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
        // Account each wall-clock window exactly once: a duplicate chain's
        // fire dies here (no counter bump, no re-roll, and — by returning
        // before the reschedule — no successor, so stray chains self-cull).
        let window = (Date().timeIntervalSince1970 / DigiMode.wspr.slotSeconds).rounded(.down)
        guard window != lastBeaconWindow else {
            Self.beaconLog.error("duplicate fire for window \(window, format: .fixed(precision: 0)) — parallel chain culled")
            return
        }
        lastBeaconWindow = window

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
            Self.beaconLog.info("window: quiet (willTX was \(self.beaconNextWindowWillTX)) quietWindows=\(self.beaconWindowsSinceTX)")
            return
        }

        let call = UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? ""
        let grid4 = String((location.effectiveGrid ?? "").prefix(4))
        guard grid4.count == 4 else {
            beaconWindowsSinceTX += 1
            return
        }
        syncWSPRPowerFromRadio() // pick up knob changes since arming, BEFORE reading dBm
        let dbm = UserDefaults.standard.integer(forKey: SettingsKeys.wsprPowerDBm)
        let power = dbm > 0 ? dbm : 37
        let offset = Double.random(in: 1420...1580)
        if transmit.transmitWSPR(call: call, grid4: grid4, dbm: power, offsetHz: offset) {
            beaconWindowsSinceTX = 0
            Self.beaconLog.info("window: TRANSMIT \(power) dBm at \(offset, format: .fixed(precision: 0)) Hz")
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
        let myCall = UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? ""
        sequencer.myCall = myCall
        sequencer.myGrid4 = String((location.effectiveGrid ?? "").prefix(4))
        sequencer.cqModifier = Self.activeCQModifier()
        sequencer.cqSlotInterval = max(1, UserDefaults.standard.integer(forKey: SettingsKeys.cqSlotInterval))
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

    /// The stored CQ flavor, if it's one the FT8 payload can carry —
    /// anything else (mid-edit custom text) falls back to plain CQ
    /// rather than failing at encode time every slot.
    static func activeCQModifier() -> String {
        let raw = (UserDefaults.standard.string(forKey: SettingsKeys.cqModifier) ?? "")
            .trimmingCharacters(in: .whitespaces).uppercased()
        return QSOSequencer.isValidCQModifier(raw) ? raw : ""
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
        sequencer.myCall = UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? ""
        sequencer.myGrid4 = String((location.effectiveGrid ?? "").prefix(4))
        let theirParity = message.slotParity(slotSeconds: period)

        if message.isCQ {
            sequencer.replyTo(call: call, snr: message.snr, cqParity: theirParity, grid: message.grid)
        } else if QSOSequencer.isReport(message.payloadToken) {
            // They sent us a report — we owe a roger
            sequencer.engageAsAnswerer(call: call, report: message.payloadToken, snr: message.snr, theirParity: theirParity)
        } else if let grid = QSOSequencer.rogerGridValue(message.payloadToken) {
            // They rogered our grid with theirs — contest exchange done, RR73 owed
            sequencer.engageWithRogerGrid(call: call, grid: grid, snr: message.snr, theirParity: theirParity)
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
                        SettingsKeys.dialFrequencyMHz: 14.074,
            SettingsKeys.digiMode: DigiMode.ft8.rawValue,
            SettingsKeys.catBaud: 0, // auto-detect
            SettingsKeys.wsprPowerDBm: 37,
            SettingsKeys.wsprDutyPct: 20,
            SettingsKeys.cqSlotInterval: 1,
            SettingsKeys.autoUpdateCheck: true,
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
                wsprNet: model.wsprNet,
                updater: model.updater,
                actions: model
            )
            .frame(minWidth: 980, minHeight: 620)
        }
        // Apple Maps treatment: no title bar, content to the top edge,
        // toolbar items floating over the map
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    model.updater.checkNow()
                }
            }
        }

        Window("QSO Log", id: "qso-log") {
            QSOLogView(qsoLog: model.qsoLog, stateResolver: model.stateResolver)
        }
        .defaultSize(width: 720, height: 420)
        .keyboardShortcut("l", modifiers: .command)

        Settings {
            SettingsView(cat: model.cat, location: model.location, controller: model.controller, wsprNet: model.wsprNet, updater: model.updater)
        }
    }
}
