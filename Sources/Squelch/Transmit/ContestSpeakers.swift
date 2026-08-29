import Foundation

/// Which stations have been heard using the grid-only contest exchange
/// this session — a "CQ WW" or an "R GRID" to anyone. The sequencer leads
/// with "R MYGRID" only for those; everyone else gets a signal report
/// first, which every FT8 program understands (a contest-mode WSJT-X
/// answers it with "R GRID", which completes the QSO just the same, one
/// slot later). Stations that don't speak "R GRID" — JTDX, MSHV, older
/// builds — were seen giving up after one unanswered repeat, so guessing
/// wrong costs the contact; guessing conservatively costs a slot.
final class ContestSpeakers {
    private(set) var calls: Set<String> = []

    /// Fold in one decoded message.
    func note(_ text: String, myCall: String) {
        let parsed = FT8MessageParser.parse(text)
        guard let sender = parsed.sender, sender != myCall.uppercased() else { return }
        if parsed.isRogerGrid || (parsed.isCQ && CQHunter.cqModifier(text: text, sender: sender) == "WW") {
            calls.insert(sender)
        }
    }

    func note(_ texts: [String], myCall: String) {
        for text in texts { note(text, myCall: myCall) }
    }

    func speaks(_ call: String) -> Bool {
        calls.contains(call.uppercased())
    }
}
