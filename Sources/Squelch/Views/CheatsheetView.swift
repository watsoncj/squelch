import SwiftUI

/// Quick reference for reading the feed, shown as a popover from the log.
/// Mode-sensitive: describes whatever the app is currently decoding.
struct CheatsheetView: View {
    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = ""
    @AppStorage(SettingsKeys.digiMode) private var digiModeRaw = DigiMode.ft8.rawValue

    private var mode: DigiMode { DigiMode(rawValue: digiModeRaw) ?? .ft8 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if mode.isJS8 {
                    js8Content
                } else if mode == .wspr {
                    wsprContent
                } else {
                    ftContent
                }
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
    }

    // MARK: - FT8 / FT4

    @ViewBuilder
    private var ftContent: some View {
        Text("Reading \(mode.rawValue) Messages")
            .font(.title3.bold())

        Text("\(mode == .ft4 ? "FT4 is FT8's contest-speed sibling — same messages, half the slot time. " : "")Directed messages read **TO FROM payload** — the first callsign is who it's for, the second is who sent it.")

        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("A complete QSO")
            exampleLine("CQ K1ABC FN42", "K1ABC calls anyone, from grid FN42")
            exampleLine("K1ABC W9XYZ EN52", "W9XYZ answers with their grid")
            exampleLine("W9XYZ K1ABC -05", "K1ABC: “your signal is −5 dB here”")
            exampleLine("K1ABC W9XYZ R-12", "W9XYZ: “roger, you're −12 dB here”")
            exampleLine("W9XYZ K1ABC RR73", "K1ABC: “all received, goodbye” — QSO complete")
            exampleLine("K1ABC W9XYZ 73", "W9XYZ: “goodbye” (courtesy)")
        }

        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Payloads")
            defLine("EN52", "Maidenhead grid square — the sender's location")
            defLine("-05 / +03", "signal report: SNR in dB (0 is loud; −20 is the edge of decodability)")
            defLine("R-05", "roger — “got your report” — plus their report of you")
            defLine("RRR", "everything received")
            defLine("RR73", "received + goodbye, rolled into one")
            defLine("73", "best regards — the ham sign-off")
            defLine("CQ DX …", "calling distant (other-continent) stations only")
            defLine("CQ POTA …", "Parks on the Air activation")
            defLine("<PJ4/K1ABC>", "nonstandard callsign, sent compressed — decoded from a hash")
        }

        logColumns
        colors(example: "CQ K1ABC FN42", cqMeaning: "a CQ you could answer",
               you: "\(myCallsign.isEmpty ? "W0CJW" : myCallsign) K1ABC -05", youMeaning: "someone calling you")

        Text("Timing: everything happens in \(slotText) slots\(mode == .ft8 ? " starting at :00/:15/:30/:45 UTC" : ""). The two sides of a QSO alternate slots, so a full exchange takes about \(mode == .ft4 ? "45 seconds" : "a minute and a half").")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: - JS8

    @ViewBuilder
    private var js8Content: some View {
        Text("Reading JS8 Traffic")
            .font(.title3.bold())

        Text("JS8 is FT8's waveform turned into a **chat mode**: messages read **FROM: TO command text**, span as many \(slotText) frames as they need, and end with the ♢ marker. Much of a JS8 band is automatic — heartbeats, acknowledgements and net check-ins — with keyboard conversations woven between them.")

        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("The heartbeat network")
            exampleLine("KN4ZXG: @HB HEARTBEAT FM16 ♢", "“I'm here, in grid FM16, listening” — sent unattended every 10–30 min")
            exampleLine("WA9TDD: IU7VLD HEARTBEAT SNR -14 ♢", "WA9TDD acknowledging IU7VLD's heartbeat: “you're −14 dB here”. Squelch sends these too (Settings › JS8)")
            exampleLine("DA1LEO: @ALLCALL CQ CQ CQ JN49 ♢", "a CQ — same frame as a heartbeat, addressed to everyone")
        }

        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Directed commands")
            exampleLine("K1ABC: W9XYZ SNR?", "“what's my signal report?” — the other station answers automatically")
            exampleLine("K1ABC: W9XYZ GRID?", "“where are you?”")
            exampleLine("K1ABC: W9XYZ HW CPY?", "“how copy?” — a human question, expects a human answer")
            exampleLine("K1ABC: W9XYZ MSG HELLO ♢", "a receipted message: checksummed, and W9XYZ's station replies ACK")
            exampleLine("K1ABC: W9XYZ> SNR? *DE* W1AW", "a relay — K1ABC passing W1AW's query along")
            exampleLine("K1ABC: GOOD EVENING. BTU ♢", "free text; BTU = “back to you”, the keyboard “over”")
        }

        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Markers")
            defLine("♢", "end of transmission — the station has stopped; your turn")
            defLine("……", "a frame was lost here — there's a hole in the text")
            defLine("… (pending)", "still arriving, one frame per slot — the row above the feed moves down when the last frame lands")
            defLine("F!104 …", "a machine-readable form (net check-in); robots talking to robots")
        }

        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Speeds")
            defLine("SLOW", "30 s frames, 25 Hz wide — most sensitive")
            defLine("JS8", "15 s frames, 50 Hz — the normal speed, where heartbeats live")
            defLine("FAST / 40 / 60", "10 / 6 / 4 s frames, wider and faster — ragchews often shift up once the path is good. Each speed decodes separately (the Speed menu switches)")
        }

        logColumns
        colors(example: "DA1LEO: @ALLCALL CQ CQ CQ JN49 ♢", cqMeaning: "a CQ you could answer",
               you: "K1ABC: \(myCallsign.isEmpty ? "W0CJW" : myCallsign) SNR? ♢", youMeaning: "someone addressing you")

        Text("Transmitting: the Message button composes (\"CALL MSG …\" or free text), Heartbeat sends one @HB beacon, and frames go out one per \(slotText) slot while decoding runs.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: - WSPR

    @ViewBuilder
    private var wsprContent: some View {
        Text("Reading WSPR Spots")
            .font(.title3.bold())

        Text("WSPR is a **beacon mode**, not a conversation: stations transmit their call, grid and power in a 110.6-second transmission, and everyone else just listens and reports. There are no QSOs — the product is the propagation map.")

        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Feed rows")
            exampleLine("WSPR K1ABC FN42 37dBm", "K1ABC's beacon from FN42 at 37 dBm (5 W), decoded here")
            exampleLine("TX WSPR \(myCallsign.isEmpty ? "W0CJW" : myCallsign) …", "your own beacon going out (inert log row)")
        }

        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Power (dBm → watts)")
            defLine("23 dBm", "0.2 W")
            defLine("30 dBm", "1 W")
            defLine("37 dBm", "5 W — the common setting")
            defLine("40 dBm", "10 W")
        }

        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Log columns")
            defLine("SNR", "how strongly the beacon arrived, in dB — WSPR decodes down to about −29")
            defLine("DT", "their clock vs ours, seconds; keep yours synced")
            defLine("Freq", "audio offset — WSPR lives in a 200 Hz sub-band")
        }

        Text("Timing: 2-minute slots starting on even UTC minutes. The Beacon button transmits at the duty cycle set in Settings, and received spots can be uploaded to WSPRnet — the sidebar shows who's hearing you.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: - Shared pieces

    private var slotText: String {
        let s = mode.slotSeconds
        return s == s.rounded() ? "\(Int(s))-second" : "\(String(format: "%g", s))-second"
    }

    @ViewBuilder
    private var logColumns: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Log columns")
            defLine("SNR", "how strongly we received them, in dB")
            defLine("DT", "their clock vs ours, seconds. Should be within ±1 — if every decode shows the same large DT, sync your Mac's clock")
            defLine("Freq", "audio offset in the 200–3000 Hz passband — their spot on the waterfall")
            defLine("Grid", "from the message, or their last transmitted grid")
        }
    }

    private func colors(example: String, cqMeaning: String, you: String, youMeaning: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Colors")
            HStack(spacing: 6) {
                Text(example).font(.callout.monospaced()).foregroundStyle(.green)
                Text("— \(cqMeaning)").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(you).font(.callout.monospaced().bold()).foregroundStyle(Color.accentColor)
                Text("— \(youMeaning)").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.top, 2)
    }

    private func exampleLine(_ message: String, _ meaning: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message)
                .font(.callout.monospaced())
                .frame(width: 220, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(meaning)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func defLine(_ term: String, _ meaning: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(term)
                .font(.callout.monospaced())
                .frame(width: 110, alignment: .leading)
            Text(meaning)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
