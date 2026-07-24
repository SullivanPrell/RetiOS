import SwiftUI
import SwiftData
import ReticulumSwift

struct CallsView: View {
    @Environment(CallsController.self) private var calls
    @Environment(NotificationManager.self) private var notifs
    @State private var showNewCall = false
    @State private var idleSection: CallsIdleSection = .recents

    var body: some View {
        NavigationStack {
            Group {
                switch calls.callState {
                case .idle:
                    idleContainerView
                case .incoming(let callerHash):
                    incomingCallView(callerHash: callerHash)
                case .calling(let hash):
                    callingView(hash: hash)
                case .active(let hash, let since):
                    activeCallView(hash: hash, since: since)
                case .failed(let reason):
                    failedView(reason: reason)
                }
            }
            .rnsCanvasBackground()
            // Flush pinned title (no large-title dead space) — matches the
            // Messages tab. The New Call action moves from the nav-bar toolbar
            // into the pinned header's trailing slot.
            .rnsPinnedTitle("Calls") {
                Button(action: { showNewCall = true }) {
                    Image(systemName: "phone.badge.plus")
                }
                .accessibilityLabel("New Call")
                .disabled(calls.callState != .idle)
            }
            .sheet(isPresented: $showNewCall) {
                NewCallSheet()
            }
            .rnsFeedback(trigger: calls.callState) { _, new in
                switch new {
                case .active:   return .success
                case .failed:   return .error
                case .incoming: return .impact(weight: .medium)
                default:        return nil
                }
            }
            // Menu-bar "File ▸ New Call" (⌘⇧C). Only when idle — matches the
            // toolbar button's disabled state.
            .onChange(of: notifs.requestNewCall) { _, _ in
                if calls.callState == .idle { showNewCall = true }
            }
        }
    }

    // MARK: - Idle container (tabs)

    private var idleContainerView: some View {
        Group {
            switch idleSection {
            case .recents:
                CallsRecentsContent()
            case .peers:
                CallsPeersContent { hash in
                    if let data = Data(hexString: hash) {
                        calls.startCall(to: data)
                    }
                }
            }
        }
        .rnsSectionPicker([
            ("Recents", CallsIdleSection.recents),
            ("Peers",   CallsIdleSection.peers)
        ], selection: $idleSection)
    }

    // MARK: - Call states

    /// `lxst.telephony` hashes heard from announces, handed to the in-call
    /// contact action so it can identify an inbound caller (see
    /// `CallPeerResolver`).
    private var lxstPeerHashes: [String] {
        calls.lxstPeers.map(\.destinationHash)
    }

    private func incomingCallView(callerHash: Data) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "phone.arrow.down.left.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.rnsAccent)
                .symbolEffect(.pulse)
                .accessibilityHidden(true)
            Text("Incoming Call")
                .font(.title2.bold())
            if callerHash.isEmpty {
                Text("Unknown caller")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(callerHash.hexString.truncatedHash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // Same affordance a message thread gets: save the other party
                // as a contact without leaving the call screen.
                CallContactAction(callHash: callerHash, lxstPeerHashes: lxstPeerHashes,
                                  liveIdentity: calls.activeCallRemoteIdentity)
            }
            HStack(spacing: 40) {
                VStack(spacing: 8) {
                    Button(action: { calls.rejectIncomingCall() }) {
                        Image(systemName: "phone.down.fill")
                            .font(.title)
                            .frame(width: 64, height: 64)
                            .background(Color.rnsError, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Decline call")
                    Text("Decline")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
                VStack(spacing: 8) {
                    Button(action: { calls.acceptIncomingCall() }) {
                        Image(systemName: "phone.fill")
                            .font(.title)
                            .frame(width: 64, height: 64)
                            .background(Color.rnsSuccess, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Accept call")
                    Text("Accept")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal)
    }

    private func callingView(hash: Data) -> some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Calling…")
                .font(.title2)
            Text(hash.hexString.truncatedHash)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            CallContactAction(callHash: hash, lxstPeerHashes: lxstPeerHashes,
                                  liveIdentity: calls.activeCallRemoteIdentity)
            Button(role: .destructive, action: { calls.endCall() }) {
                Label("Cancel", systemImage: "phone.down.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.rnsError)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal)
    }

    private func activeCallView(hash: Data, since: Date) -> some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(Color.rnsSuccess)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Connected")
                    .font(.title2.bold())
                Text(hash.hexString.truncatedHash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(since, style: .timer)
                    .foregroundStyle(.secondary)
                CallContactAction(callHash: hash, lxstPeerHashes: lxstPeerHashes,
                                  liveIdentity: calls.activeCallRemoteIdentity)
                    .padding(.top, 4)
            }

            HStack(spacing: 40) {
                VStack(spacing: 8) {
                    Button(action: { calls.toggleMute() }) {
                        Image(systemName: calls.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.title)
                            .frame(width: 64, height: 64)
                            // `.quaternary` is the native, cross-platform fill for an
                            // inactive control — a translucent neutral that stays visible
                            // on ANY background in both Light and Dark. (Grouped-tertiary
                            // matched the grouped call screen exactly in Light, making the
                            // circle invisible; plain `Color(.systemGray5)` is UIKit-only.)
                            .background(calls.isMuted ? AnyShapeStyle(Color.rnsWarning)
                                                      : AnyShapeStyle(.quaternary),
                                        in: Circle())
                            .foregroundStyle(calls.isMuted ? .white : .primary)
                    }
                    .accessibilityLabel(calls.isMuted ? "Unmute microphone" : "Mute microphone")
                    Text(calls.isMuted ? "Unmute" : "Mute")
                        .font(.caption)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 8) {
                    Button(action: { calls.endCall() }) {
                        Image(systemName: "phone.down.fill")
                            .font(.title)
                            .frame(width: 64, height: 64)
                            .background(Color.rnsError, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("End call")
                    Text("End")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal)
    }

    private func failedView(reason: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(Color.rnsError)
                .accessibilityHidden(true)
            Text("Call Failed")
                .font(.title2.bold())
            Text(reason)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Dismiss") { calls.endCall() }
                .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Idle section enum

private enum CallsIdleSection: Hashable { case recents, peers }

// MARK: - Recents content

private struct CallsRecentsContent: View {
    @Environment(CallsController.self) private var calls

    var body: some View {
        if calls.callHistory.isEmpty {
            RNSEmptyState(
                title: "No Recent Calls",
                systemImage: "phone.arrow.up.right",
                description: "Your call history will appear here once you make or receive a call."
            )
        } else {
            List(calls.callHistory) { record in
                // Tap a recent to call back (matches the Phone app). Recents are
                // only shown while idle, so starting a call here is always safe.
                Button {
                    if !record.peerHash.isEmpty, let data = Data(hexString: record.peerHash) {
                        calls.startCall(to: data)
                    }
                } label: {
                    CallRecordRow(record: record)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Call back")
                .rnsRow()
            }
            .rnsContentListStyle()
            .rnsScreenBackground()
        }
    }
}

private struct CallRecordRow: View {
    let record: CallRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: directionIcon)
                .foregroundStyle(outcomeColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.peerHash.isEmpty ? "Unknown" : record.peerHash)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(outcomeLabel)
                        .font(.caption)
                        .foregroundStyle(outcomeColor)
                    if let dur = record.duration {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(durationString(dur))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Text(RNSDate.listTimestamp(record.startTime))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var directionIcon: String {
        switch record.direction {
        case .outbound: return "phone.arrow.up.right"
        case .inbound:  return "phone.arrow.down.left"
        }
    }

    private var outcomeLabel: String {
        switch record.outcome {
        case .calling:      return "Calling…"
        case .answered:     return record.direction == .inbound ? "Received" : "Outgoing"
        case .missed:       return "Missed"
        case .rejected:     return "Declined"
        case .failed:       return "Failed"
        }
    }

    private var outcomeColor: Color {
        switch record.outcome {
        case .answered:              return .rnsSuccess
        case .missed:                return .rnsError
        case .rejected:              return .rnsWarning
        case .failed, .calling:      return .secondary
        }
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}

// MARK: - Call hash → contact resolution

/// Maps a hash surfaced by `CallsController` onto the `lxmf.delivery` hash that
/// `PeerEntity.destinationHash` stores, so the other party can be saved as a
/// contact.
///
/// **An LXST call hash is not a contact hash.** Three different 16-byte
/// namespaces show up in this tab, all derived from the same remote Identity but
/// none interchangeable with the others:
///
///   * `lxst.telephony` destination hashes — what LXST announces carry, and what
///     `LXSTPeer.destinationHash` and an outbound dial from the peers list hold.
///   * Identity hashes — `Telephone`'s ringing callback reports the caller as
///     `Identity.hash`, which is not a destination hash at all.
///   * `lxmf.delivery` destination hashes — the only thing `PeerEntity` accepts.
///
/// Writing a call hash straight into a `PeerEntity` would mint a contact whose
/// address routes nowhere and whose messages could never be delivered, so every
/// contact action here resolves first and is simply unavailable when it cannot.
private enum CallPeerResolver {
    /// Name hash of `lxmf.delivery`. Constant for the life of the process.
    private static let lxmfDeliveryNameHash =
        Destination.computeNameHash(appName: "lxmf", aspects: ["delivery"])

    /// The remote party's `lxmf.delivery` destination hash (hex), or nil when the
    /// link to a real Identity cannot be proven.
    ///
    /// - Parameter lxstPeerHashes: `lxst.telephony` hashes currently known from
    ///   announces. Used to identify an inbound caller, who is reported by
    ///   identity hash rather than by any destination hash.
    static func lxmfDeliveryHex(forCallHash hash: Data,
                                lxstPeerHashes: [String] = [],
                                liveIdentity: Identity? = nil) -> String? {
        // Case 0 — a call is on the line, so the link handshake has already
        // proven the remote public key. This is the ONLY branch that works for
        // an inbound call from a peer we have not heard announce this session,
        // which is precisely the caller a user most wants to save: `.incoming`
        // carries an *identity* hash, and nothing in Reticulum is keyed by one.
        // Every branch below reconstructs what this one is simply handed.
        //
        // This branch alone falls back to the unproven derivation. The other
        // cases require the delivery destination to have been announced (see
        // `announcedDeliveryHash`), because they fire passively while a list is
        // on screen. Here the identity is cryptographically verified and the
        // user has explicitly asked to save this caller, so deriving their
        // address is warranted even though we cannot yet tell whether they run
        // LXMF at all.
        if let liveIdentity {
            return announcedDeliveryHash(for: liveIdentity)?.hexString
                ?? Destination.hash(identity: liveIdentity,
                                    appName: "lxmf",
                                    aspects: ["delivery"]).hexString
        }

        guard !hash.isEmpty else { return nil }

        // Case A — `hash` is a destination hash we have heard announced (an LXST
        // peer row, or a hash dialled from Peers / New Call, both of which only
        // reach a call state after `startCall` recalled the identity). Recall
        // hands back the remote Identity and the delivery address follows from
        // it. This is the same derivation `hasLXSTCallPath` performs, run the
        // other way round.
        if let identity = Identity.recall(destinationHash: hash) {
            return announcedDeliveryHash(for: identity)?.hexString
        }

        // From here `hash` is an Identity hash (an inbound ring), which never
        // recalls because nothing is keyed by identity hash. Two ways to get
        // back to the Identity itself, both of which must *prove* the match
        // rather than assume it — an unknown destination hash reinterpreted as
        // an identity hash would silently produce a garbage contact.

        // Case B — the caller is one of the LXST peers we have heard announce.
        // Recalling that announce yields the Identity object, and comparing its
        // own hash to the caller hash is the proof.
        for hex in lxstPeerHashes {
            guard let destination = Data(hexString: hex),
                  let identity = Identity.recall(destinationHash: destination),
                  identity.hash == hash
            else { continue }
            return announcedDeliveryHash(for: identity)?.hexString
        }

        // Case C — the caller never announced LXST but did announce LXMF. A
        // single-kind destination hash is truncatedHash(nameHash + identityHash),
        // so the delivery address is computable from the identity hash alone —
        // the same bytes the `Destination` initialiser would produce if we held
        // the Identity object. Recalling the derived hash and checking that the
        // identity behind it hashes back to the caller is the proof here.
        let derived = Identity.truncatedHash(lxmfDeliveryNameHash + hash)
        if let identity = Identity.recall(destinationHash: derived), identity.hash == hash {
            return derived.hexString
        }
        return nil
    }

    /// The identity's `lxmf.delivery` hash, but only if that destination has
    /// actually been announced.
    ///
    /// The derivation itself always succeeds — a destination hash is a pure
    /// function of the identity and the name — so returning it unconditionally
    /// mints an address for a node that may serve no LXMF at all. `rnphone`
    /// (LXST's own console entry point) is exactly that: it constructs only an
    /// `lxst.telephony` destination and never imports LXMF. Saving one of those
    /// as a contact produced a permanent row in Messages ▸ Contacts for an
    /// address nothing on the network answers, and neither list offers a delete.
    ///
    /// Recalling the derived hash is the proof: it succeeds only if that exact
    /// destination was announced and ingested.
    private static func announcedDeliveryHash(for identity: Identity) -> Data? {
        let derived = Destination.hash(identity: identity,
                                       appName: "lxmf",
                                       aspects: ["delivery"])
        return Identity.recall(destinationHash: derived) != nil ? derived : nil
    }
}

/// Creates or updates the `PeerEntity` for an already-resolved delivery hash.
/// Mirrors the Messages tab's add-contact idiom (flip `isContact`, then save).
private func saveCallPeerAsContact(lxmfHex: String, in context: ModelContext) {
    let descriptor = FetchDescriptor<PeerEntity>(
        predicate: #Predicate<PeerEntity> { $0.destinationHash == lxmfHex }
    )
    if let existing = try? context.fetch(descriptor).first {
        existing.isContact = true
    } else {
        // No row yet: the peer announced LXST but never LXMF. The delivery hash
        // was still derived from their real Identity, so this is their address —
        // it just has not been heard announced yet.
        context.insert(PeerEntity(destinationHash: lxmfHex, isContact: true))
    }
    try? context.save()
}

/// In-call "Add to Contacts" affordance, shown on the ringing, dialling and
/// connected screens.
///
/// Renders nothing at all when the remote party cannot be resolved to an LXMF
/// delivery address (see `CallPeerResolver`) — an inert or lying button would be
/// worse than no button.
private struct CallContactAction: View {
    @Environment(\.modelContext) private var context
    /// Live row for the resolved peer, so the label flips the moment it is saved.
    @Query private var matches: [PeerEntity]

    private let lxmfHex: String?

    /// - Parameter lxstPeerHashes: passed in rather than read from the
    ///   environment because resolution has to happen *in the initialiser* — it
    ///   supplies the `@Query` predicate, and environment values are not
    ///   available until the view body runs.
    /// - Parameter liveIdentity: the remote party's handshake-verified
    ///   `Identity` when a call is on the line. Without it an inbound call from
    ///   a peer whose announces we have not heard this session resolves to
    ///   nothing — and an unknown caller is exactly the one worth saving.
    init(callHash: Data, lxstPeerHashes: [String], liveIdentity: Identity? = nil) {
        let hex = CallPeerResolver.lxmfDeliveryHex(forCallHash: callHash,
                                                   lxstPeerHashes: lxstPeerHashes,
                                                   liveIdentity: liveIdentity)
        lxmfHex = hex
        // An unresolved call hash queries for the empty string, which no real
        // 32-character hash can equal, so the query stays empty rather than
        // matching an arbitrary row.
        let target = hex ?? ""
        _matches = Query(filter: #Predicate<PeerEntity> { $0.destinationHash == target },
                         sort: \PeerEntity.lastSeen, order: .reverse)
    }

    var body: some View {
        if let lxmfHex {
            if matches.first?.isContact == true {
                Label("In Contacts", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(Color.rnsTextSecondary)
            } else {
                Button {
                    saveCallPeerAsContact(lxmfHex: lxmfHex, in: context)
                } label: {
                    Label("Add to Contacts", systemImage: "person.crop.circle.badge.plus")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.rnsAccent)
            }
        }
    }
}

// MARK: - LXST Peers content

/// An LXST peer paired with the LXMF peer record it resolves to.
///
/// `LXSTPeer` carries no name — only a `lxst.telephony` hash and a last-seen
/// date — so the display name and contact state both come from the resolved
/// `PeerEntity`, and search matches against it.
private struct ResolvedCallPeer: Identifiable {
    let peer: LXSTPeer
    /// The peer's `lxmf.delivery` hash (hex), or nil when it cannot be resolved.
    let lxmfHex: String?
    let contact: PeerEntity?

    var id: String { peer.id }
    var displayName: String? { contact?.displayName }
    var isContact: Bool { contact?.isContact ?? false }
}

private struct CallsPeersContent: View {
    @Environment(CallsController.self) private var calls
    @Environment(\.modelContext) private var context
    @Query(sort: \PeerEntity.lastSeen, order: .reverse) private var knownPeers: [PeerEntity]
    @State private var searchText = ""
    let onCall: (String) -> Void

    private var resolvedPeers: [ResolvedCallPeer] {
        let byHash = Dictionary(knownPeers.map { ($0.destinationHash, $0) },
                                uniquingKeysWith: { first, _ in first })
        return calls.lxstPeers.map { peer in
            let lxmfHex = Data(hexString: peer.destinationHash)
                .flatMap { CallPeerResolver.lxmfDeliveryHex(forCallHash: $0) }
            return ResolvedCallPeer(peer: peer,
                                    lxmfHex: lxmfHex,
                                    contact: lxmfHex.flatMap { byHash[$0] })
        }
    }

    // House search semantics: match display name or hash, case-insensitively.
    // The LXMF hash is included because a peer copied from the Messages tab is
    // identified there by its delivery hash, not by its call hash.
    private var filtered: [ResolvedCallPeer] {
        guard let q = RNSSearch.query(searchText) else { return resolvedPeers }
        return resolvedPeers.filter {
            RNSSearch.matches(q, name: $0.displayName,
                              hashes: [$0.peer.destinationHash, $0.lxmfHex])
        }
    }

    var body: some View {
        if calls.lxstPeers.isEmpty {
            RNSEmptyState(
                title: "No LXST Peers",
                systemImage: "phone.badge.waveform",
                description: "Peers that have announced their LXST call address will appear here. Enable LXST announcing in Settings so others can call you too."
            )
        } else {
            List(filtered) { entry in
                LXSTPeerRow(entry: entry, onCall: onCall)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        contactButton(for: entry)
                    }
                    .contextMenu {
                        contactButton(for: entry)
                    }
                    .rnsRow()
            }
            .rnsContentListStyle()
            .rnsScreenBackground()
            // Overlay goes on the list, *before* the search field is stacked on
            // top: applied after `rnsInlineSearch` it would cover the field itself
            // and the user could never edit or clear a no-results query.
            .overlay {
                if filtered.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .rnsInlineSearch(text: $searchText)
        }
    }

    /// Add/remove-contact action, omitted entirely for a peer whose LXMF
    /// delivery address could not be resolved from its call hash.
    @ViewBuilder
    private func contactButton(for entry: ResolvedCallPeer) -> some View {
        if let lxmfHex = entry.lxmfHex {
            Button {
                if let existing = entry.contact, existing.isContact {
                    existing.isContact = false
                    try? context.save()
                } else {
                    saveCallPeerAsContact(lxmfHex: lxmfHex, in: context)
                }
            } label: {
                Label(entry.isContact ? "Remove Contact" : "Add Contact",
                      systemImage: entry.isContact ? "person.crop.circle.badge.minus"
                                                   : "person.crop.circle.badge.plus")
            }
            .tint(entry.isContact ? Color.rnsWarning : Color.rnsAccent)
        }
    }
}

private struct LXSTPeerRow: View {
    let entry: ResolvedCallPeer
    let onCall: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            PeerIdentityView(name: entry.displayName,
                             hash: entry.peer.destinationHash,
                             lastSeen: entry.peer.lastSeen)
            Spacer()
            if entry.isContact {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(Color.rnsAccent)
                    .accessibilityLabel("Contact")
            }
            Button {
                onCall(entry.peer.destinationHash)
            } label: {
                Image(systemName: "phone.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.rnsSuccess)
            .accessibilityLabel("Call peer")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - New call sheet

struct NewCallSheet: View {
    @Environment(CallsController.self) private var calls
    @Environment(\.dismiss) private var dismiss
    @State private var hashInput = ""
    @State private var inputError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Destination Hash") {
                    TextField("32-character hex hash", text: $hashInput)
                        .rnsHashFieldStyle()
                        .onChange(of: hashInput) { _, new in
                            hashInput = String(new.filter { $0.isHexDigit }.prefix(32))
                        }
                    if let err = inputError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(Color.rnsError)
                    }
                }
                .rnsRow()
                Section {
                    Text("Enter the 32-hex-character destination hash (16 bytes) of the remote LXST node.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .rnsRow()
            }
            .rnsScreenBackground()
            .navigationTitle("New Call")
            .rnsInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Call") { initiateCall() }
                        .disabled(hashInput.filter { $0.isHexDigit }.count != 32)
                }
            }
        }
    }

    private func initiateCall() {
        let hex = String(hashInput.filter { $0.isHexDigit }.prefix(32))
        guard hex.count == 32, let hash = Data(hexString: hex) else {
            inputError = "Must be exactly 32 hex characters (16 bytes)"
            return
        }
        calls.startCall(to: hash)
        dismiss()
    }
}

// MARK: - Helpers

private extension Data {
    init?(hexString: String) {
        let hex = hexString.filter { $0.isHexDigit }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
