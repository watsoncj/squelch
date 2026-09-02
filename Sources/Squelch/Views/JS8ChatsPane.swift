import SwiftUI

/// The direct-message view of JS8: conversations on top, a thread with a
/// docked composer when one is selected. Lives in the sidebar as the
/// Chats tab (JS8 mode only).
struct JS8ChatsPane: View {
    @ObservedObject var store: JS8MessageStore
    @ObservedObject var js8: JS8Session
    let myCall: String
    let txAvailable: Bool
    let decoding: Bool
    /// Send `text` addressed to `partner` (builder prepends the address).
    let onSend: (String, String) -> Bool
    /// No joined groups: widen to every conversation on the band, the
    /// observed ones (station · station) read-only.
    let includeObserved: Bool

    @State private var selectedPartner: String?
    @State private var draft = ""

    var body: some View {
        if let partner = selectedPartner {
            threadView(partner)
        } else {
            conversationList
        }
    }

    // MARK: Conversations

    private var conversationList: some View {
        List(store.conversations(includeObserved: includeObserved)) { convo in
            Button {
                selectedPartner = convo.partner
                store.markRead(partner: convo.partner)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: convo.partner.hasPrefix("@") ? "person.3"
                          : JS8MessageStore.isObservedPartner(convo.partner) ? "ear" : "person")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(convo.partner)
                            .font(.body.monospaced().bold())
                        Text((convo.last.outgoing ? "you: " : "") + convo.last.bubbleText)
                            .font(.callout)
                            .foregroundStyle(.primary.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(relativeAgeText(for: convo.last.timestamp, now: Date()))
                            .font(.caption)
                            .foregroundStyle(.primary.opacity(0.6))
                        if convo.unread > 0 {
                            Text("\(convo.unread)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if store.conversations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.largeTitle)
                        .foregroundStyle(.primary.opacity(0.4))
                    Text("No conversations yet")
                        .font(.headline)
                    Text(includeObserved
                         ? "Conversations decode here as the band produces them — including ones between other stations. Message someone from a feed row, or send a CQ."
                         : "Messages addressed to \(myCall.isEmpty ? "you" : myCall) or a joined group thread here. Answer a CQ from the feed, or join a group like @R8AUXCOM from a row's context menu.")
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
        }
    }

    // MARK: Thread

    private func threadView(_ partner: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    selectedPartner = nil
                } label: {
                    Label("Chats", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
                Text(partner)
                    .font(.body.monospaced().bold())
                Spacer()
                Menu {
                    Button("Query SNR") { _ = onSend("\(partner) SNR?", partner) }
                    Button("How copy?") { _ = onSend("\(partner) HW CPY?", partner) }
                    Button("Check for messages") { _ = onSend("\(partner) QUERY MSGS", partner) }
                    if let id = offeredMessageID(partner) {
                        Button("Retrieve message \(id)") { _ = onSend("\(partner) QUERY MSG \(id)", partner) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                .disabled(!canTransmit)
                .opacity(observedThread ? 0 : 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(store.thread(with: partner)) { msg in
                            bubble(msg)
                                .id(msg.id)
                        }
                    }
                    .padding(10)
                }
                .onAppear {
                    if let last = store.thread(with: partner).last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: store.messages.count) { _, _ in
                    if let last = store.thread(with: partner).last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        store.markRead(partner: partner)
                    }
                }
            }

            Divider()

            HStack(spacing: 6) {
                TextField(observedThread ? "Observed conversation — read-only"
                          : (canTransmit ? "Message \(partner)…" : "Start decoding to send"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                    .disabled(!canTransmit)
                if js8.isSending {
                    ProgressView()
                        .controlSize(.small)
                        .help("Sending — one frame per slot")
                } else {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .disabled(!canSend)
                }
            }
            .padding(8)
        }
    }

    private func bubble(_ msg: JS8ChatMessage) -> some View {
        VStack(alignment: msg.outgoing ? .trailing : .leading, spacing: 1) {
            Text(msg.bubbleText)
                .font(.callout.monospaced())
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    msg.outgoing ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 9)
                )
            Text(bubbleMeta(msg))
                .font(.caption2)
                .foregroundStyle(.primary.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: msg.outgoing ? .trailing : .leading)
    }

    private func bubbleMeta(_ msg: JS8ChatMessage) -> String {
        var parts: [String] = []
        if msg.to.hasPrefix("@") || (!msg.outgoing && msg.from != selectedPartner) {
            parts.append(msg.outgoing ? "you" : msg.from)
        }
        parts.append(TimeDisplay.current(UserDefaults.standard.string(forKey: SettingsKeys.timeDisplay) ?? "").logTimestamp(for: msg.timestamp))
        if !msg.outgoing { parts.append(String(format: "%+.0f dB", msg.snr)) }
        return parts.joined(separator: " · ")
    }

    /// A "MSG ID <n>" offer in the thread's recent incoming traffic —
    /// the station is holding mail for us.
    private func offeredMessageID(_ partner: String) -> Int? {
        for msg in store.thread(with: partner).suffix(6).reversed() where !msg.outgoing {
            if let range = msg.text.range(of: "MSG ID ([0-9]+)", options: .regularExpression) {
                return Int(msg.text[range].dropFirst(7))
            }
        }
        return nil
    }

    private var observedThread: Bool {
        selectedPartner.map(JS8MessageStore.isObservedPartner) ?? false
    }

    private var canTransmit: Bool { txAvailable && decoding && !observedThread }
    private var canSend: Bool {
        canTransmit && !js8.isSending && !draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func send() {
        guard canSend, let partner = selectedPartner else { return }
        if onSend(draft, partner) {
            draft = ""
        }
    }
}
