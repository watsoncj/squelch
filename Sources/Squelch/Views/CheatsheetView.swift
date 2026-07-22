import SwiftUI

/// Quick reference for reading FT8 messages, shown as a popover from the log.
struct CheatsheetView: View {
    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Reading FT8 Messages")
                    .font(.title3.bold())

                Text("Directed messages read **TO FROM payload** — the first callsign is who it's for, the second is who sent it.")

                VStack(alignment: .leading, spacing: 4) {
                    sectionHeader("A complete QSO")
                    qsoLine("CQ K1ABC FN42", "K1ABC calls anyone, from grid FN42")
                    qsoLine("K1ABC W9XYZ EN52", "W9XYZ answers with their grid")
                    qsoLine("W9XYZ K1ABC -05", "K1ABC: “your signal is −5 dB here”")
                    qsoLine("K1ABC W9XYZ R-12", "W9XYZ: “roger, you're −12 dB here”")
                    qsoLine("W9XYZ K1ABC RR73", "K1ABC: “all received, goodbye” — QSO complete")
                    qsoLine("K1ABC W9XYZ 73", "W9XYZ: “goodbye” (courtesy)")
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

                VStack(alignment: .leading, spacing: 4) {
                    sectionHeader("Log columns")
                    defLine("SNR", "how strongly we received them, in dB")
                    defLine("DT", "their clock vs ours, seconds. Should be within ±1 — if every decode shows the same large DT, sync your Mac's clock")
                    defLine("Freq", "audio offset in the 200–3000 Hz passband — their spot on the waterfall")
                    defLine("Grid", "from the message, or their last transmitted grid")
                }

                VStack(alignment: .leading, spacing: 4) {
                    sectionHeader("Colors")
                    HStack(spacing: 6) {
                        Text("CQ K1ABC FN42").font(.callout.monospaced()).foregroundStyle(.green)
                        Text("— a CQ you could answer").font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text("\(myCallsign) K1ABC -05").font(.callout.monospaced().bold()).foregroundStyle(Color.accentColor)
                        Text("— someone calling you").font(.callout).foregroundStyle(.secondary)
                    }
                }

                Text("Timing: everything happens in 15-second slots starting at :00/:15/:30/:45 UTC. The two sides of a QSO alternate slots, so a full exchange takes about a minute and a half.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.top, 2)
    }

    private func qsoLine(_ message: String, _ meaning: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message)
                .font(.callout.monospaced())
                .frame(width: 170, alignment: .leading)
            Text(meaning)
                .font(.callout)
                .foregroundStyle(.secondary)
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
