//
//  PacketTunnelProvider.swift
//  YggdrasilTunnel — RetiOS's Yggdrasil network extension.
//
//  Runs the embedded yggdrasil-go engine (Yggdrasil.xcframework) inside a
//  Packet Tunnel Provider so the device gains a real Yggdrasil IPv6 presence
//  (split-tunnel, 0200::/7 only — normal traffic is untouched). RetiOS's
//  Reticulum stack then rides over that IPv6 exactly like any TCP/Backbone
//  interface — wire-compatible with Python RNS-over-Yggdrasil nodes.
//
//  Ported from the official yggdrasil-network/yggdrasil-ios PacketTunnelProvider
//  (BSD/MIT), adapted for RetiOS: the extension reads the config JSON straight
//  from the VPN profile's providerConfiguration and hands it to the engine.
//
import NetworkExtension
import Foundation
import Yggdrasil

class PacketTunnelProvider: NEPacketTunnelProvider {

    /// The embedded yggdrasil-go node (gomobile-bound).
    private var yggdrasil = MobileYggdrasil()

    // MARK: - Tunnel lifecycle

    override func startTunnel(options: [String: NSObject]?,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfiguration = proto.providerConfiguration,
              let configJSON = providerConfiguration["json"] as? Data else {
            NSLog("YggdrasilTunnel: missing provider configuration JSON")
            completionHandler(YggdrasilTunnelError.missingConfiguration)
            return
        }

        // 1. Boot the Go node from the JSON config. The config disables the OS
        //    TUN (IfName none/dummy), so the engine creates only its userspace
        //    IPv6 layer — we hand it the real utun fd below via takeOverTUN().
        do {
            try yggdrasil.startJSON(configJSON)
        } catch {
            NSLog("YggdrasilTunnel: startJSON error: \(error.localizedDescription)")
            completionHandler(error)
            return
        }

        let address = yggdrasil.getAddressString()
        let subnet = yggdrasil.getSubnetString()
        NSLog("YggdrasilTunnel: node IPv6 \(address), subnet \(subnet)")

        // 2. Route only the Yggdrasil range (0200::/7) through this tunnel —
        //    a split tunnel, so normal device traffic is untouched.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: address)
        let ipv6 = NEIPv6Settings(addresses: [address], networkPrefixLengths: [7])
        ipv6.includedRoutes = [NEIPv6Route(destinationAddress: "0200::", networkPrefixLength: 7)]
        settings.ipv6Settings = ipv6
        settings.mtu = NSNumber(value: yggdrasil.getMTU())

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { completionHandler(nil); return }
            if let error {
                NSLog("YggdrasilTunnel: setTunnelNetworkSettings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            // 3. Hand the live utun file descriptor to the engine so it
            //    reads/writes IPv6 packets on the system tunnel directly.
            guard let fd = self.tunnelFileDescriptor else {
                NSLog("YggdrasilTunnel: could not locate utun file descriptor")
                completionHandler(YggdrasilTunnelError.tunnelFileDescriptorNotFound)
                return
            }
            do {
                try self.yggdrasil.takeOverTUN(fd)
                NSLog("YggdrasilTunnel: started")
                completionHandler(nil)
            } catch {
                NSLog("YggdrasilTunnel: takeOverTUN failed: \(error.localizedDescription)")
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        NSLog("YggdrasilTunnel: stopping (reason \(reason.rawValue))")
        try? yggdrasil.stop()
        super.stopTunnel(with: reason, completionHandler: completionHandler)
    }

    // MARK: - Status IPC (app ⇄ extension)

    override func handleAppMessage(_ messageData: Data,
                                   completionHandler: ((Data?) -> Void)? = nil) {
        let request = String(data: messageData, encoding: .utf8)
        switch request {
        case "address":
            completionHandler?(yggdrasil.getAddressString().data(using: .utf8))
        case "subnet":
            completionHandler?(yggdrasil.getSubnetString().data(using: .utf8))
        case "publickey":
            completionHandler?(yggdrasil.getPublicKeyString().data(using: .utf8))
        case "peers":
            completionHandler?(yggdrasil.getPeersJSON().data(using: .utf8))
        case "retry":
            yggdrasil.retryPeersNow()
            completionHandler?("ok".data(using: .utf8))
        default:
            completionHandler?(nil)
        }
    }
}

enum YggdrasilTunnelError: LocalizedError {
    case missingConfiguration
    case tunnelFileDescriptorNotFound

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Yggdrasil tunnel configuration was missing or invalid."
        case .tunnelFileDescriptorNotFound:
            return "Could not obtain the tunnel file descriptor from the system."
        }
    }
}
