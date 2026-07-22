import Foundation
import SwiftData
import ReticulumSwift
import LXMF

/// Coalesces inbound LXMF messages into batched SwiftData writes.
///
/// `LXMRouter.onMessageReceived` fires once per delivered message, from a
/// transport background thread. Doing one fetch + insert + `save()` per message
/// on the app's main `ModelContext` is expensive twice over: the work itself
/// runs on the main actor, and *every* `save()` invalidates *every* on-screen
/// `@Query`, which then re-runs its fetch (`ConversationsView` re-scans the
/// whole message table on each one).
///
/// That is survivable for a trickle of live traffic but not for a burst — and a
/// propagation-node sync produces exactly a burst: the router replays the whole
/// offline backlog through this callback back-to-back, so the app hung for the
/// duration of the sync that runs on every launch.
///
/// This mirrors `LXMFPeerAnnounceHandler`, which already solved the identical
/// problem for announce storms:
///   1. Extract plain value types on the calling thread and buffer them under a
///      lock (cheap, safe from any thread — no `@Model` object escapes).
///   2. Flush at most once per `flushInterval` on the main actor, doing ONE bulk
///      dedup fetch, ONE bulk peer-name fetch, and ONE `save()` for the whole
///      batch — so a backlog of hundreds collapses into a single write.
final class LXMFMessageIngest {

    /// A received message reduced to value types, captured off the main actor.
    /// Deliberately holds no `LXMessage` / `@Model` reference so nothing
    /// thread-confined escapes the transport thread.
    private struct Incoming {
        let messageHash: String
        let conversationHash: String
        let senderHash: String
        let recipientHash: String
        let title: String
        let content: String
        let timestamp: Date
        let isInbound: Bool
        let deliveryState: Int16
        let hasAttachments: Bool
        let packedMessage: Data?
    }

    private let context: ModelContext
    /// Our own lxmf.delivery hash (hex) — decides inbound vs outbound.
    private let myHash: String
    private weak var notificationManager: NotificationManager?

    private let lock = NSLock()
    private var pending: [Incoming] = []
    private var flushScheduled = false

    /// Coalescing window. Short enough that a single live message still lands
    /// promptly, long enough that a backlog burst collapses into one write.
    private let flushInterval: TimeInterval = 0.4

    init(context: ModelContext, myHash: String, notificationManager: NotificationManager?) {
        self.context = context
        self.myHash = myHash
        self.notificationManager = notificationManager
    }

    /// Buffer a received message. Safe to call from any thread.
    func enqueue(_ message: LXMessage) {
        let senderHex    = message.sourceHash.map { String(format: "%02x", $0) }.joined()
        let recipientHex = message.destinationHash.map { String(format: "%02x", $0) }.joined()
        // conversationHash is always the peer's side — not us.
        let isInbound = senderHex != myHash
        let peerHex   = isInbound ? senderHex : recipientHex
        let msgHash   = message.hash?.map { String(format: "%02x", $0) }.joined() ?? UUID().uuidString
        let carriesFields = !message.fields.isEmpty

        let incoming = Incoming(
            messageHash: msgHash,
            conversationHash: peerHex,
            senderHash: senderHex,
            recipientHash: recipientHex,
            title: message.titleAsString ?? "",
            content: message.contentAsString ?? "",
            timestamp: Date(timeIntervalSince1970: message.timestamp ?? Date().timeIntervalSince1970),
            isInbound: isInbound,
            deliveryState: Int16(message.state.rawValue),
            hasAttachments: carriesFields,
            packedMessage: carriesFields ? message.packed : nil
        )

        lock.lock()
        pending.append(incoming)
        let needSchedule = !flushScheduled
        flushScheduled = true
        lock.unlock()

        if needSchedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
    }

    /// Drains the buffer and writes the whole batch in one transaction.
    @MainActor
    private func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        flushScheduled = false
        lock.unlock()

        guard !batch.isEmpty else { return }

        // ONE dedup fetch for the whole batch (was one per message).
        let hashes = batch.map(\.messageHash)
        let existingDescriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { hashes.contains($0.messageHash) }
        )
        var known = Set((try? context.fetch(existingDescriptor))?.map(\.messageHash) ?? [])

        var inserted: [Incoming] = []
        for item in batch {
            // Guards against duplicates already in the store AND repeats within
            // this same batch (a replayed backlog can contain both).
            guard !known.contains(item.messageHash) else { continue }
            known.insert(item.messageHash)

            context.insert(MessageEntity(
                messageHash: item.messageHash,
                conversationHash: item.conversationHash,
                senderHash: item.senderHash,
                recipientHash: item.recipientHash,
                title: item.title,
                content: item.content,
                timestamp: item.timestamp,
                isOutbound: !item.isInbound,
                deliveryState: item.deliveryState,
                isRead: !item.isInbound,
                hasAttachments: item.hasAttachments,
                packedMessage: item.packedMessage
            ))
            inserted.append(item)
        }

        guard !inserted.isEmpty else { return }

        // ONE save for the batch — this is the invalidation that re-runs the
        // on-screen @Query views, so it must happen once, not N times.
        try? context.save()

        notify(inserted)
    }

    /// Post local notifications for the inbound messages in a flushed batch,
    /// resolving every sender name in a single fetch.
    @MainActor
    private func notify(_ inserted: [Incoming]) {
        guard let nm = notificationManager else { return }
        let inbound = inserted.filter(\.isInbound)
        guard !inbound.isEmpty else { return }

        let peerHexes = Array(Set(inbound.map(\.conversationHash)))
        let peerDescriptor = FetchDescriptor<PeerEntity>(
            predicate: #Predicate { peerHexes.contains($0.destinationHash) }
        )
        var names: [String: String] = [:]
        for peer in (try? context.fetch(peerDescriptor)) ?? [] {
            if let name = peer.displayName, !name.isEmpty { names[peer.destinationHash] = name }
        }

        // A replayed backlog can be large; posting one banner per message would
        // bury the user in notifications for messages that all arrived at once.
        // Notify individually for a normal trickle, and summarise a burst.
        let burstThreshold = 3
        if inbound.count > burstThreshold {
            let senders = Set(inbound.map { names[$0.conversationHash] ?? "\($0.conversationHash.prefix(8))…" })
            let who = senders.count == 1 ? (senders.first ?? "") : "\(senders.count) contacts"
            nm.scheduleMessageNotification(
                senderName: who,
                preview: "\(inbound.count) new messages",
                peerHash: inbound.last?.conversationHash ?? ""
            )
            return
        }

        for item in inbound {
            let senderName = names[item.conversationHash] ?? "\(item.conversationHash.prefix(8))…"
            let preview = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            nm.scheduleMessageNotification(senderName: senderName,
                                           preview: preview,
                                           peerHash: item.conversationHash)
        }
    }
}
