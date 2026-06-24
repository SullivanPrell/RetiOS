import Foundation

/// Read-only client for the public Reticulum interface directory at
/// https://directory.rns.recipes — lets users discover and quick-add
/// community-run gateways without typing a host/port by hand.
enum InterfaceDirectory {
    struct Entry: Codable, Identifiable, Hashable {
        let id: Int
        let name: String
        let type: String
        let typeName: String
        let network: String
        let host: String
        let port: Int?
        let status: String
    }

    private struct Response: Codable { let data: [Entry] }

    private static let submittedURL = URL(string: "https://directory.rns.recipes/api/directory/submitted")!

    /// Fetches the currently-online, community-submitted directory entries.
    static func fetchOnline() async throws -> [Entry] {
        var components = URLComponents(url: submittedURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "status", value: "online")]
        guard let url = components.url else { throw URLError(.badURL) }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data).data
    }
}

extension InterfaceDirectory.Entry {
    /// RetiOS can only quick-connect to host:port style gateways — RNode, Serial,
    /// I2P, KISS etc. require local hardware or daemons this directory can't configure.
    var isQuickAddable: Bool {
        savedKind != nil && port != nil
    }

    var savedKind: StackController.SavedInterfaceKind? {
        // Yggdrasil gateways are ordinary TCP/Backbone links to an IPv6
        // Yggdrasil address — the API reports that in `network`, never `type`.
        // Tag them `.yggdrasil` so the app shows the right icon/label; they're
        // still added as a TCP/Backbone interface under the hood.
        if network == "yggdrasil" {
            switch type {
            case "tcp", "backbone": return .yggdrasil
            default:                return nil
            }
        }
        switch type {
        case "tcp":      return .tcp
        case "backbone": return .backbone
        default:         return nil   // i2p and others need local config — not quick-addable
        }
    }

    var hostPort: String {
        if let port { return "\(host):\(port)" }
        return host
    }

    /// Human-readable short label for the type badge (API's `typeName` is a full class name).
    var typeLabel: String {
        switch type {
        case "tcp":        return "TCP"
        case "backbone":   return "Backbone"
        case "yggdrasil":  return "Yggdrasil"
        default:           return type.capitalized
        }
    }
}
