import SwiftUI

/// The Mac app's Apple Maps paradigm, sized for iPad: full-bleed map,
/// floating translucent sidebar (feed + docked station detail), floating
/// waterfall, and a compact control capsule in place of the Mac toolbar.
struct PadContentView: View {
    @ObservedObject var model: PadModel
    @ObservedObject private var store: DecodeStore
    @ObservedObject private var controller: DecodeController
    @ObservedObject private var wsprNet: WSPRNetService

    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = ""
    @AppStorage(SettingsKeys.dialFrequencyMHz) private var dialFrequencyMHz = 14.074
    @AppStorage(SettingsKeys.digiMode) private var digiMode = DigiMode.ft8.rawValue
    @AppStorage(SettingsKeys.showWaterfall) private var showWaterfall = false
    @AppStorage(SettingsKeys.showSidebar) private var showSidebar = true

    @State private var selectedMessageID: DecodedMessage.ID?
    @State private var selectedStationCall: String?
    @State private var showSettings = false

    init(model: PadModel) {
        self.model = model
        self.store = model.store
        self.controller = model.controller
        self.wsprNet = model.wsprNet
    }

    private var selectedMessage: DecodedMessage? {
        selectedMessageID.flatMap { id in store.messages.first { $0.id == id } }
    }

    private var sidebarWidth: CGFloat { 360 }
    private var panelObscuredWidth: CGFloat { showSidebar ? sidebarWidth : 0 }

    var body: some View {
        MapPane(
            store: store,
            location: model.location,
            stateResolver: model.stateResolver,
            selectedMessage: selectedMessage,
            beaconReports: wsprNet.reports,
            onSelectStation: { call in
                selectedStationCall = call
                showSidebar = true
            },
            leadingObscuredWidth: panelObscuredWidth
        )
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            if showSidebar {
                panelStack
            } else {
                Button {
                    showSidebar = true
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .glassCapsule()
                .padding(.leading, 12)
                .padding(.top, 8)
            }
        }
        .overlay(alignment: .top) {
            controlCapsule
                .padding(.top, 8)
                .padding(.leading, panelObscuredWidth + 60)
        }
        .overlay(alignment: .bottom) {
            if showWaterfall {
                WaterfallPane(processor: model.waterfall, controller: controller)
                    .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.leading, max(10, panelObscuredWidth + 10))
                    .padding(.bottom, 10)
                    .padding(.trailing, 10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !showWaterfall {
                Button {
                    showWaterfall = true
                } label: {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .glassCapsule()
                .padding(.trailing, 10)
                .padding(.bottom, 10)
            }
        }
        .sheet(isPresented: $showSettings) {
            PadSettingsView(location: model.location, controller: controller, wsprNet: wsprNet)
        }
        // Decoding is useless if the iPad locks mid-slot
        .onChange(of: controller.isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
    }

    /// Start/Stop, frequency label (manual — no CAT on iPad), settings.
    /// Every control owns a >=44pt touch target — bare icon glyphs are
    /// unhittable on glass.
    private var controlCapsule: some View {
        HStack(spacing: 4) {
            Button {
                if controller.isRunning {
                    controller.stop()
                } else {
                    controller.start()
                }
            } label: {
                Label(controller.isRunning ? "Stop" : "Start",
                      systemImage: controller.isRunning ? "stop.fill" : "play.fill")
                    .padding(.horizontal, 12)
                    .frame(height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            frequencyMenu

            if controller.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let period = (DigiMode(rawValue: digiMode) ?? .ft8).slotSeconds
                    let fraction = context.date.timeIntervalSince1970
                        .truncatingRemainder(dividingBy: period) / period
                    SlotRing(fraction: fraction)
                }
                .padding(.horizontal, 6)
            }

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .glassCapsule()
    }

    private var frequencyMenu: some View {
        PadFrequencyMenu(controller: controller).equatable()
    }

    private var panelStack: some View {
        VStack(spacing: 0) {
            LogPane(
                store: store,
                stateResolver: model.stateResolver,
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
                onReply: nil,
                replyEnabled: false
            ) {
                HStack {
                    Text("Squelch")
                        .font(.headline)
                    Spacer()
                    Button {
                        showSidebar = false
                    } label: {
                        Image(systemName: "sidebar.leading")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
            }
            if let call = selectedStationCall {
                Divider()
                StationDetailView(
                    callsign: call,
                    store: store,
                    stateResolver: model.stateResolver,
                    qsoLog: model.qsoLog,
                    location: model.location,
                    onClose: { selectedStationCall = nil },
                    onReply: nil,
                    replyEnabled: false
                )
                .frame(height: 360)
            } else if wsprNet.reportsRelevant {
                Divider()
                BeaconReportsView(wsprNet: wsprNet, onClose: {})
                    .frame(height: 300)
            }
        }
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(.thickMaterial)
        // iPad Maps style: a floating rounded panel inside the safe area
        // (flush-to-edge here would run under the status bar)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding([.leading, .top, .bottom], 8)
    }
}

/// The frequency picker, quarantined from the parent's update stream:
/// decode-level publishes re-render PadContentView every second or so, and
/// each re-render rebuilds an open Menu's UIKit content — snapping its
/// scroll position back to the top. Equatable == true means parent updates
/// never touch it; its own @AppStorage still invalidates it directly.
private struct PadFrequencyMenu: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { true }

    let controller: DecodeController

    @AppStorage(SettingsKeys.dialFrequencyMHz) private var dialFrequencyMHz = 14.074
    @AppStorage(SettingsKeys.digiMode) private var digiMode = DigiMode.ft8.rawValue

    var body: some View {
        Menu {
            // Receive-only: every preset is fair game; the radio dial is
            // set by hand and this just tells the decoder what to expect
            ForEach(QSYPreset.all) { preset in
                Button {
                    dialFrequencyMHz = preset.mhz
                    digiMode = preset.mode.rawValue
                    if controller.isRunning {
                        controller.stop()
                        controller.start()
                    }
                } label: {
                    // Title + subtitle rows — the mac label's "10m FT8 —
                    // 28.074" em-dash line wraps at iOS menu width
                    Text(preset.label.components(separatedBy: " — ").first ?? preset.label)
                    Text(String(format: "%.4f MHz", preset.mhz))
                }
            }
        } label: {
            Text("\(String(format: "%.4f", dialFrequencyMHz)) · \(digiMode)")
                .font(.callout.monospacedDigit())
                .padding(.horizontal, 12)
                .frame(height: 48)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
    }
}
