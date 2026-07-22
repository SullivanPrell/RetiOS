//
//  YggdrasilVPNManager.swift
//  RetiOS
//
//  Drives the YggdrasilTunnel packet-tunnel extension: creates/updates the VPN
//  profile that carries the node config, starts/stops the tunnel, and polls the
//  running engine over the NE IPC channel for live status (address, subnet,
//  public key, peers). Adapted from the reference yggdrasil-ios
//  CrossPlatformAppDelegate into a SwiftUI-friendly ObservableObject.
//
import Foundation
import Observation
import NetworkExtension
import Combine

/// A single Yggdrasil peer as reported by the engine's GetPeersJSON.
struct YggdrasilPeerInfo: Identifiable {
    let id = UUID()
    let uri: String
    let up: Bool
    let address: String?
    let uptimeSeconds: Double?

    init?(json: [String: Any]) {
        guard let uri = json["URI"] as? String else { return nil }
        self.uri = uri
        self.up = json["Up"] as? Bool ?? false
        self.address = json["IP"] as? String
        self.uptimeSeconds = (json["Uptime"] as? NSNumber)?.doubleValue
    }
}

@MainActor
@Observable
final class YggdrasilVPNManager {
    /// Must match the extension target's bundle identifier (project.yml).
    static let extensionBundleID = "dev.sprell.retios.YggdrasilTunnel"

    enum Status: String {
        case disconnected, connecting, connected, disconnecting, reasserting, invalid

        init(_ vpn: NEVPNStatus) {
            switch vpn {
            case .connected: self = .connected
            case .connecting: self = .connecting
            case .disconnecting: self = .disconnecting
            case .reasserting: self = .reasserting
            case .invalid: self = .invalid
            case .disconnected: self = .disconnected
            @unknown default: self = .disconnected
            }
        }

        var isActive: Bool { self == .connected || self == .connecting || self == .reasserting }
    }

    private(set) var status: Status = .disconnected
    private(set) var nodeAddress: String?
    private(set) var nodeSubnet: String?
    private(set) var publicKey: String?
    private(set) var peers: [YggdrasilPeerInfo] = []
    private(set) var lastError: String?
    /// True once we have located (or created) the VPN profile.
    private(set) var isConfigured: Bool = false
    /// True once a `NETunnelProviderManager.loadAllFromPreferences()` has
    /// succeeded this session. Distinguishes "queried NE, genuinely no profile"
    /// from "couldn't query NE" — the caller must not mint a new node key in the
    /// latter case (it would change the node identity). See StackController.
    private(set) var didLoadManagers: Bool = false

    @ObservationIgnored private var manager: NETunnelProviderManager?
    @ObservationIgnored private var statusObserver: NSObjectProtocol?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let conn = note.object as? NEVPNConnection else { return }
            // Delivered on the main queue (queue: .main), so we are already on
            // the main actor — assert it to touch main-actor state synchronously.
            MainActor.assumeIsolated {
                guard let self, conn === self.manager?.connection else { return }
                self.handleStatusChange(conn.status)
            }
        }
    }

    deinit {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
    }

    // MARK: - Discovery

    /// Locate an existing RetiOS Yggdrasil VPN profile, if any.
    func refreshManager() async {
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            self.didLoadManagers = true
            // A previous transient failure (e.g. Simulator "IPC failed") must
            // not leave a stale red error banner once a refresh succeeds.
            self.lastError = nil
            let found = all.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == Self.extensionBundleID
            }
            self.manager = found
            self.isConfigured = found != nil
            if let conn = found?.connection {
                handleStatusChange(conn.status)
            }
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// The persisted config JSON, if a profile exists (so the UI can restore
    /// the peer list into the editor).
    func loadSavedConfig() -> YggdrasilConfig? {
        guard let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol,
              let json = proto.providerConfiguration?["json"] as? Data else { return nil }
        return YggdrasilConfig(json: json)
    }

    // MARK: - Apply / start / stop

    /// Create or update the VPN profile with `config`, then start the tunnel.
    func startTunnel(with config: YggdrasilConfig) async {
        lastError = nil
        guard let json = config.jsonData() else {
            lastError = "Could not serialize Yggdrasil configuration."
            return
        }

        let manager = self.manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.extensionBundleID
        proto.providerConfiguration = ["json": json]
        proto.serverAddress = "Yggdrasil"
        proto.username = config.publicKeyHex ?? "yggdrasil"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Yggdrasil (RetiOS)"
        manager.isEnabled = true

        do {
            try await manager.saveToPreferences()
            // Reload after save — starting immediately off a freshly-saved
            // manager throws "configuration is invalid" (a documented NE quirk).
            try await manager.loadFromPreferences()
            self.manager = manager
            self.isConfigured = true
            self.publicKey = config.publicKeyHex
            try manager.connection.startVPNTunnel()
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// Stop the tunnel but keep the profile (so it can be restarted).
    func stopTunnel() {
        manager?.connection.stopVPNTunnel()
    }

    /// Stop and delete the VPN profile entirely.
    func removeTunnel() async {
        manager?.connection.stopVPNTunnel()
        do {
            try await manager?.removeFromPreferences()
        } catch {
            self.lastError = error.localizedDescription
        }
        manager = nil
        isConfigured = false
        clearStatus()
    }

    // MARK: - Status + IPC polling

    private func handleStatusChange(_ vpn: NEVPNStatus) {
        status = Status(vpn)
        switch status {
        case .connected:
            startPolling()
        case .disconnected, .disconnecting, .invalid:
            stopPolling()
            clearStatus()
        default:
            break
        }
    }

    private func startPolling() {
        // Cancel any prior loop first rather than early-returning on a non-nil
        // task: a previously stuck/finishing loop must not leave two loops
        // running (or block a restart) after a tunnel flap.
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() async {
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected else { return }
        if let addr = await sendMessage("address", on: session) {
            nodeAddress = String(data: addr, encoding: .utf8)
        }
        if let subnet = await sendMessage("subnet", on: session) {
            nodeSubnet = String(data: subnet, encoding: .utf8)
        }
        if let pk = await sendMessage("publickey", on: session),
           let s = String(data: pk, encoding: .utf8), !s.isEmpty {
            publicKey = s
        }
        if let peersData = await sendMessage("peers", on: session),
           let arr = (try? JSONSerialization.jsonObject(with: peersData)) as? [[String: Any]] {
            peers = arr.compactMap(YggdrasilPeerInfo.init(json:))
        }
    }

    /// Ask the extension to dial its peers immediately.
    func retryPeers() {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        try? session.sendProviderMessage("retry".data(using: .utf8)!, responseHandler: nil)
    }

    private func sendMessage(_ command: String, on session: NETunnelProviderSession) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let responder = IPCResponder(cont)
            // NE gives no delivery guarantee: if the extension is jetsammed after
            // the message is queued but before it replies, the response handler
            // may never fire. Resume with nil after a timeout so the poll loop
            // can never hang on an un-resumable continuation.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                responder.finish(nil)
            }
            do {
                try session.sendProviderMessage(command.data(using: .utf8)!) { response in
                    Task { @MainActor in responder.finish(response) }
                }
            } catch {
                responder.finish(nil)
            }
        }
    }

    /// One-shot resume guard for an IPC continuation. Main-actor isolated (hence
    /// implicitly Sendable) so the timeout and the response race resume it
    /// exactly once.
    @MainActor
    private final class IPCResponder {
        @ObservationIgnored private var continuation: CheckedContinuation<Data?, Never>?
        init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }
        func finish(_ value: Data?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    private func clearStatus() {
        nodeAddress = nil
        nodeSubnet = nil
        peers = []
    }
}
