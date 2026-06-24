import Foundation
import SwiftData
import ReticulumSwift
import LXMF

/// Listens for LXMF delivery announces and upserts PeerEntity records.
///
/// Transport calls `receivedAnnounce` from background threads, often in bursts
/// (a busy mesh can deliver hundreds of `lxmf.delivery` announces per second).
/// Writing one SwiftData save per announce would saturate the main thread —
/// every save re-renders every `@Query` view — and the UI (including the
/// keyboard / text entry) would starve and appear frozen.
///
/// To stay responsive under load this handler:
///   1. Buffers announces in a lock-protected, last-wins map (cheap, any thread).
///   2. Flushes the buffer at most once per `flushInterval`, doing a single bulk
///      fetch + single `save()` for the whole batch. So a burst of hundreds of
///      announces collapses into one inexpensive write per second.
///
/// The flush runs on the main actor against the app's main `ModelContext` so the
/// `@Query`-backed views update reliably; the per-flush cost is bounded and tiny
/// regardless of how much announce traffic arrives.
final class LXMFPeerAnnounceHandler: AnnounceHandler {
    public var aspectFilter: String? { "lxmf.delivery" }

    private let context: ModelContext

    private let lock = NSLock()
    private var pending: [String: (name: String?, date: Date)] = [:]
    private var flushScheduled = false

    /// Coalescing window. Bursts collapse into a single batched save per window.
    private let flushInterval: TimeInterval = 1.0

    init(context: ModelContext) {
        self.context = context
    }

    func receivedAnnounce(destinationHash: Data, identity: Identity, appData: Data?,
                          announcePacketHash: Data, isPathResponse: Bool) {
        // Capture value types here — called on a Transport background thread.
        let hex         = destinationHash.map { String(format: "%02x", $0) }.joined()
        let displayName = Self.extractDisplayName(from: appData)
        let now         = Date()

        lock.lock()
        if let existing = pending[hex] {
            // Last write wins; keep a name once we've seen one.
            pending[hex] = (displayName ?? existing.name, now)
        } else {
            pending[hex] = (displayName, now)
        }
        let needSchedule = !flushScheduled
        flushScheduled = true
        lock.unlock()

        if needSchedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
    }

    /// Drains the pending buffer and writes it in one transaction.
    @MainActor
    private func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        flushScheduled = false
        lock.unlock()

        guard !batch.isEmpty else { return }

        // One fetch for every peer in the batch, then upsert in memory.
        let hexes = Array(batch.keys)
        let descriptor = FetchDescriptor<PeerEntity>(
            predicate: #Predicate { hexes.contains($0.destinationHash) }
        )
        var byHex: [String: PeerEntity] = [:]
        for peer in (try? context.fetch(descriptor)) ?? [] {
            byHex[peer.destinationHash] = peer
        }

        for (hex, info) in batch {
            if let existing = byHex[hex] {
                existing.lastSeen = info.date
                if let name = info.name { existing.displayName = name }
            } else {
                context.insert(PeerEntity(destinationHash: hex, displayName: info.name))
            }
        }
        try? context.save()
    }

    /// LXMF announce app_data is msgpack([display_name_bytes?, stamp_cost?, ...]).
    /// Delegates to the canonical `displayNameFromAppData` from LXMF, which handles
    /// both bin (.bytes) and legacy str (.string) first elements, plus plain-UTF-8
    /// fallback for pre-0.5.0 announces.
    private static func extractDisplayName(from data: Data?) -> String? {
        displayNameFromAppData(data)
    }
}
