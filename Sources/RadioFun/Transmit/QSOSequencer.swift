import Foundation

/// A completed FT8 contact.
struct QSORecord: Identifiable, Codable {
    let id: UUID
    let partner: String
    let partnerGrid: String?
    let reportSent: String
    let reportReceived: String?
    let start: Date
    let end: Date
    let dialFrequencyMHz: Double
    let mode: String // "FT8"
}

/// FT8 auto-sequence state machine. Pure logic, no I/O: the app calls
/// `ingest` with each receive slot's decodes and `transmission` before each
/// transmit slot; QSOs alternate 15 s slots by parity (even/odd).
///
/// Caller side (we CQ'd):  CQ → [they: MYCALL X GRID] → X MYCALL ±NN
///                         → [they: MYCALL X R±NN] → X MYCALL RR73 ✓
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

    var myCall = "W0CJW"
    var myGrid4 = ""
    var maxRetries = 3
    var maxUnansweredCQ = 10
    var onQSOComplete: ((QSORecord) -> Void)?

    private(set) var txParity = 0
    private var currentTX: String?
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

    // MARK: - Commands

    func startCQ(parity: Int) {
        reset()
        mode = .cqLoop
        txParity = parity
        currentTX = cqText
        awaiting = .answer
        resumeCQAfterQSO = true
        describe("Calling CQ (\(parityName(parity)) slots)")
    }

    func replyTo(call: String, snr: Float, cqParity: Int) {
        reset()
        mode = .qsoAsAnswerer
        partner = call
        txParity = 1 - cqParity
        reportSent = Self.formatReport(snr)
        currentTX = "\(call) \(myCall) \(myGrid4)".trimmingCharacters(in: .whitespaces)
        awaiting = .report
        retriesLeft = maxRetries
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
        partnerGrid = grid
        txParity = 1 - theirParity
        reportSent = Self.formatReport(snr)
        currentTX = "\(call) \(myCall) \(reportSent)"
        awaiting = .rogerReport
        retriesLeft = maxRetries
        qsoStart = Date()
        resumeCQAfterQSO = false
        describe("Answering \(call) with report")
    }

    /// Engage with a station that sent us a signal report: we owe them a
    /// roger. Enters mid-exchange as the answerer side (the "late reply
    /// after give-up" recovery).
    func engageAsAnswerer(call: String, report: String, snr: Float, theirParity: Int) {
        reset()
        mode = .qsoAsAnswerer
        partner = call
        reportReceived = report
        txParity = 1 - theirParity
        reportSent = Self.formatReport(snr)
        currentTX = "\(call) \(myCall) R\(reportSent)"
        awaiting = .rr73
        retriesLeft = maxRetries
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
    func ingest(decodes: [Decode], slotParity: Int) {
        guard mode != .idle, slotParity != txParity else { return }
        for decode in decodes {
            let tokens = decode.text.uppercased().split(separator: " ").map(String.init)
            guard tokens.count >= 2, tokens[0] == myCall.uppercased() else { continue }
            let from = tokens[1].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            let payload = tokens.count >= 3 ? tokens[2] : ""
            handle(from: from, payload: payload, snr: decode.snr)
        }
    }

    /// Ask what to transmit in the slot of the given parity (nil = stay quiet).
    func transmission(forSlotParity parity: Int) -> String? {
        guard mode != .idle, parity == txParity, let tx = currentTX else { return nil }

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
            } else {
                retriesLeft -= 1
                if retriesLeft < 0 {
                    describe("No reply from \(partner ?? "?") — giving up")
                    finishQSOSession()
                    return transmission(forSlotParity: parity)
                }
            }
        }
        respondedSinceLastTX = false
        return tx
    }

    // MARK: - Message handling

    private func handle(from: String, payload: String, snr: Float) {
        switch (mode, awaiting) {
        case (.cqLoop, .answer):
            // Anyone answering our CQ with a grid (or a bare report)
            guard FT8MessageParser.isGrid(payload) || Self.isReport(payload) || payload.isEmpty else { return }
            partner = from
            partnerGrid = FT8MessageParser.isGrid(payload) ? payload : nil
            reportSent = Self.formatReport(snr)
            qsoStart = Date()
            mode = .qsoAsCaller
            awaiting = .rogerReport
            retriesLeft = maxRetries
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
    }

    /// QSO (or attempt) is over: resume CQing if that's how we got here.
    private func finishQSOSession() {
        let resume = resumeCQAfterQSO
        let parity = txParity
        reset()
        if resume {
            mode = .cqLoop
            txParity = parity
            currentTX = cqText
            awaiting = .answer
            resumeCQAfterQSO = true
            describe("Calling CQ (\(parityName(parity)) slots)")
        } else {
            describe("TX idle")
        }
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
        "CQ \(myCall) \(myGrid4)".trimmingCharacters(in: .whitespaces)
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
}
