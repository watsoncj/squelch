import Foundation

/// A completed contact — auto-sequenced FT8 or manually logged.
struct QSORecord: Identifiable, Codable {
    let id: UUID
    let partner: String
    var partnerGrid: String?
    let reportSent: String
    let reportReceived: String?
    let start: Date
    let end: Date
    let dialFrequencyMHz: Double
    let mode: String // "FT8", "SSB", …
    // Later additions, optional so pre-existing JSONL lines still decode
    var name: String? = nil
    var notes: String? = nil
    var state: String? = nil   // 2-letter US/CA region code from license lookup
    var country: String? = nil // license-country name from lookup
    var contest: String? = nil // contest name, e.g. "ARRL-VHF" — groups Cabrillo exports
    var txPowerWatts: Int? = nil // radio's power setting (CAT) when the QSO completed
}

/// FT8 auto-sequence state machine. Pure logic, no I/O: the app calls
/// `ingest` with each receive slot's decodes and `transmission` before each
/// transmit slot; QSOs alternate 15 s slots by parity (even/odd).
///
/// Caller side (we CQ'd):  CQ → [they: MYCALL X GRID] → X MYCALL ±NN
///                         → [they: MYCALL X R±NN] → X MYCALL RR73 ✓
///                         (they may skip R±NN and sign off outright —
///                          that closes it too: ✓ then X MYCALL 73)
/// Answerer side:          X MYCALL GRID → [they: MYCALL X ±NN]
///                         → X MYCALL R±NN → [they: RR73] ✓ → X MYCALL 73
final class QSOSequencer: ObservableObject {
    struct Decode {
        let text: String
        let snr: Float
    }

    enum Mode: Equatable {
        case idle
        case cqLoop          // calling CQ, waiting for an answer
        case qsoAsCaller     // exchange in progress, we initiated with CQ
        case qsoAsAnswerer   // exchange in progress, we answered their CQ
    }

    private enum Awaiting {
        case answer       // caller: a station answering our CQ
        case rogerReport  // caller: R±NN
        case report       // answerer: ±NN
        case rr73         // answerer: RR73/RRR
        case none         // final courtesy message, nothing required back
    }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var stateDescription = "TX idle"
    @Published private(set) var currentPartner: String?

    var myCall = ""
    var myGrid4 = ""
    /// Directed-CQ modifier riding between CQ and our call ("DX", "POTA").
    /// The app validates with `isValidCQModifier` before setting; read
    /// fresh at each CQ transmission, so mid-run changes take effect.
    var cqModifier = ""
    /// Transmit every Nth of our slots while CQing (1 = every slot).
    /// Skipped slots are pure listen — an answer landing in one is
    /// engaged immediately; only the CQ itself is throttled.
    var cqSlotInterval = 1
    var maxRetries = 3
    var maxUnansweredCQ = 10
    /// Extra no-progress TX slots tolerated while the partner is heard
    /// working OTHER stations — pileup runners service several callers
    /// between our slots, so busy is not gone. Bounds total patience.
    var maxBusyPasses = 10
    /// How long after giving up a straggling RR73/73 still completes
    /// (and logs) the exchange.
    var lateSignoffGrace: TimeInterval = 300
    /// Pileup overflow callers are only answered if heard again this
    /// recently — three slots of silence means they've likely moved on.
    var queuedCallerMaxAge: TimeInterval = 45
    /// Retry budget when answering a queued caller — deliberately smaller
    /// than `maxRetries`: they answered a while ago and may have lost
    /// interest, and the rest of the line shouldn't wait to find out.
    var queuedCallerRetries = 1
    /// Whether a contest is running — injectable; the app wires this to
    /// the active-contest setting. Under contest time pressure the busy
    /// patience is zeroed: slots spent waiting in a runner's line are
    /// slots not spent making QSOs, and a bailed exchange still logs via
    /// `abandoned` if their signoff straggles in.
    var isContestActive: () -> Bool = { false }
    /// Clock, injectable for tests.
    var now: () -> Date = { Date() }
    var onQSOComplete: ((QSORecord) -> Void)?
    /// Fired when we give up on a partner mid-exchange (retries exhausted) —
    /// lets the app re-engage if their reply straggles in moments later.
    var onQSOAbandoned: ((String) -> Void)?

    private(set) var txParity = 0
    private var currentTX: String?
    /// Our-parity slots seen this CQ loop, for the duty-cycle skip.
    private var cqSlotCounter = 0
    private var awaiting: Awaiting = .none
    private var partner: String? {
        didSet { currentPartner = partner }
    }
    private var partnerGrid: String?
    private var reportSent = ""
    private var reportReceived: String?
    private var qsoStart: Date?
    private var retriesLeft = 0
    private var unansweredCQ = 0
    private var respondedSinceLastTX = true
    private var finalMessagesLeft = 0 // remaining sends of a courtesy RR73/73
    private var resumeCQAfterQSO = false
    /// Who the partner was heard working this receive slot (or "CQ") —
    /// proof of life that pauses the retry countdown.
    private var partnerBusyWith: String?
    private var busyPassesLeft = 0
    /// Busy patience granted at each engagement — none during a contest.
    private var busyPassBudget: Int { isContestActive() ? 0 : maxBusyPasses }

    /// Exchanges given up on with both reports already exchanged, kept so
    /// a straggling signoff still completes and logs the contact — pileup
    /// runners routinely acknowledge minutes after our last slot. Keyed
    /// by partner call; survives across subsequent QSOs, pruned by age.
    private struct AbandonedExchange {
        let partnerGrid: String?
        let reportSent: String
        let reportReceived: String?
        let qsoStart: Date
        let abandonedAt: Date
    }
    private var abandoned: [String: AbandonedExchange] = [:]

    /// Pileup overflow: stations that answered our CQ while we were
    /// mid-exchange with someone else. The freshest one is answered
    /// directly after the current QSO — a runner shouldn't make the
    /// line sit through another CQ. Keyed by call, refreshed each time
    /// they're heard again, pruned by `queuedCallerMaxAge`.
    private struct QueuedCaller {
        let grid: String?
        let snr: Float
        let heardAt: Date
    }
    private var queuedCallers: [String: QueuedCaller] = [:]

    /// The mirror of `abandoned`: QSOs we completed and LOGGED whose
    /// partner may have lost our final. A repeated roger from them within
    /// the grace window earns a courtesy re-acknowledgment (never a
    /// second log entry) — we expect runners to do this for us, so we
    /// do it for them. Keyed by call, value is completion time.
    private var recentlyCompleted: [String: Date] = [:]
    /// One-shot courtesy re-ack queued for the next TX slot of the given
    /// parity; only ever sent from idle/cqLoop.
    private var courtesyTX: (text: String, parity: Int)?

    // MARK: - Commands

    func startCQ(parity: Int) {
        reset()
        mode = .cqLoop
        txParity = parity
        currentTX = cqText
        awaiting = .answer
        resumeCQAfterQSO = true
        describe("Calling \(cqLabel) (\(parityName(parity)) slots)")
    }

    /// A CQ run is on — calling now, or mid-QSO and returning to the
    /// loop afterward. Drives the toolbar button's lit state.
    var cqRunActive: Bool {
        mode == .cqLoop || (mode != .idle && resumeCQAfterQSO)
    }

    func replyTo(call: String, snr: Float, cqParity: Int, grid: String? = nil) {
        reset()
        mode = .qsoAsAnswerer
        partner = call
        abandoned[call] = nil // re-engaged: the live exchange supersedes the stash
        queuedCallers[call] = nil // ditto: they're no longer waiting in line
        partnerGrid = grid // from their CQ — they won't send it again
        txParity = 1 - cqParity
        reportSent = Self.formatReport(snr)
        currentTX = "\(call) \(myCall) \(myGrid4)".trimmingCharacters(in: .whitespaces)
        awaiting = .report
        retriesLeft = maxRetries
        busyPassesLeft = busyPassBudget
        qsoStart = Date()
        resumeCQAfterQSO = false
        describe("Answering \(call)")
    }

    /// Engage with a station that answered us (or our stopped CQ) with a
    /// grid: we owe them a report. Enters mid-exchange as the caller side.
    func engageAsCaller(call: String, grid: String?, snr: Float, theirParity: Int) {
        reset()
        mode = .qsoAsCaller
        partner = call
        abandoned[call] = nil // re-engaged: the live exchange supersedes the stash
        queuedCallers[call] = nil // ditto: they're no longer waiting in line
        partnerGrid = grid
        txParity = 1 - theirParity
        reportSent = Self.formatReport(snr)
        currentTX = "\(call) \(myCall) \(reportSent)"
        awaiting = .rogerReport
        retriesLeft = maxRetries
        busyPassesLeft = busyPassBudget
        qsoStart = Date()
        resumeCQAfterQSO = false
        describe("Answering \(call) with report")
    }

    /// Engage with a station that sent us a signal report: we owe them a
    /// roger. Enters mid-exchange as the answerer side (the "late reply
    /// after give-up" recovery).
    func engageAsAnswerer(call: String, report: String, snr: Float, theirParity: Int, grid: String? = nil) {
        reset()
        mode = .qsoAsAnswerer
        partner = call
        abandoned[call] = nil // re-engaged: the live exchange supersedes the stash
        queuedCallers[call] = nil // ditto: they're no longer waiting in line
        partnerGrid = grid
        reportReceived = report
        txParity = 1 - theirParity
        reportSent = Self.formatReport(snr)
        currentTX = "\(call) \(myCall) R\(reportSent)"
        awaiting = .rr73
        retriesLeft = maxRetries
        busyPassesLeft = busyPassBudget
        qsoStart = Date()
        resumeCQAfterQSO = false
        describe("Roger report to \(call)")
    }

    /// The next slot-start of the given parity, at least `minLead` seconds
    /// out — the window an armed auto-answer will fire in.
    static func nextTXWindow(parity: Int, period: Double, after date: Date, minLead: TimeInterval) -> Date {
        var t = (date.timeIntervalSince1970 / period).rounded(.up) * period
        while Int(t / period) % 2 != parity || t - date.timeIntervalSince1970 < minLead {
            t += period
        }
        return Date(timeIntervalSince1970: t)
    }

    func stop() {
        reset()
        describe("TX idle")
    }

    // MARK: - Slot hooks

    /// Feed decodes from a completed receive slot (opposite parity to ours).
    /// Called every slot, even while idle — late signoffs from abandoned
    /// exchanges arrive after we've moved on.
    func ingest(decodes: [Decode], slotParity: Int) {
        let brackets = CharacterSet(charactersIn: "<>")
        let cutoff = now().addingTimeInterval(-lateSignoffGrace)
        abandoned = abandoned.filter { $0.value.abandonedAt >= cutoff }
        recentlyCompleted = recentlyCompleted.filter { $0.value >= cutoff }
        let queueCutoff = now().addingTimeInterval(-queuedCallerMaxAge)
        queuedCallers = queuedCallers.filter { $0.value.heardAt >= queueCutoff }

        for decode in decodes {
            let tokens = decode.text.uppercased().split(separator: " ").map(String.init)
            guard tokens.count >= 3,
                  tokens[0].trimmingCharacters(in: brackets) == myCall.uppercased() else { continue }
            let from = tokens[1].trimmingCharacters(in: brackets)
            guard from != partner else { continue }
            let payload = tokens[2]

            // A straggling RR73/73 from a partner we gave up on: the
            // exchange was complete on the air the whole time — log it,
            // whatever state we're in now. (No TX: we may be mid-QSO
            // with someone else.)
            if Self.isSignoff(payload), let pending = abandoned.removeValue(forKey: from) {
                let dial = UserDefaults.standard.double(forKey: SettingsKeys.dialFrequencyMHz)
                onQSOComplete?(QSORecord(
                    id: UUID(),
                    partner: from,
                    partnerGrid: pending.partnerGrid,
                    reportSent: pending.reportSent,
                    reportReceived: pending.reportReceived,
                    start: pending.qsoStart,
                    end: now(),
                    dialFrequencyMHz: dial,
                    mode: "FT8"
                ))
                if mode == .idle || mode == .cqLoop {
                    describe("Late \(payload) from \(from) — QSO logged")
                }
                continue
            }

            // The mirror case: a partner we already logged lost our final
            // and is still asking. Re-acknowledge — from idle any slot,
            // from cqLoop only in our own slot (in place of one CQ, never
            // transmitting both parities) — and never mid-exchange.
            guard recentlyCompleted[from] != nil,
                  mode == .idle || (mode == .cqLoop && 1 - slotParity == txParity)
            else { continue }
            if Self.rogerReportValue(payload) != nil {
                courtesyTX = ("\(from) \(myCall) RR73", 1 - slotParity)
                describe("\(from) missed our RR73 — re-acknowledging")
            } else if payload == "RR73" || payload == "RRR" {
                courtesyTX = ("\(from) \(myCall) 73", 1 - slotParity)
                describe("\(from) missed our 73 — re-sending")
            }
        }

        guard mode != .idle, slotParity != txParity else { return }
        for decode in decodes {
            let tokens = decode.text.uppercased().split(separator: " ").map(String.init)
            // Partners hash OUR call (h22) when it's nonstandard — a reply
            // arrives as "<W0CJW/AG> K1ABC R-05"; match brackets-stripped
            let addressee = tokens[0].trimmingCharacters(in: brackets)
            // Our partner transmitting to ANYONE is proof of life — note
            // who, so the retry countdown pauses instead of burning
            if let partner, tokens.count >= 2, addressee != myCall.uppercased(),
               tokens[1].trimmingCharacters(in: brackets) == partner {
                partnerBusyWith = addressee
            }
            guard tokens.count >= 2, addressee == myCall.uppercased() else { continue }
            let from = tokens[1].trimmingCharacters(in: brackets)
            let payload = tokens.count >= 3 ? tokens[2] : ""
            // Pileup overflow while we're running: a CQ-shaped answer from
            // someone who isn't the current partner joins the line
            if resumeCQAfterQSO, mode == .qsoAsCaller, from != partner,
               FT8MessageParser.isGrid(payload) || Self.isReport(payload) || payload.isEmpty {
                queuedCallers[from] = QueuedCaller(
                    grid: FT8MessageParser.isGrid(payload) ? payload : nil,
                    snr: decode.snr,
                    heardAt: now()
                )
            }
            handle(from: from, payload: payload, snr: decode.snr)
        }
    }

    /// Ask what to transmit in the slot of the given parity (nil = stay quiet).
    func transmission(forSlotParity parity: Int) -> String? {
        // Courtesy re-ack for an already-logged QSO whose final never
        // made it across — one shot, no QSO state touched
        if let courtesy = courtesyTX,
           mode == .idle || mode == .cqLoop,
           parity == courtesy.parity {
            courtesyTX = nil
            return courtesy.text
        }

        guard mode != .idle, parity == txParity, let tx = currentTX else { return nil }

        // Duty cycle: while CQing, transmit only every Nth of our slots.
        // The skip returns BEFORE the no-progress accounting, so listening
        // slots never burn the unanswered-CQ budget; `handle` still
        // engages an answer that lands in one.
        if mode == .cqLoop {
            let due = cqSlotCounter % max(1, cqSlotInterval) == 0
            cqSlotCounter += 1
            if !due {
                describe("Listening between \(cqLabel) calls")
                return nil
            }
        }

        if !respondedSinceLastTX {
            // No progress since our last transmission
            if mode == .cqLoop {
                unansweredCQ += 1
                if unansweredCQ >= maxUnansweredCQ {
                    stop()
                    describe("CQ stopped: no answers after \(maxUnansweredCQ) calls")
                    return nil
                }
            } else if awaiting == .none {
                // Courtesy message already sent; wind down
                finalMessagesLeft -= 1
                if finalMessagesLeft < 0 {
                    finishQSOSession()
                    return transmission(forSlotParity: parity) // may CQ again
                }
            } else if let other = partnerBusyWith, busyPassesLeft > 0 {
                // Heard working someone else (or CQing between customers):
                // busy is not gone — stay in line without burning a retry
                busyPassesLeft -= 1
                describe(other == "CQ"
                         ? "\(partner ?? "?") is CQing — staying in line"
                         : "\(partner ?? "?") is working \(other) — staying in line")
            } else {
                retriesLeft -= 1
                if retriesLeft < 0 {
                    describe("No reply from \(partner ?? "?") — giving up")
                    if let partner {
                        // Both reports made it across → a late signoff can
                        // still complete this; remember what we'd log
                        if let qsoStart, reportReceived != nil {
                            abandoned[partner] = AbandonedExchange(
                                partnerGrid: partnerGrid,
                                reportSent: reportSent,
                                reportReceived: reportReceived,
                                qsoStart: qsoStart,
                                abandonedAt: now()
                            )
                        }
                        onQSOAbandoned?(partner)
                    }
                    finishQSOSession()
                    return transmission(forSlotParity: parity)
                }
            }
        }
        respondedSinceLastTX = false
        partnerBusyWith = nil // per-slot evidence, consumed above
        if mode == .cqLoop {
            // Rebuild from the live modifier — a flavor change mid-run
            // shapes this very call, and the description tracks it
            currentTX = cqText
            describe("Calling \(cqLabel) (\(parityName(txParity)) slots)")
            return cqText
        }
        return tx
    }

    // MARK: - Message handling

    private func handle(from: String, payload: String, snr: Float) {
        switch (mode, awaiting) {
        case (.cqLoop, .answer):
            // Anyone answering our CQ with a grid (or a bare report)
            guard FT8MessageParser.isGrid(payload) || Self.isReport(payload) || payload.isEmpty else { return }
            courtesyTX = nil // live exchange outranks a queued re-ack
            partner = from
            queuedCallers[from] = nil // now the live partner, not in line
            partnerGrid = FT8MessageParser.isGrid(payload) ? payload : nil
            // A bare-report answer already carries their report — keep it, to
            // log and to arm the late-signoff stash if the exchange stalls
            reportReceived = Self.isReport(payload) ? payload : nil
            reportSent = Self.formatReport(snr)
            qsoStart = Date()
            mode = .qsoAsCaller
            awaiting = .rogerReport
            retriesLeft = maxRetries
            busyPassesLeft = busyPassBudget
            currentTX = "\(from) \(myCall) \(reportSent)"
            markResponded("Answering \(from)\(partnerGrid.map { " (\($0))" } ?? "")")

        case (.qsoAsCaller, .rogerReport):
            guard from == partner else { return }
            if let report = Self.rogerReportValue(payload) {
                reportReceived = report
                completeQSO()
                currentTX = "\(from) \(myCall) RR73"
                awaiting = .none
                finalMessagesLeft = 0 // one RR73; re-sent only if they repeat R±NN
                markResponded("RR73 to \(from)")
            } else if Self.isSignoff(payload) {
                // They skipped R±NN and closed out — runners do this when a
                // bare report answered our CQ. Both reports crossed, so the
                // contact is good: log it and return the courtesy 73.
                completeQSO()
                windDown(finalTo: from)
            } else if FT8MessageParser.isGrid(payload) || Self.isReport(payload) {
                // They repeated their answer — resend our report
                markResponded("Repeating report to \(from)")
            }

        case (.qsoAsAnswerer, .report):
            guard from == partner else { return }
            if Self.isReport(payload) {
                reportReceived = payload
                currentTX = "\(from) \(myCall) R\(reportSent)"
                awaiting = .rr73
                retriesLeft = maxRetries
                busyPassesLeft = busyPassBudget
                markResponded("Roger report to \(from)")
            } else if Self.isSignoff(payload) {
                completeQSO()
                windDown(finalTo: from)
            }

        case (.qsoAsAnswerer, .rr73):
            guard from == partner else { return }
            if Self.isSignoff(payload) {
                completeQSO()
                windDown(finalTo: from)
            } else if Self.isReport(payload) {
                // They didn't hear our roger — resend it
                markResponded("Repeating roger to \(from)")
            }

        case (.qsoAsCaller, .none):
            // Post-RR73: they repeat R±NN if they missed it, or send 73
            guard from == partner else { return }
            if Self.rogerReportValue(payload) != nil {
                markResponded("Repeating RR73 to \(from)")
            } else if Self.isSignoff(payload) {
                finishQSOSession()
            }

        case (.qsoAsAnswerer, .none):
            // Post-73: a repeated RR73/RRR means they missed our courtesy
            // 73 — send it again. Their own 73 means everyone's done.
            guard from == partner else { return }
            if payload == "RR73" || payload == "RRR" {
                markResponded("Repeating 73 to \(from)")
            } else if payload == "73" {
                finishQSOSession()
            }

        default:
            break
        }
    }

    private func windDown(finalTo call: String) {
        currentTX = "\(call) \(myCall) 73"
        awaiting = .none
        finalMessagesLeft = 0 // send 73 once
        markResponded("73 to \(call)")
    }

    private func completeQSO() {
        guard let partner, let qsoStart else { return }
        let dial = UserDefaults.standard.double(forKey: SettingsKeys.dialFrequencyMHz)
        let record = QSORecord(
            id: UUID(),
            partner: partner,
            partnerGrid: partnerGrid,
            reportSent: reportSent,
            reportReceived: reportReceived,
            start: qsoStart,
            end: Date(),
            dialFrequencyMHz: dial,
            mode: "FT8"
        )
        onQSOComplete?(record)
        recentlyCompleted[partner] = now()
    }

    /// QSO (or attempt) is over: answer the next pileup caller if one is
    /// still fresh, else resume CQing if that's how we got here.
    private func finishQSOSession() {
        let resume = resumeCQAfterQSO
        let parity = txParity
        let next = resume ? popFreshestQueuedCaller() : nil
        reset()
        if let (call, info) = next {
            // Straight to a report — they already sent their grid, and the
            // line shouldn't sit through another CQ cycle
            mode = .qsoAsCaller
            partner = call
            partnerGrid = info.grid
            txParity = parity
            reportSent = Self.formatReport(info.snr)
            currentTX = "\(call) \(myCall) \(reportSent)"
            awaiting = .rogerReport
            // Short leash (see queuedCallerRetries): they may have moved on
            retriesLeft = queuedCallerRetries
            busyPassesLeft = min(queuedCallerRetries, busyPassBudget)
            qsoStart = Date()
            resumeCQAfterQSO = true
            describe("Answering \(call) from the pileup")
        } else if resume {
            mode = .cqLoop
            txParity = parity
            currentTX = cqText
            awaiting = .answer
            resumeCQAfterQSO = true
            describe("Calling \(cqLabel) (\(parityName(parity)) slots)")
        } else {
            describe("TX idle")
        }
    }

    /// Remove and return the most recently heard caller still inside the
    /// freshness window; stale entries are dropped wholesale.
    private func popFreshestQueuedCaller() -> (String, QueuedCaller)? {
        let cutoff = now().addingTimeInterval(-queuedCallerMaxAge)
        queuedCallers = queuedCallers.filter { $0.value.heardAt >= cutoff }
        guard let best = queuedCallers.max(by: { $0.value.heardAt < $1.value.heardAt })
        else { return nil }
        queuedCallers[best.key] = nil
        return (best.key, best.value)
    }

    private func reset() {
        mode = .idle
        currentTX = nil
        awaiting = .none
        partner = nil
        partnerGrid = nil
        reportSent = ""
        reportReceived = nil
        qsoStart = nil
        retriesLeft = 0
        unansweredCQ = 0
        respondedSinceLastTX = true
        finalMessagesLeft = 0
        resumeCQAfterQSO = false
        partnerBusyWith = nil
        busyPassesLeft = 0
        courtesyTX = nil
        cqSlotCounter = 0 // resumed runs open with an immediate CQ
        // `abandoned`, `recentlyCompleted`, and `queuedCallers` deliberately
        // survive: they outlive the QSO they came from
    }

    private func markResponded(_ text: String) {
        respondedSinceLastTX = true
        unansweredCQ = 0
        describe(text)
    }

    private func describe(_ text: String) {
        stateDescription = text
    }

    private var cqText: String {
        "\(cqLabel) \(myCall) \(myGrid4)".trimmingCharacters(in: .whitespaces)
    }

    /// "CQ" or "CQ POTA" — the run's name in descriptions and the chip.
    var cqLabel: String {
        cqModifier.isEmpty ? "CQ" : "CQ \(cqModifier)"
    }

    private func parityName(_ parity: Int) -> String {
        parity == 0 ? "even" : "odd"
    }

    // MARK: - Payload classification

    static func formatReport(_ snr: Float) -> String {
        let clamped = max(-30, min(30, Int(snr.rounded())))
        return String(format: "%+03d", clamped)
    }

    static func isReport(_ s: String) -> Bool {
        guard s.count == 3, s.first == "+" || s.first == "-" else { return false }
        return s.dropFirst().allSatisfy(\.isNumber)
    }

    static func rogerReportValue(_ s: String) -> String? {
        guard s.first == "R", isReport(String(s.dropFirst())) else { return nil }
        return String(s.dropFirst())
    }

    static func isSignoff(_ s: String) -> Bool {
        s == "RR73" || s == "RRR" || s == "73"
    }

    /// A directed-CQ modifier the FT8 payload can carry (ft8_lib pack28's
    /// c28 special range): 1–4 letters ("DX", "POTA") or exactly 3 digits.
    /// Mixed letters+digits don't pack — "P0TA" would fail at encode time.
    static func isValidCQModifier(_ s: String) -> Bool {
        if s.count == 3, s.allSatisfy(\.isNumber) { return true }
        return (1...4).contains(s.count)
            && s.allSatisfy { $0.isASCII && $0.isLetter && $0.isUppercase }
    }
}
