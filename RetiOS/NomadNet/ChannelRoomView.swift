import SwiftUI
import SwiftData
import NomadNet

// MARK: - ChannelRoomView

struct ChannelRoomView: View {
    let channelHash: String
    let channelName: String
    let destName: String

    @EnvironmentObject var nomadNet: NomadNetController
    @Environment(\.modelContext) private var modelContext

    @Query private var messages: [ChannelMessageEntity]

    /// The room we're composing into — set from the join-room prompt.
    @State private var activeRoom: String? = nil
    @State private var roomInput   = "general"
    @State private var composeDraft = ""
    @State private var sendError: String?
    @State private var showRoomPicker = false
    @FocusState private var composeFocused: Bool

    init(channelHash: String, channelName: String, destName: String = RRC.defaultDestName) {
        self.channelHash = channelHash
        self.channelName = channelName
        self.destName    = destName
        let hash = channelHash
        _messages = Query(
            filter: #Predicate<ChannelMessageEntity> { $0.channelHash == hash },
            sort: [SortDescriptor(\ChannelMessageEntity.timestamp, order: .forward)]
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            if let room = activeRoom {
                composeBar(room: room)
            } else {
                joinRoomPrompt
            }
        }
        .rnsCanvasBackground()
        .navigationTitle(channelName)
        .rnsInlineNavigationTitle()
        .toolbar { connectionBadge }
        .alert("Send Error", isPresented: Binding(
            get: { sendError != nil },
            set: { if !$0 { sendError = nil } }
        )) {
            Button("OK", role: .cancel) { sendError = nil }
        } message: {
            Text(sendError ?? "")
        }
        .onAppear {
            clearUnread()
            ensureConnected()
            // If the hub already has joined rooms, pick the first.
            if let hub = activeHub, let r = hub.rooms.sorted().first {
                activeRoom = r
                roomInput  = r
            }
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(messages) { msg in
                            ChannelMessageBubble(message: msg)
                                .id(msg.messageID)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.messageID, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = messages.last {
                    proxy.scrollTo(last.messageID, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No messages yet")
                .foregroundStyle(.secondary)
            if activeHub?.status == .connecting {
                Text("Connecting to hub…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Join-room prompt

    private var joinRoomPrompt: some View {
        HStack(spacing: 8) {
            Image(systemName: "number")
                .foregroundStyle(.secondary)
            TextField("Room name", text: $roomInput)
                .autocorrectionDisabled()
                .rnsNoAutocapitalization()
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                // Single-line field: Return joins (matches the native submit
                // convention on both platforms). joinRoom() already no-ops on empty.
                .onSubmit { joinRoom() }
                #if os(iOS)
                .submitLabel(.join)
                #endif
            Button("Join") { joinRoom() }
                .buttonStyle(.borderedProminent)
                .tint(.rnsAccent)
                .disabled(roomInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.rnsSurface)
    }

    // MARK: - Compose bar

    @ViewBuilder
    private func composeBar(room: String) -> some View {
        HStack(spacing: 8) {
            Button {
                showRoomPicker = true
            } label: {
                Label("#\(room)", systemImage: "number")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

            TextField("Message", text: $composeDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($composeFocused)

            Button(action: { sendMessage(room: room) }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(composeDraft.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? Color.secondary : Color.rnsAccent)
            }
            // Ensure the 44x44pt minimum hit region around the 28pt glyph.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .disabled(composeDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.rnsSurface)
        .confirmationDialog("Switch Room", isPresented: $showRoomPicker) {
            if let hub = activeHub {
                ForEach(hub.rooms.sorted(), id: \.self) { r in
                    Button("#\(r)") { activeRoom = r }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Toolbar connection badge

    @ToolbarContentBuilder
    private var connectionBadge: some ToolbarContent {
        ToolbarItem(placement: .rnsTrailing) {
            if let hub = activeHub {
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor(hub.status))
                        .frame(width: 7, height: 7)
                    Text(hub.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusColor(_ status: RRCHub.Status) -> Color {
        switch status {
        case .connected:    return .rnsSuccess
        case .connecting:   return .rnsWarning
        case .disconnected: return .secondary
        case .failed:       return .rnsError
        }
    }

    // MARK: - Actions

    private var activeHub: RRCHub? {
        guard let manager = nomadNet.rrcManager,
              let hashData = Data(hexString: channelHash) else { return nil }
        return manager.findHub(hash: hashData, destName: destName)
    }

    private func ensureConnected() {
        guard let hub = activeHub else { return }
        if hub.status == .disconnected || hub.status == .failed {
            hub.connect()
        }
    }

    private func joinRoom() {
        let room = roomInput.trimmingCharacters(in: .whitespaces)
        guard !room.isEmpty, let hub = activeHub else { return }
        do {
            try hub.joinRoom(room)
            activeRoom = room.lowercased()
        } catch {
            sendError = error.localizedDescription
        }
    }

    private func sendMessage(room: String) {
        let text = composeDraft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let hub = activeHub else { return }
        do {
            try hub.sendMessage(room: room, text: text)
            composeDraft = ""
        } catch {
            sendError = error.localizedDescription
        }
    }

    private func clearUnread() {
        let desc = FetchDescriptor<ChannelEntity>(
            predicate: #Predicate { $0.channelHash == channelHash }
        )
        if let channel = (try? modelContext.fetch(desc))?.first {
            channel.unreadCount = 0
            try? modelContext.save()
        }
    }
}

// MARK: - ChannelMessageBubble

private struct ChannelMessageBubble: View {
    let message: ChannelMessageEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(message.displaySender)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.rnsAccent)
                if let room = message.room, !room.isEmpty {
                    Text("#\(room)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(message.content)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Hex helper

private extension Data {
    init?(hexString: String) {
        let hex = hexString.filter { $0.isHexDigit }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        self = data
    }
}
