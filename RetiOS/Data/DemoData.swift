import Foundation
import SwiftData

/// DEBUG-only fixture data, for reviewing screens that only look like anything
/// once they hold rows.
///
/// The Mac layout is judged by looking at it (`scripts/mac-screens.sh`), but a
/// screenshot run can't reach the *populated* Messages, Contacts or Peers
/// screens: an ad-hoc signed build has no sandbox, so it reads a different,
/// empty store from the one the real app uses. That left the exact screens with
/// the styling problems — row banding, separators, bubbles — unreviewable, and
/// every fix to them a guess. A two-row list is not enough either; row banding
/// and scan-ability only show up past a handful of entries.
///
/// Enabled with `-seedDemoData YES`. Never compiled into Release.
///
/// **Safety.** Every row it writes is tagged — messages by a `demo-` hash
/// prefix, peers and their conversations by a reserved `0d0d0d…` destination
/// hash. It refuses to touch a store containing anything it did not write, and
/// only ever deletes rows carrying those markers. Real conversations and real
/// announce-derived peers are untouchable.
enum DemoData {

    static var isEnabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "seedDemoData")
        #else
        false
        #endif
    }

    /// Reserved prefixes. A real Reticulum destination hash is a truncated
    /// SHA-256, so these are astronomically unlikely to collide — but the
    /// deletion path is still gated on the message check below, not on this
    /// alone.
    private static let peerPrefix = "0d0d0d"
    private static let messagePrefix = "demo-"

    private static func demoHash(_ index: Int) -> String {
        peerPrefix + String(format: "%026x", index)
    }

    /// Stable hashes for the two scripted conversations.
    static var peerAHash: String { demoHash(0) }
    static var peerBHash: String { demoHash(1) }

    @MainActor
    static func seedIfNeeded(_ context: ModelContext) {
        guard isEnabled else { return }

        let existingMessages = (try? context.fetch(FetchDescriptor<MessageEntity>())) ?? []

        // Refuse outright if the store holds anything real. One non-fixture
        // message disqualifies it.
        guard existingMessages.allSatisfy({ $0.messageHash.hasPrefix(messagePrefix) }) else { return }

        // Clear the previous fixture so that editing the script below actually
        // changes what the next screenshot run shows — otherwise the first seed
        // wins forever and edits look like they did nothing.
        for message in existingMessages { context.delete(message) }
        let existingPeers = (try? context.fetch(FetchDescriptor<PeerEntity>())) ?? []
        for peer in existingPeers where peer.destinationHash.hasPrefix(peerPrefix) {
            context.delete(peer)
        }

        let now = Date()

        // A couple are deliberately nameless — the common case for a peer heard
        // only via an announce.
        let names: [String?] = ["sully-iphone", "kitchen-node", "EliteOne-SB",
                                "sergds (Ts3K)", "Ashen", "gdch7", "SLEN",
                                nil, "relay-west", nil, "basement-pi"]
        for (index, name) in names.enumerated() {
            let peer = PeerEntity(destinationHash: demoHash(index), displayName: name)
            peer.lastSeen = now.addingTimeInterval(-Double(index) * 45)
            context.insert(peer)
        }

        // A short exchange on the first conversation, spanning enough of the
        // calendar to exercise every branch of `RNSDate.listTimestamp` at once
        // — today, yesterday, and a date past the weekday window.
        var script: [(peer: String, minutesAgo: Double, outbound: Bool, text: String)] = [
            (peerAHash, 60 * 26,     true,  "testing123"),
            (peerAHash, 60 * 25,     false, "hi"),
            (peerAHash, 60 * 24,     true,  "hi"),
            (peerAHash, 12,          false, "Got your message — the RNode is back on the mesh, running at 12 dBm."),
            (peerAHash, 8,           true,  "Nice. Did the propagation node pick up the backlog?"),
            (peerBHash, 60 * 24 * 9, false, "Kitchen sensor announce, hop count 2.")
        ]
        // One more conversation per remaining peer, so the Messages list is
        // long enough to show banding rather than a single row.
        for index in 2..<names.count {
            script.append((peer: demoHash(index),
                           minutesAgo: Double(index) * 137,
                           outbound: index.isMultiple(of: 2),
                           text: "Link established, \(index) hop\(index == 1 ? "" : "s") away."))
        }

        for (index, line) in script.enumerated() {
            context.insert(MessageEntity(
                messageHash: messagePrefix + String(format: "%04d", index),
                conversationHash: line.peer,
                senderHash: line.outbound ? "self" : line.peer,
                recipientHash: line.outbound ? line.peer : "self",
                title: "",
                content: line.text,
                timestamp: now.addingTimeInterval(-line.minutesAgo * 60),
                isOutbound: line.outbound,
                deliveryState: line.outbound ? 2 : 0,
                isRead: true
            ))
        }
        try? context.save()
    }
}
