import SwiftUI
import AppKit

/// The single TX/session status surface — a compact chip that lives in the
/// toolbar, left of the frequency selector. Priority: transmitting (red,
/// Halt) → armed auto-answer (orange, Cancel) → active sequencer session
/// (blue/green, Stop) → armed WSPR beacon → TX error (dismissable) →
/// TX notice (dismissable, informational).
struct QSOStatusPanel: View {
    @ObservedObject var sequencer: QSOSequencer
    @ObservedObject var transmit: TransmitController
    @ObservedObject var model: AppModel
    @ObservedObject var controller: DecodeController
    @AppStorage(SettingsKeys.digiMode) private var digiMode = DigiMode.ft8.rawValue
    @AppStorage(SettingsKeys.huntEnabled) private var huntEnabled = false
    @AppStorage(SettingsKeys.huntDX) private var huntDX = false
    @AppStorage(SettingsKeys.huntNewStates) private var huntNewStates = false
    @AppStorage(SettingsKeys.huntNewCountries) private var huntNewCountries = false

    private var period: Double {
        (DigiMode(rawValue: digiMode) ?? .ft8).slotSeconds
    }

    var body: some View {
        if transmit.anyTXActive {
            transmittingChip
        } else if let pending = model.pendingReply {
            pendingChip(pending)
        } else if sequencer.mode != .idle {
            sessionChip
        } else if model.wsprBeaconEnabled {
            beaconChip
        } else if let error = transmit.txError {
            errorChip(error)
        } else if let notice = transmit.txNotice {
            noticeChip(notice)
        } else if controller.micDenied {
            micDeniedChip
        } else if let error = controller.startError {
            startErrorChip(error)
        } else if controller.isRunning, controller.inputSilent {
            silentInputChip
        } else if controller.isRunning, controller.inputClipping {
            clippingChip
        } else if controller.isRunning, let span = controller.narrowFilterSpan {
            narrowFilterChip(span)
        } else if controller.isRunning, controller.wsprAudioSuspect {
            mangledAudioChip
        } else if controller.isRunning, huntEnabled, DigiMode.current.supportsQSO {
            huntingChip
        } else if controller.isRunning {
            decodingChip
        }
    }

    /// The new-station sharp edge: mic permission denied fails silently
    /// otherwise (dead meter, zero decodes, no explanation).
    private var micDeniedChip: some View {
        chip(tint: .red) {
            Image(systemName: "mic.slash.fill")
                .foregroundStyle(.red)
            Text("Microphone access denied")
                .font(.callout)
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .help("macOS is blocking Squelch's audio input. Enable Squelch under Microphone, then press Start again.")
    }

    private func startErrorChip(_ error: String) -> some View {
        chip(tint: .orange) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 280)
                .help(error)
            Button {
                controller.startError = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
        }
    }

    /// Decoding but the input has been dead quiet — indistinguishable from
    /// a closed band without this.
    private var silentInputChip: some View {
        chip(tint: .orange) {
            Image(systemName: "waveform.slash")
                .foregroundStyle(.orange)
            Text("No audio from \(controller.deviceName)")
                .font(.callout)
        }
        .help("Decoding is running but the input is silent. Check the Digirig USB connection, the input device in Settings → Audio Input, and the radio's volume — the level meter should move with band noise.")
    }

    /// The input is overdriving — distortion kills weak-signal decodes.
    private var clippingChip: some View {
        chip(tint: .orange) {
            Image(systemName: "waveform.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("Audio input clipping")
                .font(.callout)
        }
        .help("The input is hitting full scale. Lower the radio's AF/USB output level (or the interface gain) until the meter stays out of the top — clipped audio distorts and weak signals stop decoding.")
    }

    /// Decodes bunched into a thin audio slice: the radio's IF width is
    /// eating the rest of the passband.
    private func narrowFilterChip(_ span: (lo: Int, hi: Int)) -> some View {
        chip(tint: .orange) {
            Image(systemName: "waveform.path.badge.minus")
                .foregroundStyle(.orange)
            Text("RX filter looks narrow")
                .font(.callout)
        }
        .help("Decodes are only arriving between about \(span.lo) and \(span.hi) Hz — the rest of the passband is silent. Check the radio's IF WIDTH / narrow-filter setting for its data mode and widen it to ~3000 Hz (watch for a NAR indicator). Signals outside a narrow filter vanish without a trace.")
    }

    /// WSPR-shaped signals keep arriving but never decode — almost always
    /// the radio's DSP chewing the audio (any brand: NR/DNR, auto-notch/DNF,
    /// contour, RX EQ), occasionally a badly off-frequency dial.
    private var mangledAudioChip: some View {
        chip(tint: .orange) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .foregroundStyle(.orange)
            Text("Signals heard, none decode")
                .font(.callout)
        }
        .help("WSPR-like signals are reaching the decoder but nothing decodes. Turn OFF the radio's noise reduction, auto-notch, contour, and receive EQ for data modes — they silently destroy weak digital signals. Also confirm the dial matches the WSPR frequency exactly.")
    }

    /// Hunt mode armed and scanning — the decode ring wears binoculars so
    /// the auto-TX standing order is always visible.
    private var huntingChip: some View {
        chip(tint: .green) {
            Image(systemName: "binoculars.fill")
                .foregroundStyle(.green)
            Text("Hunting CQs")
                .font(.callout)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let fraction = context.date.timeIntervalSince1970
                    .truncatingRemainder(dividingBy: period) / period
                SlotRing(fraction: fraction, tint: .green)
            }
        }
        .help("Watching for \(huntCriteriaText) — a matching CQ arms a reply with a countdown you can cancel")
    }

    private var huntCriteriaText: String {
        var parts: [String] = []
        if huntDX { parts.append("DX") }
        if huntNewStates { parts.append("new states") }
        if huntNewCountries { parts.append("new countries") }
        return parts.isEmpty ? "nothing (pick criteria under Hunt)" : parts.joined(separator: ", ")
    }

    /// Lowest priority: a radial ring filling over the decode slot.
    /// Deliberately minimal — input level lives in Settings › Audio Input.
    private var decodingChip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let fraction = context.date.timeIntervalSince1970
                .truncatingRemainder(dividingBy: period) / period
            SlotRing(fraction: fraction)
        }
        .frame(height: 26)
        .help("Decoding — the ring fills over the \(digiMode) slot")
    }

    // MARK: - States

    private var transmittingChip: some View {
        chip(tint: .red, prominent: true) {
            // Static icon on purpose: a repeating symbolEffect inside the
            // toolbar re-commits the whole window every frame (main thread
            // spent 44% blocked in CA commit waits — sluggish scrolling)
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.red)
            txStatusText
            // Progress through the slot window (2 min for a WSPR beacon,
            // 15 s for FT8) — red to match the TX state
            if !transmit.isTuning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let fraction = context.date.timeIntervalSince1970
                        .truncatingRemainder(dividingBy: period) / period
                    SlotRing(fraction: fraction, tint: .red)
                }
            }
            // Plain bordered: a prominent red tint here bleeds across the
            // whole toolbar glass container and drowns the text
            Button("Halt") {
                model.haltTX()
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.bordered)
            .foregroundStyle(.red)
            .controlSize(.small)
        }
        .help(sequencer.mode != .idle ? sequencer.stateDescription : "Transmitting — Halt with Space")
    }

    private func pendingChip(_ pending: PendingReply) -> some View {
        let hunted: CQHunter.Reason? = {
            if case .huntedCQ(let reason) = pending.kind { return reason }
            return nil
        }()
        return chip(tint: .orange) {
            Image(systemName: hunted == nil ? "phone.arrow.down.left.fill" : "binoculars.fill")
                .foregroundStyle(.orange)
            HStack(spacing: 4) {
                if let hunted {
                    Text("\(hunted.label) · calling")
                    callsignButton(pending.call)
                    Text("in")
                } else {
                    callsignButton(pending.call)
                    Text("calling · answering in")
                }
            }
            .font(.callout)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, pending.fireAt.timeIntervalSince(context.date).rounded(.up))
                counterText(Int(remaining))
                    .font(.callout)
            }
            Button("Cancel") {
                model.cancelPendingReply()
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var sessionChip: some View {
        chip(tint: sequencer.mode == .cqLoop ? .blue : .green) {
            Image(systemName: sequencer.mode == .cqLoop ? "megaphone.fill" : "person.line.dotted.person.fill")
                .foregroundStyle(sequencer.mode == .cqLoop ? .blue : .green)
            if sequencer.mode != .cqLoop, let partner = sequencer.currentPartner {
                HStack(spacing: 4) {
                    Text("QSO with")
                    callsignButton(partner)
                }
                .font(.callout.weight(.semibold))
            } else {
                Text(title)
                    .font(.callout.weight(.semibold))
            }
            nextTXCountdown
            Button("Stop") {
                model.haltTX()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .help(sequencer.stateDescription)
    }

    private var beaconChip: some View {
        chip(tint: model.beaconNextWindowWillTX ? .orange : .blue) {
            Image(systemName: "dot.radiowaves.up.forward")
                .foregroundStyle(model.beaconNextWindowWillTX ? .orange : .blue)
            Text(model.beaconNextWindowWillTX ? "Beacon: TX next window" : "Beacon armed")
                .font(.callout)
            // Radial fills over the 2-minute WSPR window, like the
            // decode chip's slot ring
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let period = DigiMode.wspr.slotSeconds
                let fraction = context.date.timeIntervalSince1970
                    .truncatingRemainder(dividingBy: period) / period
                SlotRing(fraction: fraction,
                         tint: model.beaconNextWindowWillTX ? .orange : .blue)
            }
            if !model.beaconNextWindowWillTX {
                Button("TX next") {
                    model.forceBeaconNextWindow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button("Stop") {
                model.setWSPRBeacon(false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .help("WSPR beacon — duty cycle in Settings")
    }

    private func errorChip(_ error: String) -> some View {
        chip(tint: .orange) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 280)
                .help(error)
            Button {
                transmit.txError = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
        }
    }

    /// Informational, non-blocking — TX went ahead (e.g. the output device
    /// was healed after a USB port change).
    private func noticeChip(_ notice: String) -> some View {
        chip(tint: .blue) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
            Text(notice)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 280)
                .help(notice)
            Button {
                transmit.txNotice = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Pieces

    private var title: String {
        switch sequencer.mode {
        case .cqLoop: return "Calling \(sequencer.cqLabel)"
        case .qsoAsCaller, .qsoAsAnswerer: return "QSO with \(sequencer.currentPartner ?? "…")"
        case .idle: return ""
        }
    }

    private var nextTXCountdown: some View {
        HStack(spacing: 3) {
            Text("TX in")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let next = QSOSequencer.nextTXWindow(
                    parity: sequencer.txParity,
                    period: period,
                    after: context.date,
                    minLead: 0
                )
                let remaining = next.timeIntervalSince(context.date)
                Text(String(format: "%.0f s", remaining.rounded(.up)))
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Content only — the toolbar's native glass container provides the
    /// chrome; drawing our own background/border doubled it up.
    private func chip<Content: View>(tint: Color, prominent: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .frame(height: 26) // constant across states: no vertical breathing
    }

    /// The red chip's message text, with the addressee (the station we're
    /// transmitting TO) clickable like the other chips' callsigns. CQs and
    /// TUNING have no addressee and render as plain text.
    private var txStatusText: some View {
        let text = transmit.isTuning
            ? "TUNING"
            : (transmit.currentTXText.isEmpty ? "TRANSMITTING" : transmit.currentTXText)
        let addressee = transmit.isTuning
            ? nil
            : FT8MessageParser.parse(transmit.currentTXText).addressee
        return HStack(spacing: 0) {
            if let addressee, text.hasPrefix(addressee + " ") {
                Button(addressee) {
                    model.focusMostRecent(callsign: addressee)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Select \(addressee)'s latest decode in the list")
                Text(text.dropFirst(addressee.count))
            } else {
                Text(text)
            }
        }
        .font(.callout.weight(.semibold).monospaced())
        // Min width so successive TX messages of similar length
        // ("K5XL W0CJW -17" vs "CQ W0CJW DM79") don't jitter
        .frame(minWidth: 160, alignment: .leading)
    }

    /// A chip callsign that selects and reveals that station's most
    /// recent decode in the sidebar list. The link pointer is the
    /// clickable-affordance; the surrounding text stays inert.
    private func callsignButton(_ call: String) -> some View {
        Button(call) {
            model.focusMostRecent(callsign: call)
        }
        .buttonStyle(.plain)
        .fontWeight(.semibold)
        .pointerStyle(.link)
        .help("Select \(call)'s latest decode in the list")
    }

    /// Fixed-width seconds counter so ticking never changes the chip width.
    private func counterText(_ seconds: Int) -> some View {
        Text("\(seconds) s")
            .monospacedDigit()
            .frame(width: 42, alignment: .trailing)
    }
}
