import SwiftUI

/// Unmissable strip shown whenever the radio is keyed, the auto-sequencer is
/// active, or a transmit attempt failed.
struct TXBanner: View {
    @ObservedObject var transmit: TransmitController
    @ObservedObject var sequencer: QSOSequencer
    let onHalt: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if transmit.anyTXActive {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text(transmit.isTuning ? "TUNING" : "TRANSMITTING")
                    .fontWeight(.heavy)
                if !transmit.currentTXText.isEmpty, !transmit.isTuning {
                    Text(transmit.currentTXText)
                        .font(.body.monospaced())
                }
            } else if let error = transmit.txError {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(error)
                    .lineLimit(2)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text(sequencer.stateDescription)
            }

            Spacer()

            Button("Halt TX") {
                onHalt()
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.25))
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(bannerColor)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var bannerColor: Color {
        if transmit.anyTXActive { return .red }
        if transmit.txError != nil { return .orange }
        return Color.blue.opacity(0.85)
    }
}
