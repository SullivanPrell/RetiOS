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
///   2. Flush at most once per `flushInterval` on a private serial queue against
///      its own background `ModelContext`, doing ONE bulk dedup fetch, ONE bulk
///      peer-name fetch, and ONE `save()` for the whole batch — so a backlog of
///      hundreds collapses into a single write, and none of that fetch/insert/
///      save work runs on the main thread. Only the resulting notifications hop
///      to the main actor.
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

    private let container: ModelContainer
    /// Our own lxmf.delivery hash (hex) — decides inbound vs outbound.
    private let myHash: String
    private weak var notificationManager: NotificationManager?

    /// Serial queue owning `ingestContext`. A `ModelContext` is not thread-safe,
    /// so it is created lazily *on* this queue and only ever touched here.
    private let queue = DispatchQueue(label: "dev.sprell.retios.lxmf-ingest", qos: .utility)
    private var _ingestContext: ModelContext?
    private var ingestContext: ModelContext {
        dispatchPrecondition(condition: .onQueue(queue))
        if let c = _ingestContext { return c }
        let c = ModelContext(container)
        _ingestContext = c
        return c
    }

    private let lock = NSLock()
    private var pending: [Incoming] = []
    private var flushScheduled = false

    /// Coalescing window. Short enough that a single live message still lands
    /// promptly, long enough that a backlog burst collapses into one write.
    private let flushInterval: TimeInterval = 0.4

    init(container: ModelContainer, myHash: String, notificationManager: NotificationManager?) {
        self.container = container
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
            queue.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
                self?.flush()
            }
        }
    }

    /// Drains the buffer and writes the whole batch in one transaction.
    /// Runs on `queue`, against the background context — never the main actor.
    private func flush() {
        dispatchPrecondition(condition: .onQueue(queue))
        let context = ingestContext
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

        notify(inserted, context: context)
    }

    /// A notification to post, resolved to plain strings on the ingest queue so
    /// nothing thread-confined crosses to the main actor.
    private struct Banner {
        let senderName: String
        let preview: String
        let peerHash: String
    }

    /// Resolve sender names and post local notifications for the inbound
    /// messages in a flushed batch. The name fetch runs here on the ingest
    /// queue; only the finished `Banner` values hop to the main actor.
    private func notify(_ inserted: [Incoming], context: ModelContext) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard notificationManager != nil else { return }
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
        let banners: [Banner]
        if inbound.count > burstThreshold {
            let senders = Set(inbound.map { names[$0.conversationHash] ?? "\($0.conversationHash.prefix(8))…" })
            let who = senders.count == 1 ? (senders.first ?? "") : "\(senders.count) contacts"
            banners = [Banner(senderName: who,
                              preview: "\(inbound.count) new messages",
                              peerHash: inbound.last?.conversationHash ?? "")]
        } else {
            banners = inbound.map { item in
                Banner(senderName: names[item.conversationHash] ?? "\(item.conversationHash.prefix(8))…",
                       preview: item.content.trimmingCharacters(in: .whitespacesAndNewlines),
                       peerHash: item.conversationHash)
            }
        }

        Task { @MainActor [weak self] in
            guard let nm = self?.notificationManager else { return }
            for b in banners {
                nm.scheduleMessageNotification(senderName: b.senderName,
                                               preview: b.preview,
                                               peerHash: b.peerHash)
            }
        }
    }
}
