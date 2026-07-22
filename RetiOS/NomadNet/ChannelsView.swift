import SwiftUI
import SwiftData
import NomadNet

// ChannelsContent is the inner content — no NavigationStack —
// so it can be embedded in NomadNetContainerView without nesting stacks.
struct ChannelsContent: View {
    @Environment(NomadNetController.self) private var nomadNet
    @Query(sort: \ChannelEntity.lastActivity, order: .reverse)
    private var channels: [ChannelEntity]
    @State private var showJoinSheet = false
    @State private var leaveTarget: ChannelEntity?

    var body: some View {
        Group {
            if channels.isEmpty {
                emptyState
            } else {
                channelList
            }
        }
        .rnsCanvasBackground()
        .toolbar {
            ToolbarItem(placement: .rnsTrailing) {
                Button {
                    showJoinSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Join Channel")
            }
        }
        .sheet(isPresented: $showJoinSheet) {
            JoinChannelSheet()
                .environment(nomadNet)
        }
        .confirmationDialog(
            "Leave \"\(leaveTarget?.displayName ?? "channel")\"?",
            isPresented: Binding(get: { leaveTarget != nil },
                                 set: { if !$0 { leaveTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Leave", role: .destructive) {
                if let c = leaveTarget { nomadNet.leaveChannel(channelHash: c.channelHash) }
                leaveTarget = nil
            }
            Button("Cancel", role: .cancel) { leaveTarget = nil }
        } message: {
            Text("You will stop receiving messages and the history will be removed.")
        }
    }

    // MARK: - Subviews

    private var channelList: some View {
        List {
            ForEach(channels) { channel in
                NavigationLink {
                    ChannelRoomView(channelHash: channel.channelHash,
                                    channelName: channel.displayName,
                                    destName:    channel.destName)
                        .environment(nomadNet)
                } label: {
                    ChannelRowView(channel: channel)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        leaveTarget = channel
                    } label: {
                        Label("Leave", systemImage: "xmark.circle.fill")
                    }
                }
                .rnsRow()
            }
        }
        .listStyle(.plain)
        .rnsScreenBackground()
    }

    private var emptyState: some View {
        #if os(macOS)
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(Color.rnsTextMuted)
            Text("No Channels")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.rnsTextPrimary)
            Text("Tap + to join an RRC hub by hash, or browse a NomadNet node that hosts a channel.")
                .font(.callout)
                .foregroundStyle(Color.rnsTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Join a Channel") { showJoinSheet = true }
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .rnsCanvasBackground()
        #else
        ContentUnavailableView {
            Label("No Channels", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Tap + to join an RRC hub by hash, or browse a NomadNet node that hosts a channel.")
        } actions: {
            Button("Join a Channel") { showJoinSheet = true }
                .buttonStyle(.bordered)
        }
        #endif
    }
}

// Standalone view (used by iPad sidebar detail pane).
struct ChannelsView: View {
    var body: some View {
        NavigationStack {
            ChannelsContent()
                .navigationTitle("Channels")
                .rnsInlineNavigationTitle()
                .rnsNavigationBar()
        }
    }
}

// MARK: - ChannelRowView

private struct ChannelRowView: View {
    let channel: ChannelEntity

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.rnsAccent.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(Color.rnsAccent)
                    .font(.system(size: 18))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayName)
                    .font(.body.weight(.medium))
                Text(channel.shortHash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(channel.lastActivity, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if channel.unreadCount > 0 {
                    Text("\(channel.unreadCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.rnsAccent, in: Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - JoinChannelSheet

struct JoinChannelSheet: View {
    @Environment(NomadNetController.self) private var nomadNet
    @Environment(\.dismiss) private var dismiss

    @State private var hashInput   = ""
    @State private var nameInput   = ""
    @State private var destInput   = RRC.defaultDestName
    @State private var validError: String?

    private var isValid: Bool {
        hashInput.filter(\.isHexDigit).count == 32
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Hub hash (32 hex chars)", text: $hashInput)
                        .rnsHashFieldStyle()
                        .onChange(of: hashInput) { _, _ in
                            hashInput = String(hashInput.filter(\.isHexDigit).prefix(32))
                            validError = nil
                        }
                } header: {
                    Text("Hub Destination Hash")
                } footer: {
                    if let err = validError {
                        Text(err).foregroundStyle(Color.rnsError)
                    } else {
                        Text("\(hashInput.count)/32 hex characters")
                            .foregroundStyle(isValid ? Color.rnsSuccess : .secondary)
                    }
                }
                .rnsRow()

                Section("Optional") {
                    TextField("Name", text: $nameInput)
                        .autocorrectionDisabled()

                    TextField("Dest name", text: $destInput)
                        .autocorrectionDisabled()
                        .rnsNoAutocapitalization()
                        .font(.caption.monospaced())
                }
                .rnsRow()
            }
            .rnsScreenBackground()
            .navigationTitle("Join Channel")
            .rnsInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") { join() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private func join() {
        let hex = hashInput.filter(\.isHexDigit)
        guard hex.count == 32, let hashData = Data(hexString: hex) else {
            validError = "Invalid hash — must be exactly 32 hex characters."
            return
        }
        let dn   = destInput.trimmingCharacters(in: .whitespaces).isEmpty
                   ? RRC.defaultDestName
                   : destInput.trimmingCharacters(in: .whitespaces)
        let name = nameInput.trimmingCharacters(in: .whitespaces)
        nomadNet.joinChannel(hubHash: hashData,
                              destName: dn,
                              name: name.isEmpty ? nil : name)
        dismiss()
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
