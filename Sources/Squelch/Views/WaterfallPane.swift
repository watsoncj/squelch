import SwiftUI

/// Scrolling passband spectrogram. Hover reads out the frequency;
/// DOUBLE-click (or right-click menu) moves the TX offset — a single
/// click deliberately does nothing, and setting is blocked while keyed.
///
/// Time runs at a fixed 300 ms per point: the pane is a window onto ~6
/// minutes of history — scroll down to look back, drag the top edge to
/// resize, or maximize to fill the map. Newest audio is pinned to the
/// top, so an untouched pane always shows live signal. Scrolling away
/// from the live edge PAUSES the view — the offset tracks incoming
/// rows so the content holds still in absolute time while the image
/// stays current (palette changes recolor a paused view immediately);
/// returning to the top goes live again.
struct WaterfallPane: View {
    @ObservedObject var processor: WaterfallProcessor
    #if os(macOS)
    @ObservedObject var transmit: TransmitController
    #endif
    @ObservedObject var controller: DecodeController
    /// Decodes from the selected station — their transmissions get boxed
    /// in the same blue as the selected grid cell on the map.
    var highlightMessages: [DecodedMessage] = []
    /// Read at wand-tap time only (not observed): recent decodes and our
    /// slot parity, for picking a clear TX offset. nil on iPad (RX-only).
    var store: DecodeStore?
    var sequencer: QSOSequencer?
    /// Inspect-mode hit: routes the clicked transmission through the same
    /// select-and-reveal flow as a chip-callsign click.
    var onSelectMessage: ((DecodedMessage.ID) -> Void)?
    @AppStorage(SettingsKeys.txOffsetHz) private var txOffsetHz = 1500.0
    @AppStorage(SettingsKeys.showWaterfall) private var showWaterfall = false
    @AppStorage(SettingsKeys.mapStyle) private var mapStyleRaw = MapStyleChoice.standard.rawValue
    @AppStorage(SettingsKeys.dialFrequencyMHz) private var dialFrequencyMHz = 14.074
    @AppStorage(SettingsKeys.licenseClass) private var licenseClassRaw = LicenseClass.technician.rawValue

    @AppStorage(SettingsKeys.waterfallHeight) private var paneHeight = 110.0
    @AppStorage(SettingsKeys.waterfallMaximized) private var maximized = false
    @Environment(\.colorScheme) private var colorScheme

    @State private var hoverX: CGFloat?
    @State private var hoverY: CGFloat?
    @State private var dragStartHeight: CGFloat?
    /// Inspect mode: armed by the crosshair button (one-shot, like a
    /// browser's element picker); ⌥-click inspects without arming.
    @State private var inspecting = false
    /// ⌥ held: hover shows the inspect outline/chip without arming —
    /// the modifier IS the mode, for as long as it's down.
    @State private var optionHeld = false
    @State private var inspection: InspectionPresentation?
    @State private var inspectionAnchor = CGRect.zero

    struct InspectionPresentation: Identifiable {
        let id = UUID()
        let result: SignalInspector.Result
    }
    /// Points scrolled back from the live edge; 0 means live. While
    /// scrolled back, the offset is bumped by each frame's row delta so
    /// the view holds still in absolute time — the image itself is
    /// always the processor's current one, so palette changes (map
    /// style, light/dark) recolor a paused view immediately.
    @State private var scrollback: CGFloat = 0
    @State private var thumbDragStart: CGFloat?

    private var paused: Bool { scrollback > 0 }

    /// Control-cluster styling follows the appearance, like the palettes:
    /// dark glass + white glyphs over the dark waterfall, light glass +
    /// ink glyphs over the light one.
    private var controlGlyph: AnyShapeStyle {
        AnyShapeStyle(colorScheme == .dark ? Color.white.opacity(0.9) : Color.black.opacity(0.75))
    }
    private var controlChip: AnyShapeStyle {
        AnyShapeStyle(colorScheme == .dark ? Color.black.opacity(0.55) : Color.white.opacity(0.7))
    }

    /// No TX marker (or offset setting) on frequencies we can't transmit on.
    /// iPad is receive-only: no marker, no offset control, ever.
    private var txLegal: Bool {
        #if os(macOS)
        return TransmitController.isTXLegalMHz(
            dialFrequencyMHz,
            license: LicenseClass(rawValue: licenseClassRaw) ?? .technician
        )
        #else
        return false
        #endif
    }

    private var txBusy: Bool {
        #if os(macOS)
        return transmit.anyTXActive
        #else
        return false
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let image = processor.image {
                    // One point per image row (fixed time scale). No
                    // ScrollView: phased trackpad scrolls never reach a
                    // SwiftUI ScrollView floating over the Map (MapKit's
                    // gesture handling eats them), so an NSEvent monitor
                    // below feeds a manual offset instead.
                    let imageHeight = CGFloat(image.height)
                    let offset = min(scrollback, max(0, imageHeight - geo.size.height))
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: geo.size.width, height: imageHeight)
                        .offset(y: -offset)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                        .clipped()
                } else {
                    // No fill: the panel's material shows through, matching
                    // the sidebar's translucent look
                    Text(controller.isRunning
                         ? "Waterfall warming up…"
                         : "Waterfall appears when decoding starts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }

                // Selected station's transmissions, boxed in the map's
                // selection blue. Row dates place each decode in time even
                // across decoding gaps; the x span is the FT8 tone spread.
                if !highlightMessages.isEmpty, let frame = processor.frame {
                    let imageHeight = CGFloat(frame.image.height)
                    let offset = min(scrollback, max(0, imageHeight - geo.size.height))
                    let toneSpanHz = 50.0 // 8 tones × 6.25 Hz
                    ForEach(highlightMessages) { message in
                        let start = message.slotStart.addingTimeInterval(TimeInterval(message.timeOffset))
                        let end = start.addingTimeInterval(DigiMode.current == .wspr ? 110.6 : 12.64)
                        if let first = frame.rowDates.firstIndex(where: { $0 >= start }),
                           frame.rowDates[first] <= end {
                            let last = frame.rowDates.lastIndex(where: { $0 <= end }) ?? first
                            // Outline only — a fill would tint the pixels and
                            // skew the intensity reading. Padded so the stroke
                            // sits in clear noise, not on the outermost tones.
                            let padHz = 7.0
                            let padRows = 2
                            let lowX = WaterfallProcessor.x(
                                forFrequency: Double(message.audioFrequency) - padHz, width: geo.size.width)
                            let highX = WaterfallProcessor.x(
                                forFrequency: Double(message.audioFrequency) + toneSpanHz + padHz, width: geo.size.width)
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(.blue.opacity(0.9), lineWidth: 1.5)
                                .frame(width: max(4, highX - lowX),
                                       height: CGFloat(last - first) + 1 + CGFloat(padRows * 2))
                                .offset(x: lowX, y: imageHeight - 1 - CGFloat(last + padRows) - offset)
                                .allowsHitTesting(false)
                        }
                    }
                }

                // Inspect mode: outline the decode box the cursor is over
                // (the devtools element-highlight) with a callsign chip —
                // you know what a click would select before clicking
                if inspecting || optionHeld, let hoverX, let hoverY, let frame = processor.frame,
                   case .hit(let hovered)? = hitTest(at: CGPoint(x: hoverX, y: hoverY),
                                                     size: geo.size, frame: frame),
                   let box = boxRect(for: hovered.message, frame: frame, size: geo.size) {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(.primary.opacity(0.7), lineWidth: 1.5)
                        .frame(width: box.width, height: box.height)
                        .offset(x: box.minX, y: box.minY)
                        .allowsHitTesting(false)
                    Text("\(hovered.message.callsign ?? "?") · \(Int(hovered.message.snr)) dB")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .position(x: min(max(box.midX, 40), geo.size.width - 40),
                                  y: max(box.minY - 10, 8))
                        .allowsHitTesting(false)
                }

                // TX offset marker
                if txLegal {
                    // Same red treatment as the map's active grid cells:
                    // 0.30 fill, 0.8 stroke
                    let txX = WaterfallProcessor.x(forFrequency: txOffsetHz, width: geo.size.width)
                    Rectangle()
                        .fill(.red.opacity(0.8))
                        .frame(width: 1.5, height: geo.size.height)
                        .position(x: txX, y: geo.size.height / 2)
                    Text(String(format: "TX %.0f", txOffsetHz))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(.red.opacity(0.30), in: RoundedRectangle(cornerRadius: 3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(.red.opacity(0.8), lineWidth: 1)
                        )
                        .foregroundStyle(.white)
                        .position(x: min(max(txX, 26), geo.size.width - 26), y: 9)
                }

                #if os(macOS)
                ScrollWheelCatcher { delta in
                    let imageHeight = CGFloat(processor.image?.height ?? 0)
                    let maxOffset = max(0, imageHeight - geo.size.height)
                    scrollback = min(max(scrollback - delta, 0), maxOffset)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                #endif

                if paused {
                    Text("Scroll to top to go live")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(6)
                }

                // Hover crosshair + frequency readout — decoration only,
                // never a hit target (it tracks the cursor, so it would
                // shadow anything interactive underneath)
                if let hoverX {
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 1, height: geo.size.height)
                        .position(x: hoverX, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                    let freq = WaterfallProcessor.frequency(forX: hoverX, width: geo.size.width)
                    Text(String(format: "%.0f Hz", freq))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 3)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .position(x: min(max(hoverX, 24), geo.size.width - 24), y: geo.size.height - 8)
                        .allowsHitTesting(false)
                }

                // Hand-rolled overlay scroller (scroll events arrive via
                // the NSEvent monitor, so there's no ScrollView to draw
                // one). Shown while paused — it doubles as the where-am-I-
                // in-history readout — and the thumb drags like the real
                // thing. Topmost in the stack so nothing shadows the drag.
                if paused, let image = processor.image {
                    let contentHeight = CGFloat(image.height)
                    let maxOffset = max(0, contentHeight - geo.size.height)
                    if maxOffset > 0 {
                        let trackHeight = geo.size.height - 8
                        let thumbHeight = max(24, trackHeight * geo.size.height / contentHeight)
                        let travel = trackHeight - thumbHeight
                        let thumbY = 4 + travel * (min(scrollback, maxOffset) / maxOffset)
                        Capsule()
                            .fill(Color.primary.opacity(0.4))
                            .frame(width: 5, height: thumbHeight)
                            .frame(width: 16) // grab zone wider than the capsule
                            .contentShape(Rectangle())
                            .offset(x: geo.size.width - 16, y: thumbY)
                            .gesture(
                                DragGesture(minimumDistance: 1)
                                    .onChanged { value in
                                        let start = thumbDragStart ?? scrollback
                                        thumbDragStart = start
                                        let perPoint = maxOffset / max(1, travel)
                                        // Clamp above zero so the drag can't
                                        // dismiss its own thumb mid-gesture
                                        scrollback = min(max(start + value.translation.height * perPoint, 0.5), maxOffset)
                                    }
                                    .onEnded { _ in
                                        thumbDragStart = nil
                                        if scrollback < 2 {
                                            scrollback = 0
                                        }
                                    }
                            )
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverX = point.x
                    hoverY = point.y
                case .ended:
                    hoverX = nil
                    hoverY = nil
                }
            }
            .onModifierKeysChanged(mask: .option) { _, new in
                optionHeld = new.contains(.option)
            }
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in
                        setOffset(atX: value.location.x, width: geo.size.width)
                    }
            )
            .gesture(
                SpatialTapGesture().modifiers(.option)
                    .onEnded { value in
                        inspect(at: value.location, size: geo.size)
                    }
            )
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        guard inspecting else { return } // single click stays inert otherwise
                        inspect(at: value.location, size: geo.size)
                    }
            )
            .popover(item: $inspection,
                     attachmentAnchor: .rect(.rect(inspectionAnchor))) { presentation in
                SignalInspectorCard(
                    result: presentation.result,
                    station: inspectedStation(for: presentation.result),
                    myCall: myCall
                )
            }
            .contextMenu {
                if txLegal, let hoverX {
                    let freq = WaterfallProcessor.frequency(forX: hoverX, width: geo.size.width)
                    Button(String(format: "Set TX offset to %.0f Hz", freq)) {
                        setOffset(atX: hoverX, width: geo.size.width)
                    }
                    .disabled(txBusy)
                }
            }
            .help(txLegal
                  ? "Double-click (or right-click) to move the TX offset. Single clicks do nothing."
                  : "Receive only on this frequency")
            .onChange(of: processor.frame?.newestRow) { previous, current in
                // New rows landed on top: push the offset down by the same
                // amount so a scrolled-back view stays put in absolute time
                // (clamped once the history cap starts eating the far end)
                guard paused, let previous, let current else { return }
                let imageHeight = CGFloat(processor.image?.height ?? 0)
                let maxOffset = max(0, imageHeight - geo.size.height)
                scrollback = min(scrollback + CGFloat(current - previous), maxOffset)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 0) {
                    #if os(macOS)
                    if store != nil {
                        Button {
                            inspecting.toggle()
                            if !inspecting { inspection = nil }
                        } label: {
                            Image(systemName: "dot.scope")
                                .foregroundStyle(inspecting ? AnyShapeStyle(.tint) : controlGlyph)
                                .frame(width: 26, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help("Inspect a signal: arm, then click a trace to identify it. ⌥-click inspects any time.")
                    }

                    if txLegal, store != nil {
                        Button {
                            pickBestOffset()
                        } label: {
                            Image(systemName: "wand.and.stars")
                                .foregroundStyle(controlGlyph)
                                .frame(width: 26, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .disabled(txBusy)
                        .help("Move the TX offset to the clearest frequency — judged from recent decodes and the waterfall")
                    }

                    Button {
                        maximized.toggle()
                    } label: {
                        Image(systemName: maximized
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .foregroundStyle(controlGlyph)
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(maximized ? "Restore the waterfall" : "Maximize the waterfall")
                    #endif

                    // Panel's own hide toggle, like the sidebar's
                    Button {
                        showWaterfall = false
                    } label: {
                        Image(systemName: "rectangle.bottomthird.inset.filled")
                            .foregroundStyle(controlGlyph)
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Hide the waterfall")
                }
                .background(controlChip, in: RoundedRectangle(cornerRadius: 7))
                .padding(4)
            }
            #if os(macOS)
            .overlay(alignment: .top) {
                // Grab strip on the top edge, the sidebar handle turned on
                // its side; dragging always drops out of maximized so the
                // height under the cursor is where the pane stays.
                Rectangle()
                    .fill(.clear)
                    .frame(height: 10)
                    .contentShape(Rectangle())
                    .offset(y: -5) // straddle the edge
                    .pointerStyle(.rowResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartHeight ?? geo.size.height
                                dragStartHeight = start
                                maximized = false
                                paneHeight = min(560, max(90, start - value.translation.height))
                            }
                            .onEnded { _ in dragStartHeight = nil }
                    )
            }
            #endif
        }
        .frame(height: maximized ? nil : CGFloat(paneHeight))
        .frame(maxHeight: maximized ? .infinity : nil)
        .clipped()
        .onAppear {
            processor.setStyle(MapStyleChoice(rawValue: mapStyleRaw) ?? .standard, dark: colorScheme == .dark)
        }
        .onChange(of: mapStyleRaw) { _, raw in
            processor.setStyle(MapStyleChoice(rawValue: raw) ?? .standard, dark: colorScheme == .dark)
        }
        .onChange(of: colorScheme) { _, scheme in
            processor.setStyle(MapStyleChoice(rawValue: mapStyleRaw) ?? .standard, dark: scheme == .dark)
        }
    }

    private func setOffset(atX x: CGFloat, width: CGFloat) {
        guard txLegal else { return }
        guard !txBusy else { return } // never retune mid-transmission
        txOffsetHz = WaterfallProcessor.frequency(forX: x, width: width).rounded()
    }

    // MARK: - Signal inspector

    private var myCall: String {
        (UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? "").uppercased()
    }

    private var transmissionSeconds: Double {
        DigiMode.current == .wspr ? 110.6 : 12.64
    }

    /// View point → (frequency, row date) → SignalInspector. nil when the
    /// click lands outside the painted history.
    private func hitTest(at point: CGPoint, size: CGSize, frame: WaterfallProcessor.Frame) -> SignalInspector.Result? {
        let imageHeight = CGFloat(frame.image.height)
        let offset = min(scrollback, max(0, imageHeight - size.height))
        let rowIndex = Int((imageHeight - 1 - (point.y + offset)).rounded())
        guard frame.rowDates.indices.contains(rowIndex) else { return nil }
        return SignalInspector.inspect(
            frequencyHz: WaterfallProcessor.frequency(forX: point.x, width: size.width),
            time: frame.rowDates[rowIndex],
            messages: recentMessages(in: frame),
            slotSeconds: DigiMode.current.slotSeconds,
            transmissionSeconds: transmissionSeconds
        )
    }

    /// The highlight overlay's projection, reused for hover outline and
    /// popover anchoring — same padding as the selection boxes so the
    /// hover and selected outlines land identically.
    private func boxRect(for message: DecodedMessage, frame: WaterfallProcessor.Frame, size: CGSize) -> CGRect? {
        let imageHeight = CGFloat(frame.image.height)
        let offset = min(scrollback, max(0, imageHeight - size.height))
        let start = message.slotStart.addingTimeInterval(TimeInterval(message.timeOffset))
        let end = start.addingTimeInterval(transmissionSeconds)
        guard let first = frame.rowDates.firstIndex(where: { $0 >= start }),
              frame.rowDates[first] <= end else { return nil }
        let last = frame.rowDates.lastIndex(where: { $0 <= end }) ?? first
        let padHz = 7.0
        let padRows = 2
        let lowX = WaterfallProcessor.x(
            forFrequency: Double(message.audioFrequency) - padHz, width: size.width)
        let highX = WaterfallProcessor.x(
            forFrequency: Double(message.audioFrequency) + 50 + padHz, width: size.width)
        return CGRect(x: lowX,
                      y: imageHeight - 1 - CGFloat(last + padRows) - offset,
                      width: max(4, highX - lowX),
                      height: CGFloat(last - first) + 1 + CGFloat(padRows * 2))
    }

    /// Only decodes the visible frame can contain — store history runs
    /// much deeper than the waterfall's ~6 minutes.
    private func recentMessages(in frame: WaterfallProcessor.Frame) -> [DecodedMessage] {
        guard let store, let oldest = frame.rowDates.first else { return [] }
        let cutoff = oldest.addingTimeInterval(-DigiMode.current.slotSeconds)
        return Array(store.messages.prefix { $0.slotStart >= cutoff })
    }

    private func inspect(at point: CGPoint, size: CGSize) {
        guard let frame = processor.frame,
              let result = hitTest(at: point, size: size, frame: frame) else { return }
        if case .hit(let hit) = result {
            inspectionAnchor = boxRect(for: hit.message, frame: frame, size: size)
                ?? CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
            if hit.message.callsign != nil, hit.message.callsign?.uppercased() != myCall {
                onSelectMessage?(hit.message.id)
            }
        } else {
            inspectionAnchor = CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
        }
        inspection = InspectionPresentation(result: result)
        inspecting = false // one-shot, like the browser's element picker
    }

    private func inspectedStation(for result: SignalInspector.Result) -> Station? {
        guard case .hit(let hit) = result, let call = hit.message.callsign else { return nil }
        return store?.stations[call]
    }

    #if os(macOS)
    /// The wand: score the passband from recent decodes (same-parity
    /// stations are the dangerous ones — they collide with us at the
    /// partner's receiver, invisibly to us while we transmit) plus the
    /// waterfall's averaged spectrum, and move the TX marker to the
    /// clearest offset.
    private func pickBestOffset() {
        guard txLegal, !txBusy, let store else { return }
        let slotSeconds = DigiMode.current.slotSeconds
        // Mid-QSO/CQ our parity is fixed; idle (between hunts) it isn't
        let myParity: Int? = sequencer.flatMap { $0.mode == .idle ? nil : $0.txParity }
        let myCall = (UserDefaults.standard.string(forKey: SettingsKeys.myCallsign) ?? "").uppercased()
        let now = Date()
        let occupants: [TXOffsetPicker.Occupant] = store.messages
            .prefix { now.timeIntervalSince($0.slotStart) < 180 }
            .filter { $0.callsign?.uppercased() != myCall }
            .map { message in
                TXOffsetPicker.Occupant(
                    frequency: Double(message.audioFrequency),
                    sameParity: myParity.map { message.slotParity(slotSeconds: slotSeconds) == $0 },
                    age: now.timeIntervalSince(message.slotStart))
            }
        processor.averagedSpectrum(excludingParity: myParity, slotSeconds: slotSeconds, seconds: 90) { spectrum, startHz, hzPerBin in
            guard !txBusy else { return } // TX may have started while we averaged
            withAnimation(.snappy) {
                txOffsetHz = TXOffsetPicker.pick(
                    occupants: occupants,
                    spectrum: spectrum,
                    spectrumStartHz: startHz,
                    spectrumHzPerBin: hzPerBin)
            }
        }
    }
    #endif
}

/// The inspector popover: THAT transmission's data (the station card
/// covers the station). Ephemeral — dismisses on click-away.
private struct SignalInspectorCard: View {
    let result: SignalInspector.Result
    let station: Station?
    let myCall: String

    private static let slotTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch result {
            case .hit(let hit): hitBody(hit)
            case .miss(let miss): missBody(miss)
            }
        }
        .padding(12)
        .frame(minWidth: 220, maxWidth: 300, alignment: .leading)
    }

    @ViewBuilder
    private func hitBody(_ hit: SignalInspector.Hit) -> some View {
        let message = hit.message
        Text(message.text)
            .font(.system(.body, design: .monospaced).weight(.semibold))
        if message.callsign?.uppercased() == myCall {
            Label("Your own transmission", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let call = message.callsign {
            HStack(spacing: 4) {
                if let country = message.country {
                    Text(country.flag)
                    Text("\(call) · \(country.name)")
                } else {
                    Text(call)
                }
                if let km = message.distanceKm {
                    Text("· \(Int(km * 0.621371)) mi")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Divider()
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            GridRow {
                Text("\(Self.slotTime.string(from: message.slotStart)) slot")
                Text(String(format: "DT %.1f s", message.timeOffset))
            }
            GridRow {
                Text("\(Int(message.audioFrequency)) Hz")
                Text(String(format: "%+.0f dB", message.snr))
            }
            if let station {
                GridRow {
                    Text("Heard \(station.heardCount)×")
                    Text(String(format: "last %+.0f dB", station.lastSNR))
                }
            }
        }
        .font(.caption.monospacedDigit())
        HStack {
            if let call = message.callsign, call.uppercased() != myCall,
               let url = URL(string: "https://www.qrz.com/db/\(call)") {
                Link("QRZ", destination: url)
                    .font(.caption)
            }
            if hit.alternates > 0 {
                Spacer()
                Text("+\(hit.alternates) more signal\(hit.alternates == 1 ? "" : "s") here")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func missBody(_ miss: SignalInspector.Miss) -> some View {
        Text("No decode here")
            .font(.body.weight(.semibold))
        Text("\(Int(miss.frequencyHz)) Hz · \(Self.slotTime.string(from: miss.time))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        Divider()
        if let nearest = miss.nearestInSlot, let away = miss.nearestHzAway,
           let call = nearest.callsign {
            let direction = Double(nearest.audioFrequency) < miss.frequencyHz ? "below" : "above"
            Text("Nearest this slot: \(call), \(Int(away)) Hz \(direction)")
                .font(.caption)
        } else {
            Text("No decodes in this slot — off-cadence, non-FT8, or below the decode floor")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#if os(macOS)
import AppKit

/// Grabs scroll-wheel events over the pane with a local NSEvent monitor
/// and hands the vertical delta to the view. A monitor sees every event
/// (trackpad phases, momentum, legacy wheels) before dispatch, which a
/// SwiftUI ScrollView floating over MapKit does not. The view itself is
/// invisible to hit-testing, so hover, double-click, and the context
/// menu underneath are untouched.
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView(onScroll: onScroll) }
    func updateNSView(_ view: CatcherView, context: Context) { view.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: (CGFloat) -> Void
        private var monitor: Any?

        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let window = self.window, event.window === window else {
                        return event
                    }
                    let point = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(point) else { return event }
                    // scrollingDeltaY already respects natural-scroll
                    // direction; momentum events arrive here too
                    self.onScroll(event.scrollingDeltaY)
                    return nil // consumed — nothing underneath scrolls
                }
            } else if window == nil, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
#endif
