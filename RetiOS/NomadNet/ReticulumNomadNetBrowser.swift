import Foundation
import ReticulumSwift
import NomadNet

/// Production NomadNetBrowser subclass that performs real page requests
/// over live RNS Links.
///
/// Protocol (mirrors Python Browser.request_page):
///   1. Check transport has a path to the destination hash.
///   2. Request path if missing and return an error (caller retries).
///   3. Recall the remote identity, build an outbound Destination.
///   4. Initiate a Link; on established, call link.request(path:data:).
///   5. Hand response bytes to handleResponse(_:url:) for Micron parsing.
final class ReticulumNomadNetBrowser: NomadNetBrowser {

    private weak var transport: Transport?

    init(transport: Transport, timeout: TimeInterval = NomadNetBrowser.defaultTimeout) {
        self.transport = transport
        super.init(timeout: timeout)
    }

    override func performRequest(_ url: NomadNetURL, fields: [String: String]) {
        guard let transport else {
            onError?("Transport unavailable", url)
            return
        }

        let destHash = url.destinationHash

        guard transport.hasPath(to: destHash) else {
            try? transport.requestPath(for: destHash)
            onError?("No path to destination — retrying path request", url)
            return
        }

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

        let encodedFields = NomadNetBrowser.encode(fields: fields, variables: url.variables)

        do {
            let link = try Link.initiate(destination: dest, transport: transport)
            link.onEstablished = { [weak self] l in
                guard let self else { return }
                try? l.request(
                    path: url.path,
                    data: encodedFields,
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
