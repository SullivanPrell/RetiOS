import SwiftUI
import SwiftData

/// New conversation sheet — pick a contact / recent peer, or enter a peer
/// destination hash manually, then write the first message.
struct ComposeView: View {
    @EnvironmentObject var stack: StackController
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var peerHashInput = ""
    @State private var messageText = ""
    @State private var errorMessage: String?
    @FocusState private var hashFocused: Bool
    @Query(sort: \PeerEntity.lastSeen, order: .reverse) private var peers: [PeerEntity]

    private var hashValid: Bool {
        let hex = peerHashInput.filter { $0.isHexDigit }
        return hex.count == 32
    }

    /// Contacts first (alphabetical), then the most recently seen peers —
    /// so most sends are a tap instead of pasting a 32-char hash.
    private var suggestedPeers: [PeerEntity] {
        let contacts = peers.filter { $0.isContact }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        let recent = Array(peers.filter { !$0.isContact }.prefix(10))
        return contacts + recent
    }

    /// Display name for the currently entered hash, if it matches a known peer.
    private var selectedPeerName: String? {
        guard hashValid else { return nil }
        return peers.first { $0.destinationHash == peerHashInput }?.displayName
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Recipient") {
                    TextField("Destination hash (32 hex chars)", text: $peerHashInput)
                        .rnsHashFieldStyle()
                        .focused($hashFocused)
                        .onChange(of: peerHashInput) { _, new in
                            // Lowercase so a typed/pasted uppercase hash still
                            // matches stored (lowercase) peer hashes — otherwise
                            // `selectedPeerName` and the row checkmark silently fail.
                            peerHashInput = String(new.filter { $0.isHexDigit }.prefix(32)).lowercased()
                        }
                    if let name = selectedPeerName {
                        Label(name, systemImage: "person.crop.circle.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(Color.rnsAccent)
                    }
                    if !peerHashInput.isEmpty && !hashValid {
                        Text("Must be a 32-character hex string (16 bytes).")
                            .font(.caption)
                            .foregroundStyle(Color.rnsError)
                    }
                }

                if !suggestedPeers.isEmpty {
                    Section("Contacts & recent peers") {
                        ForEach(suggestedPeers) { peer in
                            Button {
                                peerHashInput = peer.destinationHash
                                hashFocused = false
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(peer.label)
                                            .foregroundStyle(.primary)
                                        Text(peer.destinationHash.truncatedHash)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if peer.destinationHash == peerHashInput {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.rnsAccent)
                                    } else if peer.isContact {
                                        Image(systemName: "person.crop.circle.badge.checkmark")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Message") {
                    TextField("Type your message…", text: $messageText, axis: .vertical)
                        .lineLimit(3...8)
                }

                if let err = errorMessage {
                    Section {
                        Text(err).foregroundStyle(Color.rnsError).font(.caption)
                    }
                }
            }
            .navigationTitle("New Message")
            .rnsInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .disabled(!hashValid || messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            // Focus the hash field only when there's nothing to tap instead.
            .onAppear { if suggestedPeers.isEmpty { hashFocused = true } }
        }
    }

    private func send() {
        let hex = String(peerHashInput.filter { $0.isHexDigit }.prefix(32))
        guard let peerData = Data(hexString: hex) else { return }
        do {
            try stack.send(content: messageText.trimmingCharacters(in: .whitespacesAndNewlines),
                           to: peerData, context: context)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

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
