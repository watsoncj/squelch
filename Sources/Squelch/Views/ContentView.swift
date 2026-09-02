import SwiftUI

struct ContentView: View {
    @ObservedObject var store: DecodeStore
    @ObservedObject var controller: DecodeController
    @ObservedObject var location: LocationProvider
    @ObservedObject var transmit: TransmitController
    @ObservedObject var sequencer: QSOSequencer
    @ObservedObject var qsoLog: QSOLog
    @ObservedObject var cat: CATController
    @ObservedObject var wsprNet: WSPRNetService
    @ObservedObject var updater: UpdateChecker
    @ObservedObject var actions: AppModel

    @AppStorage(SettingsKeys.audioDeviceUID) private var audioDeviceUID = ""
    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = ""
    @AppStorage(SettingsKeys.dialFrequencyMHz) private var dialFrequencyMHz = 14.074
    @AppStorage(SettingsKeys.digiMode) private var digiMode = DigiMode.ft8.rawValue
    @AppStorage(SettingsKeys.showWaterfall) private var showWaterfall = false
    @AppStorage(SettingsKeys.waterfallHeight) private var waterfallHeight = 110.0
    @AppStorage(SettingsKeys.waterfallMaximized) private var waterfallMaximized = false
    @AppStorage(SettingsKeys.licenseClass) private var licenseClassRaw = LicenseClass.technician.rawValue
    @AppStorage(SettingsKeys.sidebarWidth) private var sidebarWidth = 360.0
    @AppStorage(SettingsKeys.showSidebar) private var showSidebar = true
    @AppStorage(SettingsKeys.huntEnabled) private var huntEnabled = false
    @AppStorage(SettingsKeys.activeContest) private var activeContest = ""
    @State private var sidebarDragStartWidth: Double?
    @State private var selectedStationCall: String?
    @State private var showCheatsheet = false
    @State private var showFrequencies = false
    @State private var showHunt = false
    @State private var showCQ = false
    @State private var showJS8Composer = false
    @AppStorage("js8SidebarTab") private var js8SidebarChats = false
    @State private var js8HeardByDismissed = false
    /// Composer draft — outlives the popover so collapsing it doesn't eat
    /// half-typed text; cleared when a message is queued for transmit.
    @State private var js8ComposerText = ""
    @State private var devices: [AudioDevice] = []
    @State private var selectedMessageID: DecodedMessage.ID?
    @State private var isFullScreen = false
    @State private var beaconReportsDismissed = false
    @Environment(\.openWindow) private var openWindow

    private var qsoLogButtonTitle: String {
        let base = qsoLog.records.isEmpty ? "QSO Log" : "\(qsoLog.records.count) QSOs"
        return activeContest.isEmpty ? base : "\(base) · \(activeContest)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Apple Maps treatment: the map fills the window and the log
            // floats over it as a translucent sidebar
            MapPane(store: store, location: location, stateResolver: actions.stateResolver, selectedMessage: selectedMessage,
                    beaconReports: wsprNet.reports,
                    onSelectStation: { call in
                        selectedStationCall = call
                        showSidebar = true // detail docks in the sidebar now
                    },
                    leadingObscuredWidth: panelObscuredWidth,
                    bottomObscuredHeight: waterfallObscuredHeight)
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
                                    statusCluster
                                }
                                .buttonStyle(.borderless)
                                .padding(.horizontal, 12) // container-owned edge insets
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
                        .padding(.top, 8) // match the native toolbar capsule's top offset
                        .padding(.trailing, 10) // flush with the side control stack below
                    }
                }
                .overlay(alignment: .bottom) {
                    // Waterfall floats over the map like the other panels
                    if showWaterfall {
                        WaterfallPane(processor: actions.waterfall, transmit: transmit, controller: controller,
                                      highlightMessages: waterfallHighlights, store: store, sequencer: sequencer,
                                      onSelectMessage: { actions.focusedMessageID = $0 })
                            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.leading, max(10, panelObscuredWidth + 10))
                            .padding(.bottom, 10)
                            .padding(.trailing, 10)
                            // Maximized fills the map. Windowed, the safe
                            // area already keeps it below the toolbar; full
                            // screen has no inset (toolbar auto-hides), so
                            // clear the floating capsules explicitly.
                            .padding(.top, waterfallMaximized && isFullScreen ? 56 : 0)
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
        .onChange(of: actions.focusedMessageID) { _, id in
            // Chip callsign clicked: select the station's latest decode
            // (LogPane reveals whatever gets selected). Mirror the list
            // binding's side effect — the station card follows
            // selectedStationCall, not the row selection.
            guard let id else { return }
            selectedMessageID = id
            if let call = store.messages.first(where: { $0.id == id })?.callsign,
               call != myCallsign {
                selectedStationCall = call
            }
            actions.focusedMessageID = nil
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            if !isFullScreen {
                toolbarItems
            }
        }
        .onChange(of: huntEnabled) { _, on in
            actions.huntToggled(on: on)
        }
        .onChange(of: digiMode) { _, raw in
            if raw != DigiMode.wspr.rawValue {
                actions.setWSPRBeacon(false)
            }
            if let mode = DigiMode(rawValue: raw) {
                actions.digiModeChanged(to: mode)
            }
        }
        // Closing the reports card is "not now", not "never" — arming the
        // beacon again brings it back
        .onChange(of: actions.wsprBeaconEnabled) { _, on in
            if on { beaconReportsDismissed = false }
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

    /// Points of the map covered by the floating waterfall at the bottom.
    /// Maximized covers everything — no visible strip to center in, and
    /// the moment it un-maximizes the regular height applies again.
    private var waterfallObscuredHeight: CGFloat {
        guard showWaterfall, !waterfallMaximized else { return 0 }
        return waterfallHeight + 10 // pane + its bottom padding
    }

    /// Apple Maps sidebar: flush to the window's top-left, traffic lights
    /// floating over its header, toggle button top-right of the header.
    /// The header rides as the list's top inset, so rows under-scroll
    /// beneath its glass exactly like Maps. Selecting a station docks its
    /// detail into the panel's bottom half (stacked master-detail) — the
    /// feed stays live above it.
    private var panelStack: some View {
        VStack(spacing: 0) {
            if isJS8Mode, js8SidebarChats {
                VStack(spacing: 0) {
                    sidebarHeaderRow // same chrome as the feed's header
                    Divider()
                    JS8ChatsPane(
                        store: actions.js8Chats,
                        js8: actions.js8,
                        myCall: myCallsign,
                        txAvailable: txAvailable,
                        decoding: controller.isRunning,
                        onSend: { text, partner in
                            actions.sendJS8(text: text, selectedCall: partner)
                        },
                        includeObserved: actions.js8.joinedGroups.isEmpty
                    )
                }
            } else {
                feedPane
            }
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
            } else if isJS8Mode, !actions.js8.heardBy.isEmpty, !js8HeardByDismissed {
                Divider()
                JS8HeardByView(js8: actions.js8, onClose: { js8HeardByDismissed = true })
            } else if wsprNet.reportsRelevant && !beaconReportsDismissed {
                // Beacon on (or just off): who's hearing us, from WSPRnet.
                // Station selection wins the slot — reports return when the
                // detail card closes.
                Divider()
                BeaconReportsView(
                    wsprNet: wsprNet,
                    onClose: { beaconReportsDismissed = true }
                )
                .frame(height: 300)
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

    /// Feed ↔ Chats, JS8 mode only. Lives inside the sidebar's header row
    /// (clear of the traffic lights); the unread badge makes the tab worth
    /// glancing at when a message lands while you're watching the feed.
    private var js8TabPicker: some View {
        let unread = actions.js8Chats.totalUnread
        return Picker("", selection: $js8SidebarChats) {
            Text("Feed").tag(false)
            Text(unread > 0 ? "Chats (\(unread))" : "Chats").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 170)
    }

    /// The sidebar's top chrome: window-drag strip, centered mode tabs in
    /// JS8, hide-sidebar toggle at the trailing edge — identical for the
    /// feed (as its list header) and the Chats pane.
    private var sidebarHeaderRow: some View {
        HStack {
            Spacer()
            if isJS8Mode {
                js8TabPicker
            }
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
            onJS8Compose: { message in
                // Prefill: a raw "CALL SNR?" query passes through as-is;
                // otherwise address the sender
                js8ComposerText = message.text.hasSuffix("SNR?") ? message.text : "\(message.callsign ?? "") "
                showJS8Composer = true
            },
            replyEnabled: txAvailable && sequencer.mode == .idle,
            micDenied: controller.micDenied,
            workedCalls: qsoLog.workedCalls,
            dupeCalls: CQHunter.dupeCalls(
                records: qsoLog.records,
                dialMHz: dialFrequencyMHz,
                contest: activeContest.isEmpty ? nil : activeContest
            ),
            contestName: activeContest.isEmpty ? nil : activeContest,
            js8Pending: isJS8Mode ? actions.js8.pending : [],
            js8FilterAvailable: isJS8Mode,
            js8Groups: isJS8Mode ? actions.js8.joinedGroups : []
        ) {
            sidebarHeaderRow
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
                if statusClusterVisible {
                    HStack(spacing: 14) {
                        statusCluster
                    }
                    .padding(.horizontal, 12) // container-owned edge insets
                }
            }
            // Capsule grouping follows spacers, not item groups: without
            // this, macOS fuses status + actions into one glass slab and
            // chip changes re-shape it around the buttons.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed)
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
            || transmit.txNotice != nil
            || controller.micDenied
            || controller.startError != nil
            || controller.isRunning
        return catTrouble || chipActive || updater.readyVersion != nil
    }

    /// Volatile: CAT trouble light + the TX/QSO/beacon/decoding chip.
    /// Isolated so its constant shape-shifting stays in its own container.
    @ViewBuilder
    private var statusCluster: some View {
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
                    .help(cat.isConnected
                          ? "CAT connected — radio is in \(cat.radioModeName ?? "?"), not DATA-USB (the app switches it before TX)"
                          : (cat.lastError ?? "CAT not connected — radio off? Retrying automatically."))
                }

                // Status chip: TX / answer / session / beacon / error /
                // decoding vitals — appears only when something is happening
                QSOStatusPanel(sequencer: sequencer, transmit: transmit, model: actions, controller: controller)

                // Update chip: appears only once the new version is
                // downloaded AND signature-verified; the user picks the
                // restart moment. Guarded against mid-QSO fat-fingers.
                if let version = updater.readyVersion {
                    let midQSO = transmit.anyTXActive
                        || sequencer.mode != .idle
                        || actions.pendingReply != nil
                    Button {
                        updater.installAndRelaunch()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            Text("\(version) ready — Restart")
                                .font(.callout)
                        }
                        .frame(height: 26)
                        .foregroundStyle(.green)
                    }
                    .buttonStyle(.borderless)
                    .disabled(midQSO)
                    .help(midQSO
                          ? "Squelch \(version) is ready — restart is held until the QSO/TX finishes"
                          : "Squelch \(version) is downloaded and verified — click to restart into it")
                }
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
                        currentMode: DigiMode(rawValue: digiMode) ?? .ft8,
                        onPick: { preset in
                            actions.qsy(to: preset)
                            showFrequencies = false
                        },
                        onPickSpeed: { mode in
                            actions.setDigiMode(mode)
                            showFrequencies = false
                        }
                    )
                }

                Button {
                    openWindow(id: "qso-log")
                } label: {
                    // The contest name rides along as a standing reminder that
                    // contest tagging is on — easy to forget come Tuesday
                    Label(qsoLogButtonTitle, systemImage: "checkmark.seal")
                        .monospacedDigit()
                        .labelStyle(.titleAndIcon) // toolbar default hides the count
                }
                .help(activeContest.isEmpty
                      ? "Completed contacts (⌘L) — add off-app QSOs from there"
                      : "Completed contacts (⌘L) — new QSOs are being tagged \(activeContest)")

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
                } else if isJS8Mode {
                    Button {
                        showJS8Composer.toggle()
                    } label: {
                        Label("Message", systemImage: actions.js8.isSending ? "paperplane.fill" : "paperplane")
                            .foregroundStyle(actions.js8.isSending ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                    }
                    .help("Compose a JS8 message — free text, or a directed command to a station")
                    .popover(isPresented: $showJS8Composer, arrowEdge: .bottom) {
                        JS8ComposerFlyout(
                            js8: actions.js8,
                            text: $js8ComposerText,
                            txAvailable: txAvailable,
                            txDisabledReason: txDisabledReason,
                            decoding: controller.isRunning,
                            grid: String((actions.location.effectiveGrid ?? "").prefix(4)),
                            onSend: { text in
                                if actions.sendJS8(text: text) {
                                    js8ComposerText = ""
                                    showJS8Composer = false
                                }
                            },
                            onHalt: { actions.haltTX() }
                        )
                    }

                    Menu {
                        Button("Send Now") {
                            actions.sendJS8Heartbeat()
                        }
                        .disabled(!txAvailable || !controller.isRunning || actions.js8.isSending)
                        Divider()
                        Picker("Automatically", selection: Binding(
                            get: { UserDefaults.standard.integer(forKey: SettingsKeys.js8HBIntervalMinutes) },
                            set: { UserDefaults.standard.set($0, forKey: SettingsKeys.js8HBIntervalMinutes) }
                        )) {
                            Text("Off").tag(0)
                            Text("Every 10 minutes").tag(10)
                            Text("Every 15 minutes").tag(15)
                            Text("Every 30 minutes").tag(30)
                            Text("Every 60 minutes").tag(60)
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Heartbeat", systemImage: "waveform.path.ecg")
                    }
                    .help(txDisabledReason ?? "Send a heartbeat (@HB with your grid) now, or on a timer — Normal speed only, in the 500–1000 Hz heartbeat sub-band, never over a conversation. Stations that hear it reply with your signal report.")

                    // Speed lives here as well as in the frequency flyout
                    // so it's one click away.
                    Menu {
                        ForEach(DigiMode.js8Speeds) { speed in
                            Button {
                                actions.setDigiMode(speed)
                            } label: {
                                if speed.rawValue == digiMode {
                                    Label(speed.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(speed.rawValue)
                                }
                            }
                        }
                    } label: {
                        Label("Speed", systemImage: "speedometer")
                    }
                    .help("JS8 speed — slower is more sensitive, faster carries more text per minute. Changing it restarts decoding.")
                } else {
                    Button {
                        showCQ.toggle()
                    } label: {
                        Label("Call CQ", systemImage: sequencer.cqRunActive ? "megaphone.fill" : "megaphone")
                            .foregroundStyle(sequencer.cqRunActive ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                    }
                    .help("Call CQ and answer stations that come back — pick a flavor (DX, POTA…) and how often to call")
                    .popover(isPresented: $showCQ, arrowEdge: .bottom) {
                        CQFlyout(
                            sequencer: sequencer,
                            txAvailable: txAvailable,
                            txDisabledReason: txDisabledReason,
                            onStart: { actions.startCQ(); showCQ = false },
                            onStop: { actions.haltTX(); showCQ = false }
                        )
                    }

                    Button {
                        showHunt.toggle()
                    } label: {
                        Label("Hunt", systemImage: huntEnabled ? "binoculars.fill" : "binoculars")
                            .foregroundStyle(huntEnabled ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                    }
                    .help("Auto-reply — answer stations calling you, and hunt CQs from new ones: DX, unworked states, unworked countries")
                    .popover(isPresented: $showHunt, arrowEdge: .bottom) {
                        HuntFlyout()
                    }
                }

                Button {
                    showCheatsheet.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .help("How to read \(DigiMode(rawValue: digiMode)?.isJS8 == true ? "JS8 traffic" : "\(digiMode) messages")")
                .popover(isPresented: $showCheatsheet, arrowEdge: .bottom) {
                    CheatsheetView()
                }
    }



    /// CQ caller flyout, HuntFlyout-style: start/stop the run and shape
    /// it — a directed-CQ flavor (CQ DX, CQ POTA, custom) and a duty
    /// cycle (call every Nth of our slots, pure listen in between). Both
    /// are re-read each slot, so changes apply live mid-run. The preview
    /// row shows the exact message that goes on the air.
    private struct CQFlyout: View {
        @ObservedObject var sequencer: QSOSequencer
        let txAvailable: Bool
        let txDisabledReason: String?
        let onStart: () -> Void
        let onStop: () -> Void

        @AppStorage(SettingsKeys.myCallsign) private var myCallsign = ""
        @AppStorage(SettingsKeys.myGrid) private var myGrid = ""
        @AppStorage(SettingsKeys.cqModifier) private var modifier = ""
        @AppStorage(SettingsKeys.cqSlotInterval) private var interval = 1
        @State private var customFlavor = false
        @FocusState private var customFieldFocused: Bool

        private static let presets = ["DX", "WW", "TEST", "POTA", "SOTA"]

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Call CQ")
                    .font(.headline)
                    .frame(maxWidth: .infinity)

                // The exact message that goes on the air
                Text(previewText)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Text("Flavor")
                        Picker("", selection: flavorSelection) {
                            Text("Plain CQ").tag("")
                            ForEach(Self.presets, id: \.self) { Text("CQ \($0)").tag($0) }
                            Divider()
                            Text("Custom…").tag("custom")
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow {
                        Text("Call every")
                        Picker("", selection: $interval) {
                            Text("slot").tag(1)
                            Text("2nd slot").tag(2)
                            Text("3rd slot").tag(3)
                            Text("4th slot").tag(4)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("How often to transmit while calling — skipped slots just listen; an answer landing in one is worked right away")
                    }
                }

                if customFlavor {
                    TextField("Up to 4 letters (QRP, EU…)", text: $modifier)
                        .textFieldStyle(.roundedBorder)
                        .focused($customFieldFocused)
                        .onChange(of: modifier) { _, raw in
                            // Keep it FT8-packable as they type: A–Z/0–9, max 4
                            let cleaned = String(raw.uppercased()
                                .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                                .prefix(4))
                            if cleaned != raw { modifier = cleaned }
                        }
                    if !modifier.isEmpty && !QSOSequencer.isValidCQModifier(modifier) {
                        Text("FT8 can't carry this one — 1–4 letters (or exactly 3 digits). Calling plain CQ until it fits.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(width: 220, alignment: .leading)
                    }
                }

                Divider()

                if sequencer.cqRunActive {
                    Button {
                        onStop()
                    } label: {
                        Label("Stop Calling", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        onStart()
                    } label: {
                        Label("Start Calling", systemImage: "megaphone.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!txAvailable)
                    if let reason = txDisabledReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(width: 220, alignment: .leading)
                    }
                }
            }
            .padding(14)
            .frame(width: 248)
            .onAppear {
                customFlavor = !modifier.isEmpty && !Self.presets.contains(modifier)
            }
        }

        /// Menu selection over the stored modifier: presets map straight
        /// through; "custom" pins the text field open (even while empty,
        /// which would otherwise read as Plain).
        private var flavorSelection: Binding<String> {
            Binding(
                get: {
                    if customFlavor { return "custom" }
                    return Self.presets.contains(modifier) ? modifier : ""
                },
                set: { choice in
                    if choice == "custom" {
                        customFlavor = true
                        customFieldFocused = true
                    } else {
                        customFlavor = false
                        modifier = choice
                    }
                }
            )
        }

        private var previewText: String {
            let mod = QSOSequencer.isValidCQModifier(modifier) ? modifier : ""
            let call = myCallsign.uppercased()
            let grid = String(myGrid.uppercased().prefix(4))
            return ["CQ", mod, call.isEmpty ? "MYCALL" : call, grid]
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    /// Auto-reply flyout: everything that keys the radio while idle, in
    /// one place. Answering stations that call us, plus hunt mode with
    /// its criteria checkboxes. Enabling hunt with nothing selected
    /// auto-picks DX so the switch never silently hunts nothing.
    private struct HuntFlyout: View {
        @AppStorage(SettingsKeys.autoAnswer) private var answerMe = false
        @AppStorage(SettingsKeys.huntEnabled) private var enabled = false
        @AppStorage(SettingsKeys.huntDX) private var dx = false
        @AppStorage(SettingsKeys.huntNewStates) private var newStates = false
        @AppStorage(SettingsKeys.huntNewCountries) private var newCountries = false
        @AppStorage(SettingsKeys.huntWW) private var ww = false

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Auto-Reply")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                Toggle("Answer stations calling me", isOn: $answerMe)
                    .toggleStyle(.switch)
                    .help("While idle, a station calling you directly arms a reply")
                Divider()
                Toggle("Hunt CQs from new ones", isOn: $enabled)
                    .toggleStyle(.switch)
                    .onChange(of: enabled) { _, on in
                        if on, !dx, !newStates, !newCountries, !ww {
                            dx = true
                        }
                    }
                Group {
                    Toggle("DX (outside my country)", isOn: $dx)
                        .help("Any CQ from a station outside your own country")
                    Toggle("Unseen states", isOn: $newStates)
                        .help("US stations in states missing from your QSO log — Worked All States, on autopilot")
                    Toggle("Unseen countries", isOn: $newCountries)
                        .help("Countries missing from your QSO log, judged by callsign prefix")
                    Toggle("CQ WW (WW Digi contest)", isOn: $ww)
                        .help("Stations calling CQ WW — WSJT-X's WW Digi contest call. Dupes are per band and per contest, so a station worked on another band is fair game again.")
                }
                .disabled(!enabled)
                Text("Any match arms a reply with a countdown — cancel it from the toolbar chip to stay quiet. A station calling you beats a hunted CQ; stations already worked on this band (in this contest, if one is active) are skipped and directed CQs (CQ DX, CQ EU) are respected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 240, alignment: .leading)
            }
            .padding(14)
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

    /// Every decode from the selected station — the waterfall boxes each
    /// of their transmissions, not just the selected row's slot.
    private var waterfallHighlights: [DecodedMessage] {
        guard let call = selectedMessage?.callsign else { return [] }
        return store.messages.filter { $0.callsign == call }
    }

    private var isWSPRMode: Bool {
        digiMode == DigiMode.wspr.rawValue
    }

    /// Frequency picker flyout, master-detail: modes stacked on the left,
    /// that mode's frequencies on the right (with the receive-only split
    /// per license class). JS8's speed strip lives with the JS8 mode.
    private struct FrequencyFlyout: View {
        let license: LicenseClass
        let currentMHz: Double
        let currentMode: DigiMode
        let onPick: (QSYPreset) -> Void
        let onPickSpeed: (DigiMode) -> Void

        /// The mode being browsed — starts on whatever is active (any JS8
        /// speed browses as JS8). Selecting here changes only the list;
        /// the radio moves when a frequency is clicked.
        @State private var browsing: DigiMode = .ft8
        @State private var appeared = false

        private static let modes: [DigiMode] = [.ft8, .ft4, .js8, .wspr]

        private var activeAsBrowsable: DigiMode {
            currentMode.isJS8 ? .js8 : currentMode
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Frequency")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Self.modes) { mode in
                            modeRow(mode)
                        }
                    }
                    Divider()
                        .padding(.horizontal, 8)
                    VStack(alignment: .leading, spacing: 4) {
                        if browsing == .js8 {
                            speedPicker
                            Divider()
                        }
                        frequencyList
                    }
                    .frame(minWidth: 190, alignment: .leading)
                }
            }
            .padding(12)
            .onAppear {
                if !appeared {
                    appeared = true
                    browsing = activeAsBrowsable
                }
            }
        }

        private func modeRow(_ mode: DigiMode) -> some View {
            let isBrowsing = browsing == mode
            let isActive = activeAsBrowsable == mode
            return Button {
                browsing = mode
            } label: {
                HStack(spacing: 5) {
                    Text(mode.rawValue)
                        .fontWeight(isActive ? .semibold : .regular)
                        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                    Spacer(minLength: 0)
                    if isActive {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: 78, alignment: .leading)
                .background(
                    isBrowsing ? Color.primary.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isActive ? "\(mode.rawValue) — the active mode" : "Show \(mode.rawValue) frequencies")
        }

        @ViewBuilder
        private var frequencyList: some View {
            // Low band to high: 80m at the top, VHF at the bottom
            let presets = QSYPreset.all.filter { $0.mode == browsing }.sorted { $0.mhz < $1.mhz }
            let txList = presets.filter { license.canTransmitData(mhz: $0.mhz) }
            let rxOnly = presets.filter { !license.canTransmitData(mhz: $0.mhz) }
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

        /// JS8 speeds share a frequency; the rows carry NORMAL and the
        /// strip switches speed in place.
        private var speedPicker: some View {
            HStack(spacing: 4) {
                Text("Speed")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.6))
                    .padding(.trailing, 2)
                    .lineLimit(1)
                ForEach(DigiMode.js8Speeds) { speed in
                    Button {
                        onPickSpeed(speed)
                    } label: {
                        Text(speed.rawValue.replacingOccurrences(of: "JS8 ", with: ""))
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                speed == currentMode ? Color.accentColor.opacity(0.25) : .clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(speedHelp(speed))
                }
            }
            .padding(.horizontal, 8)
            // Size to the labels — the column otherwise squeezes the
            // strip to the frequency rows' width and wraps every word
            .fixedSize()
        }

        private func speedHelp(_ speed: DigiMode) -> String {
            String(format: "%@ — %g s period, %.0f Hz wide", speed.rawValue, speed.slotSeconds, speed.toneSpanHz)
                + (speed == .js8Ultra ? " (experimental upstream)" : "")
        }

        private func row(_ preset: QSYPreset) -> some View {
            let selected = abs(preset.mhz - currentMHz) < 0.00005
                && (preset.mode == currentMode || (preset.mode == .js8 && currentMode.isJS8))
            return Button {
                onPick(preset)
            } label: {
                HStack(spacing: 0) {
                    Text("\(String(format: "%.4f", preset.mhz)) MHz")
                        .monospacedDigit()
                        .frame(width: 110, alignment: .trailing)
                    Text(bandName(forMHz: preset.mhz))
                        .frame(width: 44, alignment: .leading)
                        .padding(.leading, 14)
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

    /// Composer flyout for JS8: free text or "CALL CMD …" directed lines.
    private struct JS8ComposerFlyout: View {
        @ObservedObject var js8: JS8Session
        @Binding var text: String
        let txAvailable: Bool
        let txDisabledReason: String?
        let decoding: Bool
        let grid: String
        let onSend: (String) -> Void
        let onHalt: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("JS8 Message")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                TextField("W0ABC MSG HELLO — or free text", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                    .onSubmit { send() }
                if let label = js8.txLabel {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Sending: \(label) — \(js8.txQueue.count) frame\(js8.txQueue.count == 1 ? "" : "s") to go")
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Button("Halt") { onHalt() }
                            .controlSize(.small)
                    }
                }
                HStack {
                    Button("CQ") { text = "CQ CQ CQ" + (grid.isEmpty ? "" : " \(grid)") }
                        .controlSize(.small)
                        .help("Fill in a CQ — edit the flavor (CQ DX, CQ QRP…) before sending")
                    Spacer()
                    Button("Send") { send() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSend)
                }
                if !txAvailable {
                    Text(txDisabledReason ?? "TX unavailable")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !decoding {
                    Text("Start decoding first — frames go out at slot boundaries.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Directed lines (\"CALL SNR?\", \"CALL MSG …\") use JS8 commands; anything else goes as free text with your callsign in front. One frame per \(Int(DigiMode.current.slotSeconds)) s slot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 320, alignment: .leading)
                }
            }
            .padding(12)
        }

        private var canSend: Bool {
            txAvailable && decoding && !js8.isSending && !text.trimmingCharacters(in: .whitespaces).isEmpty
        }

        private func send() {
            guard canSend else { return }
            onSend(text)
        }
    }

    private var isJS8Mode: Bool {
        DigiMode(rawValue: digiMode)?.isJS8 ?? false
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
            // Port-move healing, mirroring the TX side: the UID embeds the
            // USB location, so a moved Digirig comes back under a new UID —
            // match on stable identity and adopt it
            let resolved = AudioDevices.resolveInput(storedUID: audioDeviceUID, inputs: devices)
            if let resolved, resolved.healed {
                audioDeviceUID = resolved.device.uid
            }
            // wantedUID rides along so a stored UID that matches nothing
            // (Digirig actually unplugged) surfaces as the wrong-input chip
            // instead of silently decoding the built-in mic
            controller.start(device: resolved?.device, wantedUID: audioDeviceUID)
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
