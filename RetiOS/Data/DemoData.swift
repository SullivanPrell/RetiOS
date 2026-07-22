import Foundation
import SwiftData

/// DEBUG-only fixture data, for reviewing screens that only look like anything
/// once they hold rows.
///
/// The Mac layout is judged by looking at it (`scripts/mac-screens.sh`), but a
/// screenshot run can't reach the *populated* Messages, Contacts or Peers
/// screens: an ad-hoc signed build has no sandbox, so it reads a different,
/// empty store from the one the real app uses. That left the exact screens with
/// the styling problems — row containers, bubbles, list separators —
/// unreviewable, and every fix to them a guess.
///
/// Enabled with `-seedDemoData YES`. Inserts nothing if the store already has
/// messages, so it can never overwrite real data, and it is never compiled into
/// Release.
enum DemoData {

    static var isEnabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "seedDemoData")
        #else
        false
        #endif
    }

    /// Deterministic hashes so a screenshot run can deep-link to a known thread.
    static let peerAHash = "2056d8ba1f4c7e93aa0b6d15c8e2f47b"
    static let peerBHash = "9c3e1a7f52d0b8461ee7c9a3d40b25d1"

    @MainActor
    static func seedIfNeeded(_ context: ModelContext) {
        guard isEnabled else { return }

        // Never clobber a store that already holds real conversations.
        let existing = try? context.fetch(FetchDescriptor<MessageEntity>())
        guard existing?.isEmpty ?? true else { return }

        let now = Date()
        let peers: [(hash: String, name: String)] = [
            (peerAHash, "sully-iphone"),
            (peerBHash, "kitchen-node")
        ]
        for peer in peers {
            let entity = PeerEntity(destinationHash: peer.hash, displayName: peer.name)
            entity.lastSeen = now.addingTimeInterval(-600)
            context.insert(entity)
        }

        // A short exchange, spanning enough of the calendar to exercise every
        // branch of `RNSDate.listTimestamp` at once — today, yesterday, and a
        // date old enough to fall past the weekday window.
        let script: [(peer: String, minutesAgo: Double, outbound: Bool, text: String)] = [
            (peerAHash, 60 * 26,  true,  "testing123"),
            (peerAHash, 60 * 25,  false, "hi"),
            (peerAHash, 60 * 24,  true,  "hi"),
            (peerAHash, 12,       false, "Got your message — the RNode is back on the mesh, running at 12 dBm."),
            (peerAHash, 8,        true,  "Nice. Did the propagation node pick up the backlog?"),
            (peerBHash, 60 * 24 * 9, false, "Kitchen sensor announce, hop count 2.")
        ]
        for (index, line) in script.enumerated() {
            let message = MessageEntity(
                messageHash: String(format: "demo%028d", index),
                conversationHash: line.peer,
                senderHash: line.outbound ? "self" : line.peer,
                recipientHash: line.outbound ? line.peer : "self",
                title: "",
                content: line.text,
                timestamp: now.addingTimeInterval(-line.minutesAgo * 60),
                isOutbound: line.outbound,
                deliveryState: line.outbound ? 2 : 0,
                isRead: true
            )
            context.insert(message)
        }
        try? context.save()
    }
}
