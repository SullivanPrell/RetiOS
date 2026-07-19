import SwiftUI
import SwiftData

// MARK: - Messages container

/// Top-level Messages tab — segmented into Conversations and LXMF Peers.
struct ConversationsView: View {
    @EnvironmentObject var stack: StackController
    @EnvironmentObject var notifs: NotificationManager
    @Environment(\.modelContext) private var context
    @State private var section: MessagesSection = .conversations
    @State private var showCompose = false
    @State private var showAddContact = false
    /// NavigationPath drives both user taps (via NavigationLink(value:)) and
    /// programmatic deep links from notification taps.
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            VStack(spacing: 0) {
                RNSSectionPicker([
                    ("Messages", MessagesSection.conversations),
                    ("Contacts", MessagesSection.contacts),
                    ("Peers",    MessagesSection.peers)
                ], selection: $section)

                Group {
                    switch section {
                    case .conversations:
                        ConversationListContent()
                    case .contacts:
                        ContactsContent()
                    case .peers:
                        LXMFPeersContent()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // ConversationListContent, ContactsContent and LXMFPeersContent all push
            // String (peerHash) values; this single destination handles navigation for all.
            .navigationDestination(for: String.self) { hash in
                MessageThreadView(peerHash: hash)
            }
            .navigationTitle("Messages")
            .rnsNavigationBar()
            .toolbar {
                ToolbarItem(placement: .rnsTrailing) {
                    if section == .contacts {
                        Button { showAddContact = true } label: {
                            Image(systemName: "person.badge.plus")
                        }
                        .accessibilityLabel("Add Contact")
                    } else {
                        Button { showCompose = true } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("New Message")
                    }
                }
            }
            .sheet(isPresented: $showCompose) {
                ComposeView()
                    .environmentObject(stack)
                    .environment(\.modelContext, context)
            }
            .sheet(isPresented: $showAddContact) {
                AddContactSheet()
                    .environment(\.modelContext, context)
            }
            // Deep link from notification tap: switch to conversations section
            // and push directly to the relevant thread.
            .onChange(of: notifs.openConversationHash) { _, hash in
                guard let hash else { return }
                section = .conversations
                navPath.append(hash)
                notifs.openConversationHash = nil
            }
            // Menu-bar "File ▸ New Message" (⌘N).
            .onChange(of: notifs.requestCompose) { _, _ in showCompose = true }
            // Menu-bar "File ▸ New Contact" (⌃⌘N) — switch to the Contacts
            // section and open the add-by-hash sheet.
            .onChange(of: notifs.requestAddContact) { _, _ in
                section = .contacts
                showAddContact = true
            }
        }
    }
}

private enum MessagesSection: Hashable { case conversations, contacts, peers }

// MARK: - Conversation list

/// Deduplicated list of conversations (latest message per peer), sorted newest-first.
///
/// Performance note: this view queries ALL messages once and deduplicates in Swift,
/// rather than using per-row @Query (which would spawn N live database subscriptions
/// for N conversations — causing mass re-renders on every announce flush).
private struct ConversationListContent: View {
    @EnvironmentObject var stack: StackController
    @Environment(\.modelContext) private var context
    @Query(sort: \MessageEntity.timestamp, order: .reverse) private var messages: [MessageEntity]
    @Query private var peers: [PeerEntity]

    /// One entry per peer hash, latest message each, plus its unread count.
    private var conversations: [(peerHash: String, displayName: String?, latest: MessageEntity, unread: Int)] {
        var seen: [String: MessageEntity] = [:]
        var unread: [String: Int] = [:]
        for msg in messages {
            if seen[msg.conversationHash] == nil { seen[msg.conversationHash] = msg }
            if !msg.isRead { unread[msg.conversationHash, default: 0] += 1 }
        }
        // Build a name lookup once per render (not per row).
        let nameByHash = Dictionary(uniqueKeysWithValues: peers.compactMap { p -> (String, String)? in
            guard let name = p.displayName else { return nil }
            return (p.destinationHash, name)
        })
        return seen.values
            .sorted { $0.timestamp > $1.timestamp }
            .map { msg in
                (peerHash: msg.conversationHash,
                 displayName: nameByHash[msg.conversationHash],
                 latest: msg,
                 unread: unread[msg.conversationHash] ?? 0)
            }
    }

    var body: some View {
        if conversations.isEmpty {
            emptyState
        } else {
            List(conversations, id: \.peerHash) { item in
                NavigationLink(value: item.peerHash) {
                    ConversationRow(peerHash: item.peerHash,
                                    displayName: item.displayName,
                                    latest: item.latest,
                                    unread: item.unread)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteConversation(peerHash: item.peerHash)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                // Right-click / long-press equivalent of the swipe action —
                // the discoverable path on macOS, where swiping is hidden.
                .contextMenu {
                    Button(role: .destructive) {
                        deleteConversation(peerHash: item.peerHash)
                    } label: {
                        Label("Delete Conversation", systemImage: "trash")
                    }
                }
                .rnsRow()
            }
            .listStyle(.plain)
            .rnsScreenBackground()
        }
    }

    /// Remove every message in a conversation. The peer/contact record is
    /// deliberately kept — deleting a thread shouldn't forget the person.
    private func deleteConversation(peerHash: String) {
        let descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.conversationHash == peerHash }
        )
        (try? context.fetch(descriptor))?.forEach { context.delete($0) }
        try? context.save()
    }

    private var emptyState: some View {
        RNSEmptyState(
            title: "No Conversations",
            systemImage: "message.fill",
            description: "Send a message to a peer's destination hash to start a conversation."
        )
    }
}

// MARK: - Conversation row
// Takes pre-resolved displayName from parent to avoid per-row @Query subscriptions.

private struct ConversationRow: View {
    let peerHash: String
    let displayName: String?
    let latest: MessageEntity
    let unread: Int

    private var label: String {
        displayName ?? "<\(String(peerHash.prefix(8)))>"
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(label)
                        .font(unread > 0 ? .headline.weight(.bold) : .headline)
                    Spacer()
                    Text(latest.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(latest.content.isEmpty ? (latest.title.isEmpty ? "…" : latest.title) : latest.content)
                    .font(.subheadline)
                    .foregroundStyle(unread > 0 ? .primary : .secondary)
                    .lineLimit(1)
            }
            if unread > 0 {
                Text("\(unread)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.rnsAccent, in: Capsule())
                    .accessibilityLabel("\(unread) unread")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - LXMF Peers list

/// All known LXMF peers from announce history, sorted by last seen.
private struct LXMFPeersContent: View {
    @EnvironmentObject var stack: StackController
    @Environment(\.modelContext) private var context
    @State private var showCompose = false
    @Query(sort: \PeerEntity.lastSeen, order: .reverse) private var peers: [PeerEntity]

    var body: some View {
        if peers.isEmpty {
            RNSEmptyState(
                title: "No Peers Yet",
                systemImage: "person.2.fill",
                description: "Peers appear as their LXMF announces arrive across the mesh."
            )
        } else {
            List(peers) { peer in
                NavigationLink(value: peer.destinationHash) {
                    LXMFPeerRow(peer: peer)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        peer.isContact.toggle()
                        try? context.save()
                    } label: {
                        Label(peer.isContact ? "Remove Contact" : "Add Contact",
                              systemImage: peer.isContact ? "person.crop.circle.badge.minus" : "person.crop.circle.badge.plus")
                    }
                    .tint(peer.isContact ? Color.rnsWarning : Color.rnsAccent)
                }
                .contextMenu {
                    Button {
                        peer.isContact.toggle()
                        try? context.save()
                    } label: {
                        Label(peer.isContact ? "Remove Contact" : "Add Contact",
                              systemImage: peer.isContact ? "person.crop.circle.badge.minus" : "person.crop.circle.badge.plus")
                    }
                }
                .rnsRow()
            }
            .listStyle(.plain)
            .rnsScreenBackground()
        }
    }
}

private struct LXMFPeerRow: View {
    let peer: PeerEntity

    var body: some View {
        HStack(spacing: 10) {
            PeerIdentityView(name: peer.displayName ?? "Unknown Peer",
                             hash: peer.destinationHash,
                             lastSeen: peer.lastSeen)
            Spacer()
            if peer.isContact {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(Color.rnsAccent)
                    .accessibilityLabel("Contact")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Contacts list

/// Peers the user has explicitly saved as contacts (manually added or pinned
/// from the discovered-peers list). Distinct from the raw announce-derived
/// Peers list — contacts are a deliberate, user-curated address book.
private struct ContactsContent: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<PeerEntity> { $0.isContact == true },
           sort: \PeerEntity.displayName) private var contacts: [PeerEntity]

    var body: some View {
        if contacts.isEmpty {
            RNSEmptyState(
                title: "No Contacts",
                systemImage: "person.crop.circle.badge.plus",
                description: "Save a peer as a contact, or tap + to add one by destination hash."
            )
        } else {
            List(contacts) { contact in
                NavigationLink(value: contact.destinationHash) {
                    ContactRow(contact: contact)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        contact.isContact = false
                        try? context.save()
                    } label: {
                        Label("Remove", systemImage: "person.crop.circle.badge.minus")
                    }
                }
                // Right-click / long-press equivalent of the swipe action, so the
                // Remove action is discoverable on macOS (where swiping is hidden)
                // — matching the two sibling lists in this same Messages tab.
                .contextMenu {
                    Button(role: .destructive) {
                        contact.isContact = false
                        try? context.save()
                    } label: {
                        Label("Remove Contact", systemImage: "person.crop.circle.badge.minus")
                    }
                }
                .rnsRow()
            }
            .listStyle(.plain)
            .rnsScreenBackground()
        }
    }
}

private struct ContactRow: View {
    let contact: PeerEntity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.rnsAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(contact.label)
                    .font(.body.weight(.medium))
                Text(contact.destinationHash.truncatedHash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Add contact sheet

/// Manually save a contact by destination hash, with an optional nickname.
/// Updates the existing PeerEntity if the peer has already announced, or
/// creates a new one (which will be filled in by future announces).
struct AddContactSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var hashInput = ""
    @State private var nameInput = ""
    @FocusState private var hashFocused: Bool

    private var hashValid: Bool {
        hashInput.filter { $0.isHexDigit }.count == 32
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Destination") {
                    TextField("Destination hash (32 hex chars)", text: $hashInput)
                        .rnsHashFieldStyle()
                        .focused($hashFocused)
                        .onChange(of: hashInput) { _, new in
                            hashInput = String(new.filter { $0.isHexDigit }.prefix(32))
                        }
                    if !hashInput.isEmpty && !hashValid {
                        Text("Must be a 32-character hex string (16 bytes).")
                            .font(.caption)
                            .foregroundStyle(Color.rnsError)
                    }

                }
                .rnsRow()

                Section("Name") {
                    TextField("Nickname (optional)", text: $nameInput)
                }
                .rnsRow()
            }
            .rnsScreenBackground()
            .navigationTitle("Add Contact")
            .rnsInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!hashValid)
                }
            }
            .onAppear { hashFocused = true }
        }
    }

    private func save() {
        let hash = hashInput
        let trimmedName = nameInput.trimmingCharacters(in: .whitespaces)
        let descriptor = FetchDescriptor<PeerEntity>(predicate: #Predicate { $0.destinationHash == hash })
        if let existing = try? context.fetch(descriptor).first {
            existing.isContact = true
            if !trimmedName.isEmpty { existing.displayName = trimmedName }
        } else {
            let peer = PeerEntity(destinationHash: hash,
                                  displayName: trimmedName.isEmpty ? nil : trimmedName,
                                  isContact: true)
            context.insert(peer)
        }
        try? context.save()
        dismiss()
    }
}
