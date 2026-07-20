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

    /// How often to re-check `hasPath` while waiting for a path to resolve.
    private static let pathPollInterval: TimeInterval = 0.25

    /// Bumped on every `performRequest`. A pending path-wait poll compares
    /// against this and abandons itself if the user has since navigated
    /// elsewhere — so a late-resolving path can't clobber a newer page.
    private var currentGeneration = 0

    init(transport: Transport, timeout: TimeInterval = NomadNetBrowser.defaultTimeout) {
        self.transport = transport
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

        do {
            let link = try Link.initiate(destination: dest, transport: transport)
            link.onEstablished = { [weak self] l in
                guard let self else { return }
                try? l.request(
                    path: url.path,
                    nativeValue: requestValue,
                    responseCallback: { [weak self] data, _ in
                        self?.handleResponse(data, url: url)
                        try? l.teardown()
                    },
                    failedCallback: { [weak self] reason, _ in
                        self?.onError?(reason, url)
                        try? l.teardown()
                    },
                    timeout: timeout
                )
            }
            link.onTimeout = { [weak self] _ in
                self?.onError?("Link establishment timed out", url)
            }
        } catch {
            onError?(error.localizedDescription, url)
        }
    }
}
