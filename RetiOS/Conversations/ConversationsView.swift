import SwiftUI
import SwiftData

// MARK: - Messages container

/// Top-level Messages tab — segmented into Conversations and LXMF Peers.
struct ConversationsView: View {
    @Environment(StackController.self) private var stack
    @Environment(NotificationManager.self) private var notifs
    @Environment(\.modelContext) private var context
    @State private var section: MessagesSection = .conversations
    @State private var showCompose = false
    @State private var showAddContact = false
    /// NavigationPath drives both user taps (via NavigationLink(value:)) and
    /// programmatic deep links from notification taps.
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            // Only the section picker + list scroll below the pinned title.
            // The picker sits inline on iOS and in the window toolbar on Mac —
            // see `rnsSectionPicker`.
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
            .rnsSectionPicker([
                ("Messages", MessagesSection.conversations),
                ("Contacts", MessagesSection.contacts),
                ("Peers",    MessagesSection.peers)
            ], selection: $section)
            // Flush pinned title with the compose / add-contact action in the
            // header's trailing slot beside the title — matching the Calls tab.
            // (rnsPinnedTitle sizes/tints the action and hides the empty iOS
            // nav bar; pushed thread views set their own nav bar / back button.)
            .rnsPinnedTitle("Messages") {
                headerActionButton
            }
            // ConversationListContent, ContactsContent and LXMFPeersContent all push
            // String (peerHash) values; this single destination handles navigation for all.
            .navigationDestination(for: String.self) { hash in
                MessageThreadView(peerHash: hash)
            }
            .sheet(isPresented: $showCompose) {
                ComposeView()
                    .environment(stack)
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

    /// Compose (or add-contact, in the Contacts section) action, shown in the
    /// pinned header's trailing slot beside the "Messages" title (the Calls-tab
    /// layout). `rnsPinnedTitle` handles its sizing and accent tint.
    @ViewBuilder
    private var headerActionButton: some View {
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

private enum MessagesSection: Hashable { case conversations, contacts, peers }

// Search on all three segments uses `rnsInlineSearch`, NOT `.searchable` — this
// is a tab root under `rnsPinnedTitle`, which hides the navigation bar the iOS
// search field would have to live in. See `rnsInlineSearch` for the full
// diagnosis; it fails silently, so it is worth knowing before "fixing" it back.

// MARK: - Conversation list

/// One row's worth of conversation state, fully resolved off the model objects.
///
/// A value type on purpose: it makes rows `Equatable`, so SwiftUI can skip
/// re-rendering rows that didn't change, and it keeps `@Model` references out of
/// the row views (reading a model property inside a row body would re-subscribe
/// that row to the object).
private struct ConversationSummary: Identifiable, Equatable {
    let peerHash: String
    let preview: String
    let timestamp: Date
    let unread: Int
    var id: String { peerHash }
}

/// Deduplicated list of conversations (latest message per peer), sorted newest-first.
///
/// Performance note: this view queries ALL messages once and deduplicates in Swift,
/// rather than using per-row @Query (which would spawn N live database subscriptions
/// for N conversations — causing mass re-renders on every announce flush).
///
/// It deliberately does **not** query `PeerEntity` — that lives one level down in
/// `ConversationList`, so the name lookup and the message scan sit in separate
/// views with separate inputs.
///
/// Be aware of what this did **not** achieve: `Self._printChanges()` still
/// attributes a re-render of *this* view to `QueryController<PeerEntity>` under
/// announce traffic, even though it declares no such query. `@Query`
/// invalidation is evidently broader than per-view, and SwiftData publishes no
/// documentation of its scope, so the mechanism is unexplained. The split was
/// kept because value-typed `Equatable` summary rows are worth having on their
/// own — not because it stops the grouping below from re-running.
///
/// Measured cost of that spurious re-run today: below the noise floor (p95 main-
/// thread delay stays at 0.1 ms under a 40-peer announce storm). It is a
/// scalability concern for very large message tables, not a current lag source.
private struct ConversationListContent: View {
    @Query(sort: \MessageEntity.timestamp, order: .reverse) private var messages: [MessageEntity]

    var body: some View {
        ConversationList(summaries: summarize())
    }

    /// One entry per peer hash: latest message, unread count. O(messages), run
    /// only when the message table itself changes.
    private func summarize() -> [ConversationSummary] {
        var latest: [String: MessageEntity] = [:]
        var unread: [String: Int] = [:]
        for msg in messages {
            // `messages` is sorted newest-first, so the first sighting wins.
            if latest[msg.conversationHash] == nil { latest[msg.conversationHash] = msg }
            if !msg.isRead { unread[msg.conversationHash, default: 0] += 1 }
        }
        return latest.values
            .sorted { $0.timestamp > $1.timestamp }
            .map { msg in
                ConversationSummary(
                    peerHash: msg.conversationHash,
                    preview: msg.content.isEmpty ? (msg.title.isEmpty ? "…" : msg.title) : msg.content,
                    timestamp: msg.timestamp,
                    unread: unread[msg.conversationHash] ?? 0
                )
            }
    }
}

/// Renders the resolved conversation summaries, attaching display names.
///
/// Owns the `PeerEntity` query so that an announce invalidates *only* this view —
/// rebuilding an O(peers) name map and diffing `Equatable` rows — instead of
/// re-scanning every message.
private struct ConversationList: View {
    let summaries: [ConversationSummary]
    @Environment(\.modelContext) private var context
    @Query private var peers: [PeerEntity]
    @State private var searchText = ""

    var body: some View {
        if summaries.isEmpty {
            emptyState
        } else {
            let nameByHash = nameLookup()
            let visible = filtered(nameByHash)
            List(visible) { item in
                NavigationLink(value: item.peerHash) {
                    ConversationRow(summary: item, displayName: nameByHash[item.peerHash])
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
            .rnsContentListStyle()
            .rnsScreenBackground()
            .overlay {
                if visible.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .rnsInlineSearch(text: $searchText)
        }
    }

    /// Same match rule as the sibling Peers and Contacts lists: display name or
    /// hash, case-insensitively. Matching on the hash matters more here than in
    /// those lists — a conversation with a peer that has never announced a name
    /// has no other handle to search by.
    private func filtered(_ names: [String: String]) -> [ConversationSummary] {
        guard let q = RNSSearch.query(searchText) else { return summaries }
        return summaries.filter { RNSSearch.matches(q, name: names[$0.peerHash], hash: $0.peerHash) }
    }

    /// Names for the peers we actually have conversations with. Restricting to
    /// those hashes keeps the map small on a node that has heard thousands of
    /// announces but only ever messaged a handful of them.
    private func nameLookup() -> [String: String] {
        let wanted = Set(summaries.map(\.peerHash))
        var out: [String: String] = [:]
        for p in peers where wanted.contains(p.destinationHash) {
            if let name = p.displayName { out[p.destinationHash] = name }
        }
        return out
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
// Takes a pre-resolved value summary + displayName from the parent, so it holds
// no `@Model` reference and no per-row @Query subscription.

private struct ConversationRow: View, Equatable {
    let summary: ConversationSummary
    let displayName: String?

    private var label: String {
        displayName ?? "<\(String(summary.peerHash.prefix(8)))>"
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(label)
                        .font(summary.unread > 0 ? .headline.weight(.bold) : .headline)
                    Spacer()
                    Text(RNSDate.listTimestamp(summary.timestamp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(summary.preview)
                    .font(.subheadline)
                    .foregroundStyle(summary.unread > 0 ? .primary : .secondary)
                    .lineLimit(1)
            }
            if summary.unread > 0 {
                Text("\(summary.unread)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.rnsAccent, in: Capsule())
                    .accessibilityLabel("\(summary.unread) unread")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - LXMF Peers list

/// All known LXMF peers from announce history, sorted by last seen.
private struct LXMFPeersContent: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PeerEntity.lastSeen, order: .reverse) private var peers: [PeerEntity]
    @State private var searchText = ""

    /// Match on display name or hash, case-insensitively — the house rule from
    /// Destinations ▸ Peers.
    private var filtered: [PeerEntity] {
        guard let q = RNSSearch.query(searchText) else { return peers }
        return peers.filter { RNSSearch.matches(q, name: $0.displayName, hash: $0.destinationHash) }
    }

    var body: some View {
        if peers.isEmpty {
            RNSEmptyState(
                title: "No Peers Yet",
                systemImage: "person.2.fill",
                description: "Peers appear as their LXMF announces arrive across the mesh."
            )
        } else {
            List(filtered) { peer in
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
            .rnsContentListStyle()
            .rnsScreenBackground()
            .overlay {
                if filtered.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .rnsInlineSearch(text: $searchText)
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
    @State private var searchText = ""

    /// The user asked for search on the *peers* lists, but a contact list is the
    /// same shape and sits one segment away; omitting it here would be the more
    /// surprising inconsistency. Same match rule as the sibling lists.
    private var filtered: [PeerEntity] {
        guard let q = RNSSearch.query(searchText) else { return contacts }
        return contacts.filter { RNSSearch.matches(q, name: $0.displayName, hash: $0.destinationHash) }
    }

    var body: some View {
        if contacts.isEmpty {
            RNSEmptyState(
                title: "No Contacts",
                systemImage: "person.crop.circle.badge.plus",
                description: "Save a peer as a contact, or tap + to add one by destination hash."
            )
        } else {
            List(filtered) { contact in
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
            .rnsContentListStyle()
            .rnsScreenBackground()
            .overlay {
                if filtered.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .rnsInlineSearch(text: $searchText)
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
                            // Lowercase to match ComposeView — otherwise an
                            // uppercase-hex entry creates a case-mismatched
                            // duplicate peer whose thread never links up.
                            hashInput = String(new.filter { $0.isHexDigit }.prefix(32)).lowercased()
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
