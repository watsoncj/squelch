import SwiftUI

/// Scrolling passband spectrogram. Hover reads out the frequency;
/// DOUBLE-click (or right-click menu) moves the TX offset — a single
/// click deliberately does nothing, and setting is blocked while keyed.
struct WaterfallPane: View {
    @ObservedObject var processor: WaterfallProcessor
    @ObservedObject var transmit: TransmitController
    @ObservedObject var controller: DecodeController
    @AppStorage(SettingsKeys.txOffsetHz) private var txOffsetHz = 1500.0
    @AppStorage(SettingsKeys.mapStyle) private var mapStyleRaw = MapStyleChoice.standard.rawValue
    @AppStorage(SettingsKeys.dialFrequencyMHz) private var dialFrequencyMHz = 28.074
    @AppStorage(SettingsKeys.licenseClass) private var licenseClassRaw = LicenseClass.technician.rawValue

    @State private var hoverX: CGFloat?

    /// No TX marker (or offset setting) on frequencies we can't transmit on.
    private var txLegal: Bool {
        TransmitController.isTXLegalMHz(
            dialFrequencyMHz,
            license: LicenseClass(rawValue: licenseClassRaw) ?? .technician
        )
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let image = processor.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Rectangle()
                        .fill(Color(red: 0.02, green: 0.04, blue: 0.12))
                    Text(controller.isRunning
                         ? "Waterfall warming up…"
                         : "Waterfall appears when decoding starts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }

                // TX offset marker
                if txLegal {
                    let txX = WaterfallProcessor.x(forFrequency: txOffsetHz, width: geo.size.width)
                    Rectangle()
                        .fill(.red)
                        .frame(width: 1.5, height: geo.size.height)
                        .position(x: txX, y: geo.size.height / 2)
                    Text(String(format: "TX %.0f", txOffsetHz))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 3)
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .position(x: min(max(txX, 26), geo.size.width - 26), y: 8)
                }

                // Hover crosshair + frequency readout
                if let hoverX {
                    Rectangle()
                        .fill(.white.opacity(0.55))
                        .frame(width: 1, height: geo.size.height)
                        .position(x: hoverX, y: geo.size.height / 2)
                    let freq = WaterfallProcessor.frequency(forX: hoverX, width: geo.size.width)
                    Text(String(format: "%.0f Hz", freq))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 3)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .position(x: min(max(hoverX, 24), geo.size.width - 24), y: geo.size.height - 8)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = point.x
                case .ended: hoverX = nil
                }
            }
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in
                        setOffset(atX: value.location.x, width: geo.size.width)
                    }
            )
            .contextMenu {
                if txLegal, let hoverX {
                    let freq = WaterfallProcessor.frequency(forX: hoverX, width: geo.size.width)
                    Button(String(format: "Set TX offset to %.0f Hz", freq)) {
                        setOffset(atX: hoverX, width: geo.size.width)
                    }
                    .disabled(transmit.anyTXActive)
                }
            }
            .help(txLegal
                  ? "Double-click (or right-click) to move the TX offset. Single clicks do nothing."
                  : "Receive only on this frequency")
        }
        .frame(height: 110)
        .clipped()
        .onAppear {
            processor.setStyle(MapStyleChoice(rawValue: mapStyleRaw) ?? .standard)
        }
        .onChange(of: mapStyleRaw) { _, raw in
            processor.setStyle(MapStyleChoice(rawValue: raw) ?? .standard)
        }
    }

    private func setOffset(atX x: CGFloat, width: CGFloat) {
        guard txLegal else { return }
        guard !transmit.anyTXActive else { return } // never retune mid-transmission
        txOffsetHz = WaterfallProcessor.frequency(forX: x, width: width).rounded()
    }
}
