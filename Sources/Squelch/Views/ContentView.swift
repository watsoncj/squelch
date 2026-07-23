import SwiftUI

struct ContentView: View {
    @ObservedObject var store: DecodeStore
    @ObservedObject var controller: DecodeController
    @ObservedObject var location: LocationProvider
    @ObservedObject var transmit: TransmitController
    @ObservedObject var sequencer: QSOSequencer
    @ObservedObject var qsoLog: QSOLog
    @ObservedObject var cat: CATController
    @ObservedObject var actions: AppModel

    @AppStorage(SettingsKeys.audioDeviceUID) private var audioDeviceUID = ""
    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = ""
    @AppStorage(SettingsKeys.dialFrequencyMHz) private var dialFrequencyMHz = 14.074
    @AppStorage(SettingsKeys.digiMode) private var digiMode = DigiMode.ft8.rawValue
    @AppStorage(SettingsKeys.showWaterfall) private var showWaterfall = false
    @AppStorage(SettingsKeys.licenseClass) private var licenseClassRaw = LicenseClass.technician.rawValue
    @AppStorage(SettingsKeys.sidebarWidth) private var sidebarWidth = 360.0
    @AppStorage(SettingsKeys.showSidebar) private var showSidebar = true
    @State private var sidebarDragStartWidth: Double?
    @State private var selectedStationCall: String?
    @State private var showCheatsheet = false
    @State private var showFrequencies = false
    @State private var devices: [AudioDevice] = []
    @State private var selectedMessageID: DecodedMessage.ID?
    @State private var isFullScreen = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Apple Maps treatment: the map fills the window and the log
            // floats over it as a translucent sidebar
            MapPane(store: store, location: location, stateResolver: actions.stateResolver, selectedMessage: selectedMessage,
                    onSelectStation: { call in
                        selectedStationCall = call
                        showSidebar = true // detail docks in the sidebar now
                    },
                    leadingObscuredWidth: panelObscuredWidth)
                .ignoresSafeArea(edges: .top) // bleed under the transparent toolbar
                .overlay(alignment: .top) {
                    // The hidden-titlebar drag region sits over the map, and
                    // a window-move drag would otherwise ALSO pan the map.
                    // This strip claims those drags as pure window moves —
                    // but must never cover the sidebar (it eats clicks), so
                    // it starts right of the panels / the floating toggle.
                    // Pointless (and click-stealing) in full screen.
                    if !isFullScreen {
                        Color.clear
                            .frame(height: 52)
                            .contentShape(Rectangle())
                            .gesture(WindowDragGesture())
                            .ignoresSafeArea(edges: .top)
                            .padding(.leading, showSidebar ? panelObscuredWidth + 10 : 130)
                    }
                }
                .overlay(alignment: .topLeading) {
                    // Sidebar closed: a lone glass toggle next to the
                    // traffic lights, Apple Maps style
                    if !showSidebar {
                        Button {
                            showSidebar = true
                        } label: {
                            Image(systemName: "sidebar.leading")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 38, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .glassCapsule()
                        .help("Show the sidebar")
                        .padding(.leading, 84)
                        .padding(.top, 11)
                        .ignoresSafeArea(edges: .top)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if showSidebar {
                        panelStack
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // Full screen: the toolbar auto-hides, so the radio
                    // controls float over the map in a glass bar instead
                    if isFullScreen {
                        // Two capsules mirroring the windowed toolbar's two
                        // glass groups: the volatile status cluster resizes
                        // in its own skin; the action capsule never moves.
                        // Metrics tuned to match the windowed toolbar's
                        // native capsule: ~38pt tall, 16pt item rhythm,
                        // 16pt right inset, 12pt from the top edge
                        HStack(alignment: .center, spacing: 10) {
                            if statusClusterVisible {
                                HStack(spacing: 14) {
                                    statusCluster(inToolbar: false)
                                }
                                .buttonStyle(.borderless)
                                .padding(.horizontal, 10)
                                .frame(height: 38)
                                .glassCapsule()
                            }

                            HStack(spacing: 16) {
                                actionControls
                            }
                            .buttonStyle(.borderless)
                            .labelStyle(.iconOnly) // freq/QSO opt into text themselves
                            .padding(.horizontal, 14)
                            .frame(height: 38)
                            .glassCapsule()
                        }
                        .padding(.top, 12)
                        .padding(.trailing, 10) // flush with the side control stack below
                    }
                }
                .overlay(alignment: .bottom) {
                    // Waterfall floats over the map like the other panels
                    if showWaterfall {
                        WaterfallPane(processor: actions.waterfall, transmit: transmit, controller: controller)
                            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.leading, max(10, panelObscuredWidth + 10))
                            .padding(.bottom, 10)
                            .padding(.trailing, 10)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Waterfall closed: a lone glass toggle where it lived,
                    // mirroring the sidebar's reopen button
                    if !showWaterfall {
                        Button {
                            showWaterfall = true
                        } label: {
                            Image(systemName: "rectangle.bottomthird.inset.filled")
                                .foregroundStyle(.secondary)
                                .frame(width: 38, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .glassCapsule()
                        .help("Show the waterfall")
                        .padding(.trailing, 10)
                        .padding(.bottom, 10)
                    }
                }
        }
        .background(WindowAccessor(isFullScreen: $isFullScreen))
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            if !isFullScreen {
                toolbarItems
            }
        }
        .onChange(of: digiMode) { _, raw in
            if raw != DigiMode.wspr.rawValue {
                actions.setWSPRBeacon(false)
            }
            if let mode = DigiMode(rawValue: raw) {
                actions.digiModeChanged(to: mode)
            }
        }
        .onAppear {
            // Feed-era migration: the column-table default width (540) reads
            // as the new narrow default once
            if sidebarWidth == 540 { sidebarWidth = 360 }
            devices = AudioDevices.inputDevices()
            autoSelectDigirig()
            if !cat.portPath.isEmpty {
                cat.connect()
            }
            if CommandLine.arguments.contains("--demo") {
                // Exercise the click-to-map path in demo screenshots:
                // prefer a directed message whose addressee is also mapped
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let twoPin = store.messages.first {
                        $0.coordinate != nil && !$0.isCQ
                            && $0.addressee.map { a in
                                a != "W0CJW" && store.stations[a] != nil
                            } == true
                    }
                    selectedMessageID = (twoPin ?? store.messages.first { $0.coordinate != nil })?.id
                }
                // Show the QSO status panel (AppModel.demoMode guarantees
                // demo never keys the radio)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    actions.startCQ()
                }
            }
        }
        .navigationTitle("Squelch")
    }

    /// Points of the map covered by the left-side floating panel.
    private var panelObscuredWidth: CGFloat {
        showSidebar ? sidebarWidth : 0
    }

    /// Apple Maps sidebar: flush to the window's top-left, traffic lights
    /// floating over its header, toggle button top-right of the header.
    /// The header rides as the list's top inset, so rows under-scroll
    /// beneath its glass exactly like Maps. Selecting a station docks its
    /// detail into the panel's bottom half (stacked master-detail) — the
    /// feed stays live above it.
    private var panelStack: some View {
        VStack(spacing: 0) {
            feedPane
            if let call = selectedStationCall {
                Divider()
                StationDetailView(
                    callsign: call,
                    store: store,
                    stateResolver: actions.stateResolver,
                    qsoLog: qsoLog,
                    location: location,
                    onClose: { selectedStationCall = nil },
                    onReply: { message in actions.reply(to: message) },
                    replyEnabled: txAvailable && sequencer.mode == .idle
                )
                .frame(height: 380)
            }
        }
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(.thickMaterial) // regular lets bright map bleed through in light mode
        .overlay(alignment: .trailing) {
            sidebarResizeHandle
        }
        .ignoresSafeArea(edges: .top) // full window height, flush corners
    }

    private var feedPane: some View {
        LogPane(
            store: store,
            stateResolver: actions.stateResolver,
            // Selection and card-open must land in the SAME
            // transaction: the map computes its focus region
            // from the panel-obscured width, so opening the
            // card one update later would center the target
            // behind the panels
            selection: Binding(
                get: { selectedMessageID },
                set: { id in
                    selectedMessageID = id
                    if let id,
                       let call = store.messages.first(where: { $0.id == id })?.callsign,
                       call != myCallsign {
                        selectedStationCall = call
                    }
                }
            ),
            onReply: { message in actions.reply(to: message) },
            replyEnabled: txAvailable && sequencer.mode == .idle
        ) {
            HStack {
                Spacer()
                Button {
                    showSidebar = false
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Hide the sidebar")
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture()) // header drags the window, like Apple Maps
        }
    }

    // Volatile status and stable actions live in SEPARATE toolbar groups:
    // each gets its own glass capsule, so a chip appearing, disappearing,
    // or changing width never re-shapes the container around the buttons.
    // The same two-container structure is used by the fullscreen bar.
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
            ToolbarItemGroup {
                Spacer()
            }
            ToolbarItemGroup {
                statusCluster(inToolbar: true)
            }
            ToolbarItemGroup {
                actionControls
            }
    }

    /// Whether the volatile cluster has anything to show — the fullscreen
    /// bar hides its capsule entirely when empty.
    private var statusClusterVisible: Bool {
        let catTrouble = !cat.portPath.isEmpty
            && (!cat.isConnected || (cat.radioModeName != nil && cat.radioModeName != "DATA-USB"))
        let chipActive = transmit.anyTXActive
            || actions.pendingReply != nil
            || sequencer.mode != .idle
            || actions.wsprBeaconEnabled
            || transmit.txError != nil
            || controller.isRunning
        return catTrouble || chipActive
    }

    /// Volatile: CAT trouble light + the TX/QSO/beacon/decoding chip.
    /// Isolated so its constant shape-shifting stays in its own container.
    @ViewBuilder
    private func statusCluster(inToolbar: Bool) -> some View {
                // CAT trouble light: appears only when CAT is configured
                // but disconnected, or the radio wandered off DATA-USB
                if !cat.portPath.isEmpty,
                   !cat.isConnected || (cat.radioModeName != nil && cat.radioModeName != "DATA-USB") {
                    HStack(spacing: 5) {
                        Image(systemName: cat.isConnected ? "cable.connector" : "cable.connector.slash")
                        Text(cat.isConnected
                             ? "Radio in \(cat.radioModeName ?? "?")"
                             : "CAT offline")
                            .font(.callout)
                    }
                    .frame(height: 26)
                    .foregroundStyle(.orange)
                    .padding(.leading, inToolbar ? 14 : 6)
                    .padding(.trailing, 6)
                    .help(cat.isConnected
                          ? "CAT connected — radio is in \(cat.radioModeName ?? "?"), not DATA-USB (the app switches it before TX)"
                          : (cat.lastError ?? "CAT not connected — radio off? Retrying automatically."))
                }

                // Status chip: TX / answer / session / beacon / error /
                // decoding vitals — appears only when something is happening
                QSOStatusPanel(sequencer: sequencer, transmit: transmit, model: actions, controller: controller,
                               edgeInset: inToolbar ? 14 : 8)
    }

    /// Stable: constant membership, near-constant width — this container
    /// must never visibly move.
    @ViewBuilder
    private var actionControls: some View {
                Button {
                    showFrequencies.toggle()
                } label: {
                    Label("\(mhzText(dialFrequencyMHz)) MHz · \(digiMode) · \(bandName(forMHz: dialFrequencyMHz))",
                          systemImage: "dial.medium")
                        .monospacedDigit()
                        .labelStyle(.titleAndIcon)
                }
                .help(cat.isConnected
                      ? "QSY the radio via CAT (connected)"
                      : "Set the working frequency. Connect CAT in Settings to also tune the radio.")
                .popover(isPresented: $showFrequencies, arrowEdge: .bottom) {
                    FrequencyFlyout(
                        license: licenseClass,
                        currentMHz: dialFrequencyMHz,
                        onPick: { preset in
                            actions.qsy(to: preset)
                            showFrequencies = false
                        }
                    )
                }

                Button {
                    openWindow(id: "qso-log")
                } label: {
                    Label(qsoLog.records.isEmpty ? "QSO Log" : "\(qsoLog.records.count) QSOs",
                          systemImage: "checkmark.seal")
                        .monospacedDigit()
                        .labelStyle(.titleAndIcon) // toolbar default hides the count
                }
                .help("Completed contacts (⌘L) — add off-app QSOs from there")

                Button {
                    toggleRunning()
                } label: {
                    if controller.isRunning {
                        Label("Stop", systemImage: "stop.fill")
                    } else {
                        Label("Start", systemImage: "play.fill")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .help(controller.isRunning ? "Stop decoding" : "Start decoding FT8")

                if isWSPRMode {
                    Button {
                        actions.setWSPRBeacon(!actions.wsprBeaconEnabled)
                    } label: {
                        Label(actions.wsprBeaconEnabled ? "Stop Beacon" : "Beacon",
                              systemImage: "dot.radiowaves.up.forward")
                    }
                    .disabled(!actions.wsprBeaconEnabled && !txAvailable)
                    .help(txDisabledReason ?? "Transmit WSPR at the configured duty cycle; spots of your signal appear on wsprnet receivers worldwide")
                } else {
                    Button {
                        if sequencer.mode == .idle {
                            actions.startCQ()
                        } else {
                            actions.haltTX()
                        }
                    } label: {
                        Label(sequencer.mode == .idle ? "Call CQ" : "Stop CQ",
                              systemImage: sequencer.mode == .idle ? "megaphone.fill" : "megaphone")
                    }
                    .disabled(sequencer.mode == .idle && !txAvailable)
                    .help(txDisabledReason ?? "Call CQ repeatedly and answer stations that come back")
                }

                Button {
                    showCheatsheet.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .help("How to read FT8 messages")
                .popover(isPresented: $showCheatsheet, arrowEdge: .bottom) {
                    CheatsheetView()
                }
    }

    /// Frequency picker flyout, MapModeFlyout-style: real columns, current
    /// selection highlighted, receive-only section per license class.
    private struct FrequencyFlyout: View {
        let license: LicenseClass
        let currentMHz: Double
        let onPick: (QSYPreset) -> Void

        var body: some View {
            let txList = QSYPreset.transmitLegal(for: license)
            let rxOnly = QSYPreset.receiveOnly(for: license)
            VStack(alignment: .leading, spacing: 6) {
                Text("Frequency")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                ForEach(txList) { preset in
                    row(preset)
                }
                if !rxOnly.isEmpty {
                    if !txList.isEmpty {
                        Divider()
                        Text("Receive only")
                            .font(.caption)
                            .foregroundStyle(.primary.opacity(0.6))
                            .padding(.leading, 8)
                    }
                    ForEach(rxOnly) { preset in
                        row(preset)
                    }
                }
            }
            .padding(12)
        }

        private func row(_ preset: QSYPreset) -> some View {
            let selected = abs(preset.mhz - currentMHz) < 0.00005
            return Button {
                onPick(preset)
            } label: {
                HStack(spacing: 0) {
                    Text("\(String(format: "%.4f", preset.mhz)) MHz")
                        .monospacedDigit()
                        .frame(width: 110, alignment: .trailing)
                    Text(preset.mode.rawValue)
                        .frame(width: 56, alignment: .leading)
                        .padding(.leading, 14)
                    Text(bandName(forMHz: preset.mhz))
                        .frame(width: 36, alignment: .leading)
                        .foregroundStyle(.primary.opacity(0.7))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    selected ? Color.accentColor.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Slim grab strip on the sidebar's trailing edge; drag to resize,
    /// width persists across launches. pointerStyle supplies the system
    /// resize cursor (no more NSCursor push/pop bookkeeping); the strip
    /// stays custom because a floating panel has no native resizer.
    private var sidebarResizeHandle: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 10)
            .contentShape(Rectangle())
            .offset(x: 5) // straddle the edge: half over map, half inside
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = sidebarDragStartWidth ?? sidebarWidth
                        sidebarDragStartWidth = start
                        sidebarWidth = min(900, max(300, start + value.translation.width))
                    }
                    .onEnded { _ in sidebarDragStartWidth = nil }
            )
    }

    private var selectedMessage: DecodedMessage? {
        guard let id = selectedMessageID else { return nil }
        return store.messages.first { $0.id == id }
    }

    private var isWSPRMode: Bool {
        digiMode == DigiMode.wspr.rawValue
    }

    private var licenseClass: LicenseClass {
        LicenseClass(rawValue: licenseClassRaw) ?? .technician
    }

    private var txLegal: Bool {
        TransmitController.isTXLegalMHz(dialFrequencyMHz, license: licenseClass)
    }

    private var txAvailable: Bool {
        controller.isRunning && txLegal
    }

    private var canReplyToSelection: Bool {
        guard txAvailable, sequencer.mode == .idle, !transmit.anyTXActive,
              let message = selectedMessage else { return false }
        return message.isAnswerable(by: myCallsign)
    }

    private var txDisabledReason: String? {
        if licenseClass == .unlicensed {
            return "License class is None — receive only (set yours in Settings)"
        }
        if !txLegal {
            return String(format: "%.3f MHz is outside %@ data privileges — TX disabled", dialFrequencyMHz, licenseClass.rawValue)
        }
        if !controller.isRunning {
            return "Start decoding first — the QSO sequencer needs receive slots"
        }
        return nil
    }

    private func toggleRunning() {
        if controller.isRunning {
            // A stopped decoder can't drive the sequencer — halt any
            // session/pending reply instead of leaving them armed and dead
            actions.haltTX()
            controller.stop()
        } else {
            // Re-enumerate at start so a just-plugged Digirig is found;
            // the device itself is chosen in Settings → Audio Input
            devices = AudioDevices.inputDevices()
            let device = devices.first { $0.uid == audioDeviceUID }
            controller.start(device: device)
            // Pre-start the TX engine so its device reconfiguration hits
            // now, while the capture's config-change handler can absorb it
            transmit.warmUp()
        }
    }

    /// On first launch, pre-select what looks like the Digirig.
    private func autoSelectDigirig() {
        guard audioDeviceUID.isEmpty else { return }
        if let digirig = AudioDevices.likelyDigirig(in: devices) {
            audioDeviceUID = digirig.uid
        }
    }
}
