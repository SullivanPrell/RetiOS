import SwiftUI
import SwiftData

struct DestinationsView: View {
    @EnvironmentObject var stack: StackController
    @EnvironmentObject var calls: CallsController
    @Environment(\.modelContext) private var context
    @Query(sort: \PeerEntity.lastSeen, order: .reverse) private var peers: [PeerEntity]
    @State private var searchText = ""
    @State private var lxstError: String?
    @State private var peerPendingDeletion: PeerEntity?

    private var filtered: [PeerEntity] {
        guard !searchText.isEmpty else { return peers }
        let q = searchText.lowercased()
        return peers.filter {
            ($0.displayName?.lowercased().contains(q) ?? false) ||
            $0.destinationHash.contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if peers.isEmpty {
                    peersEmptyState
                } else {
                    List(filtered) { peer in
                        NavigationLink(destination: MessageThreadView(peerHash: peer.destinationHash)) {
                            PeerRow(peer: peer)
                        }
                        // allowsFullSwipe:false so an over-swipe can't auto-start
                        // a call — the user must tap the revealed Call button.
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                if let hashData = Data(hexString: peer.destinationHash) {
                                    if calls.hasLXSTCallPath(for: hashData) {
                                        calls.startCall(to: hashData)
                                    } else {
                                        lxstError = "\(peer.label) has not announced their LXST call destination. Ask them to enable LXST on their Reticulum node so it can advertise its call address."
                                    }
                                }
                            } label: {
                                Label("Call", systemImage: "phone.fill")
                            }
                            .tint(Color.rnsSuccess)
                        }
                        // allowsFullSwipe:false + a confirmation: removing a peer
                        // is destructive (drops any nickname/contact status), so
                        // it shouldn't happen on an accidental full swipe.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                peerPendingDeletion = peer
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        .rnsRow()
                    }
                    .rnsScreenBackground()
                    .searchable(text: $searchText, prompt: "Name or hash")
                    // Standard no-results state instead of a blank list when the
                    // query matches no peer.
                    .overlay {
                        if filtered.isEmpty && !searchText.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                        }
                    }
                }
            }
            .navigationTitle("Peers")
            .rnsInlineNavigationTitle()
            .rnsNavigationBar()
            .alert(
                "Cannot Start Call",
                isPresented: Binding(
                    get: { lxstError != nil },
                    set: { if !$0 { lxstError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { lxstError = nil }
            } message: {
                Text(lxstError ?? "")
            }
            .confirmationDialog(
                "Remove Peer",
                isPresented: Binding(
                    get: { peerPendingDeletion != nil },
                    set: { if !$0 { peerPendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: peerPendingDeletion
            ) { peer in
                Button("Remove Peer", role: .destructive) {
                    context.delete(peer)
                    try? context.save()
                    peerPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { peerPendingDeletion = nil }
            } message: { peer in
                Text("“\(peer.label)” will be removed along with any nickname you set. They'll reappear if they announce again.")
            }
        }
    }

    private var peersEmptyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                    .padding(.top, 56)
                Text("No Peers Yet")
                    .font(.title2.bold())
                Text("Peers appear automatically as their LXMF announcements arrive across the mesh. Make sure the stack is running and at least one interface is active.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity)
        }
        .rnsCanvasBackground()
    }
}

// MARK: - Row

private struct PeerRow: View {
    let peer: PeerEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Name as primary label — fall back to "Unknown Peer" so the hash
            // is not shown twice when no display name has been received.
            Text(peer.displayName ?? "Unknown Peer")
                .font(.headline)
            Text(peer.destinationHash.truncatedHash)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            (Text(peer.lastSeen, style: .relative) + Text(" ago"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
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
