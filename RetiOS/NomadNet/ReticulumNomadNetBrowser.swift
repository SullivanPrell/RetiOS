import Foundation
import ReticulumSwift
import NomadNet

/// Production NomadNetBrowser subclass that performs real page requests
/// over live RNS Links.
///
/// Protocol (mirrors Python Browser.request_page):
///   1. Check transport has a path to the destination hash.
///   2. If missing, request a path and *wait* for it to resolve (up to
///      `firstHopTimeout + timeout`) before proceeding — auto-retrying rather
///      than dead-ending on an error the user has to dismiss and retry by hand.
///   3. Recall the remote identity, build an outbound Destination.
///   4. Initiate a Link; on established, call link.request(path:nativeValue:)
///      with the field/var map INLINE (so a Python node reads it as a dict —
///      see swift_devel/bugs/008; the old encode()+data: path double-packed it).
///   5. Hand response bytes to handleResponse(_:url:) for Micron parsing.
///
/// Threading: `performRequest` is only ever invoked from `NomadNetController`
/// (a `@MainActor` type), so it runs on the main thread. The path-wait poll is
/// scheduled back onto the main queue, keeping every `Transport` access on the
/// same thread as the initial call (Transport is not internally serialized) and
/// letting `currentGeneration` be read/written without a lock.
final class ReticulumNomadNetBrowser: NomadNetBrowser {

    private weak var transport: Transport?

    /// Local identity used to identify to the node on the link (Python
    /// `Browser` identifies the browsing peer so nodes can gate / personalise
    /// pages). Nil → can never identify (always anonymous).
    private let appIdentity: Identity?

    /// Per-node "identify on connect" predicate, mirroring Python NomadNet's
    /// `directory.should_identify_on_connect(destination_hash)`. Called at link
    /// establishment with the node's destination hash; return `true` to reveal
    /// our identity to that node ("log in"). Nil / `false` → browse anonymously.
    /// Backed by a persisted per-node toggle in `NomadNetController`, so the
    /// answer is always fresh for whichever node is actually being contacted —
    /// correct for navigate, back/forward and reload alike (no pushed state).
    var shouldIdentify: ((Data) -> Bool)?

    /// How often to re-check `hasPath` while waiting for a path to resolve.
    private static let pathPollInterval: TimeInterval = 0.25

    /// Bumped on every `performRequest`. A pending path-wait poll compares
    /// against this and abandons itself if the user has since navigated
    /// elsewhere — so a late-resolving path can't clobber a newer page.
    private var currentGeneration = 0

    init(transport: Transport,
         identity: Identity? = nil,
         timeout: TimeInterval = NomadNetBrowser.defaultTimeout) {
        self.transport = transport
        self.appIdentity = identity
        super.init(timeout: timeout)
    }

    override func performRequest(_ url: NomadNetURL, fields: [String: String]) {
        currentGeneration += 1
        let generation = currentGeneration

        guard let transport else {
            onError?("Transport unavailable", url)
            return
        }

        let destHash = url.destinationHash

        if transport.hasPath(to: destHash) {
            establishAndRequest(url, fields: fields, destHash: destHash, transport: transport)
            return
        }

        // No cached path yet: ask for one and wait for it to arrive, instead of
        // erroring out immediately. Deadline mirrors Python's Browser.py:
        //   pr_time = now + first_hop_timeout(dest); fail when now > pr_time + timeout
        try? transport.requestPath(for: destHash)
        let deadline = Date().addingTimeInterval(transport.firstHopTimeout(for: destHash) + timeout)
        pollForPath(url, fields: fields, destHash: destHash, deadline: deadline, generation: generation)
    }

    /// Re-check for a resolved path on the main queue until it arrives (→ proceed)
    /// or the deadline passes (→ error). Self-cancels if superseded.
    private func pollForPath(_ url: NomadNetURL,
                             fields: [String: String],
                             destHash: Data,
                             deadline: Date,
                             generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pathPollInterval) { [weak self] in
            guard let self, generation == self.currentGeneration else { return }
            guard let transport = self.transport else {
                self.onError?("Transport unavailable", url)
                return
            }
            if transport.hasPath(to: destHash) {
                self.establishAndRequest(url, fields: fields, destHash: destHash, transport: transport)
            } else if Date() >= deadline {
                self.onError?("No path to destination", url)
            } else {
                self.pollForPath(url, fields: fields, destHash: destHash,
                                 deadline: deadline, generation: generation)
            }
        }
    }

    /// Recall the identity, build the destination, and run the link + page request.
    /// Only called once a path is known.
    private func establishAndRequest(_ url: NomadNetURL,
                                     fields: [String: String],
                                     destHash: Data,
                                     transport: Transport) {
        guard let remoteIdentity = Identity.recall(destinationHash: destHash) else {
            onError?("Destination not yet known — wait for announce", url)
            return
        }

        let dest: Destination
        do {
            dest = try Destination(
                identity: remoteIdentity,
                direction: .out,
                kind: .single,
                appName: "nomadnetwork",
                aspects: ["node"]
            )
        } catch {
            onError?("Failed to build destination: \(error.localizedDescription)", url)
            return
        }

        // Build the request data as an INLINE msgpack map and submit it via the
        // nativeValue overload — NOT encode()+data:, which re-wraps the already-packed
        // Data as a msgpack .bytes value (double-packing), so a Python NomadNet node
        // reads bytes instead of a dict and drops every field/var. See bugs/008.
        let requestValue = NomadNetBrowser.encodeValue(fields: fields, variables: url.variables) ?? .nil

        // One-shot latch shared by every terminal path (response / failure /
        // establishment timeout / link close). Ensures exactly one of them
        // surfaces a result, and — crucially — that tearing the link down after a
        // successful load does NOT make `onClosed` fire a spurious error over the
        // page the user just loaded.
        let concluded = ConclusionLatch()

        do {
            let link = try Link.initiate(destination: dest, transport: transport)
            link.onEstablished = { [weak self] l in
                guard let self else { return }
                // Identify to the node ONLY when the per-node toggle is set,
                // exactly like Python's Browser (which identifies solely when
                // `should_identify_on_connect(destination_hash)` is true) — never
                // unconditionally, or we'd leak the user's identity to every node
                // they browse. Best-effort: a node that doesn't require identity
                // still serves, and a genuine failure surfaces via the request path.
                if self.shouldIdentify?(destHash) == true, let identity = self.appIdentity {
                    try? l.identify(as: identity)
                }
                // Route a thrown request (e.g. the link went stale between
                // establishment and this call) to onError instead of swallowing it
                // with `try?` — otherwise no callback ever fires and the UI spins
                // forever with no feedback.
                do {
                    try l.request(
                        path: url.path,
                        nativeValue: requestValue,
                        responseCallback: { [weak self] data, _ in
                            guard concluded.claim() else { return }
                            self?.handleResponse(data, url: url)
                            try? l.teardown()
                        },
                        failedCallback: { [weak self] reason, _ in
                            guard concluded.claim() else { return }
                            self?.onError?(reason, url)
                            try? l.teardown()
                        },
                        timeout: timeout
                    )
                } catch {
                    guard concluded.claim() else { return }
                    self.onError?("Request failed: \(error.localizedDescription)", url)
                    try? l.teardown()
                }
            }
            link.onTimeout = { [weak self] _ in
                guard concluded.claim() else { return }
                self?.onError?("Link establishment timed out", url)
            }
            // Surface an unexpected link close (before a response concluded) as an
            // error rather than an endless spinner. The success/failure paths above
            // claim the latch before their own teardown, so a normal close is a no-op.
            link.onClosed = { [weak self] _ in
                guard concluded.claim() else { return }
                self?.onError?("Link closed before the page loaded", url)
            }
        } catch {
            onError?(error.localizedDescription, url)
        }
    }
}

/// Thread-safe one-shot latch: `claim()` returns `true` for exactly one caller,
/// `false` for every subsequent call. Lets several escaping link callbacks race
/// to conclude a page request while guaranteeing only the first one acts.
private final class ConclusionLatch {
    private var claimed = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
