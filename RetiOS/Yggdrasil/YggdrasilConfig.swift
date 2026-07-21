//
//  YggdrasilConfig.swift
//  RetiOS
//
//  The Yggdrasil node configuration (the JSON the embedded engine's StartJSON
//  consumes), wrapped as an editable dictionary. Trimmed adaptation of the
//  reference yggdrasil-ios `ConfigurationProxy` — no UIKit / share-sheet.
//
//  Config + keygen are produced by the engine itself (MobileGenerateConfigJSON)
//  so the private-key format is always exactly what yggdrasil-go expects. The
//  app persists the resulting JSON; the extension reads it back verbatim.
//
import Foundation
import Yggdrasil

/// An editable Yggdrasil node configuration.
final class YggdrasilConfig {
    /// The underlying config dictionary (JSON object). Mutated in place.
    private(set) var dict: [String: Any]

    /// Create a fresh configuration with a newly generated node key.
    /// - Parameter multicastEnabled: enable LAN peer discovery over IPv6
    ///   multicast. Off by default — it needs the multicast entitlement
    ///   (separate Apple approval). Internet peers work without it.
    init(multicastEnabled: Bool = false) {
        if let data = MobileGenerateConfigJSON(),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            dict = parsed
        } else {
            dict = [:]
        }
        normalize()
        setMulticastEnabled(multicastEnabled)
    }

    /// Rehydrate a configuration from previously-saved JSON.
    init?(json: Data) {
        guard let parsed = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            return nil
        }
        dict = parsed
        normalize()
    }

    /// Force the mobile-safe settings the extension requires, regardless of
    /// what was generated or previously stored. The system tunnel provides the
    /// TUN, so we never listen for inbound peerings and never bind an admin
    /// socket (the sandbox can't anyway).
    private func normalize() {
        dict["Listen"] = [String]()
        dict["AdminListen"] = "none"
    }

    // MARK: - Editable fields

    /// Yggdrasil peer URIs, e.g. "tls://host:port", "quic://host:port",
    /// "tcp://host:port". The node dials these to join the mesh.
    var peers: [String] {
        get { dict["Peers"] as? [String] ?? [] }
        set { dict["Peers"] = newValue }
    }

    /// Optional human-readable node name advertised in NodeInfo.
    var nodeName: String? {
        get { (dict["NodeInfo"] as? [String: Any])?["name"] as? String }
        set {
            var nodeInfo = dict["NodeInfo"] as? [String: Any] ?? [:]
            if let newValue, !newValue.isEmpty {
                nodeInfo["name"] = newValue
            } else {
                nodeInfo.removeValue(forKey: "name")
            }
            dict["NodeInfo"] = nodeInfo.isEmpty ? nil : nodeInfo
        }
    }

    /// Whether LAN multicast peer discovery is configured.
    var multicastEnabled: Bool {
        !((dict["MulticastInterfaces"] as? [[String: Any]]) ?? []).isEmpty
    }

    func setMulticastEnabled(_ enabled: Bool) {
        if enabled {
            if ((dict["MulticastInterfaces"] as? [[String: Any]]) ?? []).isEmpty {
                dict["MulticastInterfaces"] = [
                    ["Regex": "en.*", "Beacon": true, "Listen": true, "Password": ""],
                    ["Regex": "bridge.*", "Beacon": true, "Listen": true, "Password": ""],
                ]
            }
        } else {
            dict["MulticastInterfaces"] = [[String: Any]]()
        }
    }

    // MARK: - Derived identity

    /// The node's ed25519 public key in hex. yggdrasil-go stores PrivateKey as
    /// the 64-byte ed25519 key (32-byte seed ‖ 32-byte public key), so the
    /// public key is the trailing 32 bytes — derivable without the engine.
    var publicKeyHex: String? {
        guard let priv = dict["PrivateKey"] as? String, priv.count == 128 else { return nil }
        return String(priv.suffix(64))
    }

    // MARK: - Serialization

    func jsonData() -> Data? {
        try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }
}
