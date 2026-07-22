import Foundation
import SwiftData
import ReticulumSwift

/// Listens for nomadnetwork.node announces and upserts NomadNodeEntity records.
///
/// NomadNet nodes set app_data = name.encode("utf-8") — plain UTF-8, no msgpack wrapper.
/// (See nomadnet/Node.py: `self.destination.announce(app_data=self.name.encode("utf-8"))`)
///
/// Same 1-second coalescing strategy as LXMFPeerAnnounceHandler — see that file for the
/// rationale. Announce bursts collapse into one batched SwiftData save per second.
final class NomadNetNodeAnnounceHandler: AnnounceHandler {
    public var aspectFilter: String? { "nomadnetwork.node" }

    private let container: ModelContainer
    /// Serial queue that owns `ingestContext`; all SwiftData work happens here so
    /// node-announce ingest never runs on the main thread. See
    /// `LXMFPeerAnnounceHandler` for the full rationale.
    private let queue = DispatchQueue(label: "dev.sprell.retios.node-announce-ingest",
                                      qos: .utility)
    private var ingestContext: ModelContext?

    private let lock = NSLock()
    private var pending: [String: (name: String?, date: Date)] = [:]
    private var flushScheduled = false
    private let flushInterval: TimeInterval = 1.0

    init(container: ModelContainer) {
        self.container = container
    }

    func receivedAnnounce(destinationHash: Data, identity: Identity, appData: Data?,
                          announcePacketHash: Data, isPathResponse: Bool) {
        let hex  = destinationHash.map { String(format: "%02x", $0) }.joined()
        let name = Self.parseName(from: appData)
        let now  = Date()

        lock.lock()
        if let existing = pending[hex] {
            // Keep a name once one has been seen (last-write-wins for dates).
            pending[hex] = (name ?? existing.name, now)
        } else {
            pending[hex] = (name, now)
        }
        let needSchedule = !flushScheduled
        flushScheduled = true
        lock.unlock()

        if needSchedule {
            queue.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
                self?.flush()
            }
        }
    }

    /// Runs on `queue` against the background context — never the main thread.
    private func flush() {
        let context: ModelContext
        if let existing = ingestContext {
            context = existing
        } else {
            context = ModelContext(container)
            ingestContext = context
        }

        lock.lock()
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        flushScheduled = false
        lock.unlock()

        guard !batch.isEmpty else { return }

        let hexes = Array(batch.keys)
        let descriptor = FetchDescriptor<NomadNodeEntity>(
            predicate: #Predicate { hexes.contains($0.destinationHash) }
        )
        var byHex: [String: NomadNodeEntity] = [:]
        for node in (try? context.fetch(descriptor)) ?? [] {
            byHex[node.destinationHash] = node
        }

        for (hex, info) in batch {
            if let existing = byHex[hex] {
                existing.lastSeen = info.date
                if let name = info.name { existing.displayName = name }
            } else {
                context.insert(NomadNodeEntity(destinationHash: hex, displayName: info.name))
            }
        }
        try? context.save()
    }

    /// NomadNet app_data is the node name as a plain UTF-8 string.
    private static func parseName(from data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
