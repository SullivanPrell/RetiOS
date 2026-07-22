import Foundation
import Observation
import Network
import SwiftData
import ReticulumSwift
import LXMF

/// Owns the Reticulum stack, LXMF router, and lifecycle for the app.
///
/// Platform strategy:
///   - iOS / iPadOS: always starts an embedded Reticulum instance with AutoInterface.
///   - macOS: probes port 37428 for an existing rnsd; if found, connects via
///     LocalInterface (client mode). If nothing is listening, starts embedded.
///
/// All other controllers receive transport/router after bringUp() completes.
@MainActor
@Observable
final class StackController {

    // MARK: - Saved interface model

    /// The wire-level interface type for a saved entry.
    /// Defaults to `.tcp` so existing persisted data (pre-multi-kind) decodes unchanged.
    enum SavedInterfaceKind: String, Codable {
        case tcp
        case backbone
        case yggdrasil  // TCP over an IPv6 Yggdrasil address — stored separately for icon/label
    }

    /// A user-added client interface whose config survives app restarts.
    struct SavedInterface: Codable, Identifiable {
        var id: String { name }
        let name: String
        let host: String
        let port: UInt16
        var kind: SavedInterfaceKind = .tcp

        init(name: String, host: String, port: UInt16, kind: SavedInterfaceKind = .tcp) {
            self.name = name
            self.host = host
            self.port = port
            self.kind = kind
        }

        enum CodingKeys: String, CodingKey { case name, host, port, kind }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            host = try c.decode(String.self, forKey: .host)
            port = try c.decode(UInt16.self, forKey: .port)
            kind = try c.decodeIfPresent(SavedInterfaceKind.self, forKey: .kind) ?? .tcp
        }
    }

    /// Configuration for an I2P interface that survives app restarts.
    struct SavedI2PConfig: Codable {
        var name: String
        /// b32 peer addresses (e.g. "abc123…xyz.b32.i2p")
        var peers: [String]
        var connectable: Bool

        init(name: String = "I2P", peers: [String] = [], connectable: Bool = false) {
            self.name = name
            self.peers = peers
            self.connectable = connectable
        }
    }

    /// Editable Yggdrasil node preferences that survive app restarts. The node's
    /// private key + full engine config live in the VPN profile (secure, not
    /// UserDefaults); this record only carries the UI-editable settings and the
    /// on/off flag. See `YggdrasilConfig` / `YggdrasilVPNManager`.
    struct SavedYggdrasilConfig: Codable {
        /// Whether the Yggdrasil node (system VPN packet tunnel) should run.
        var enabled: Bool
        /// Peer URIs to dial, e.g. "tls://host:port", "quic://host:port".
        var peers: [String]
        /// Optional node name advertised over the mesh.
        var nodeName: String
        /// LAN peer discovery over IPv6 multicast (needs the multicast entitlement).
        var multicastEnabled: Bool

        init(enabled: Bool = false, peers: [String] = [],
             nodeName: String = "", multicastEnabled: Bool = false) {
            self.enabled = enabled
            self.peers = peers
            self.nodeName = nodeName
            self.multicastEnabled = multicastEnabled
        }
    }

    /// All user-added interfaces that will be restored on next launch.
    private(set) var savedInterfaces: [SavedInterface] = []
    /// Saved I2P configuration (one I2PInterface, multiple peers).
    private(set) var savedI2PConfig: SavedI2PConfig?
    /// Saved Yggdrasil node preferences (system-VPN packet tunnel).
    private(set) var savedYggdrasilConfig: SavedYggdrasilConfig?
    /// Drives the Yggdrasil packet-tunnel extension and exposes live node status.
    /// Observe this directly for address / peer updates.
    let yggdrasilVPN = YggdrasilVPNManager()

    /// Bumped whenever `transport.interfaces` is mutated behind SwiftUI's back.
    ///
    /// `Transport` is not observable, so a view listing the live interfaces has
    /// nothing to depend on. Under `ObservableObject` this was a blanket
    /// `objectWillChange.send()`, which worked precisely *because* it was a
    /// firehose — it invalidated every observer regardless of what they read.
    /// `@Observable` has no equivalent: observers are notified only for the
    /// properties they actually touched. So the dependency has to be explicit —
    /// `InterfacesView` reads this counter alongside `transport.interfaces`.
    private(set) var interfacesRevision: Int = 0

    private static let savedInterfacesKey     = "savedTCPInterfaces"
    private static let savedI2PConfigKey       = "savedI2PConfig"
    private static let savedYggdrasilConfigKey = "savedYggdrasilConfig"
    private static let propagationNodeKey      = "propagationNodeHash"

    // MARK: - Stack state

    private(set) var isRunning = false
    /// Guards `bringUp` against re-entry (a second scene/window, or an
    /// interleaving at an `await`) starting a duplicate stack over this one.
    @ObservationIgnored private var isBringingUp = false
    private(set) var identity: Identity?
    private(set) var lxmfRouter: LXMRouter?
    /// True when we connected to an external rnsd rather than starting our own.
    private(set) var isClientMode = false
    /// Hex string of the configured LXMF outbound propagation node, if any.
    private(set) var propagationNodeHash: String?
    /// Live state of an inbound propagation-node sync (mirrors the router's
    /// state machine; polled while a sync runs since LXMRouter is not observable).
    private(set) var propagationSyncState: PropagationTransferState = .idle
    /// 0.0–1.0 progress of the current propagation sync.
    private(set) var propagationSyncProgress: Double = 0
    @ObservationIgnored private var syncPollTask: Task<Void, Never>?
    /// 16-byte hash of our lxmf.delivery destination (available after bringUp).
    private(set) var lxmfDeliveryHash: Data?
    /// Whether we actively announce our LXMF delivery address to the mesh.
    private(set) var lxmfAnnounceEnabled: Bool = {
        UserDefaults.standard.object(forKey: "lxmfAnnounceEnabled") as? Bool ?? true
    }()

    private(set) var reticulum: Reticulum?
    private(set) var transport: Transport?

    /// Human-readable name for this node, included in LXMF announces.
    /// Peers see this name instead of a raw hash in their peer lists.
    private(set) var nodeDisplayName: String = {
        UserDefaults.standard.string(forKey: "nodeDisplayName") ?? ""
    }()

    @ObservationIgnored private var peerAnnounceHandler: LXMFPeerAnnounceHandler?
    /// Coalesces inbound LXMF messages into batched SwiftData writes. Held so it
    /// outlives `bringUp` — the router's callback captures it.
    @ObservationIgnored private var messageIngest: LXMFMessageIngest?
    @ObservationIgnored private var notificationManager: NotificationManager?
    private static let lxmfAnnounceKey    = "lxmfAnnounceEnabled"
    private static let nodeDisplayNameKey = "nodeDisplayName"

    func bringUp(modelContext: ModelContext, notificationManager: NotificationManager? = nil) async {
        // Idempotent: never start a second stack over a running (or still
        // starting) one. @MainActor makes this check-and-set race-free.
        guard !isRunning, !isBringingUp else { return }
        isBringingUp = true
        defer { isBringingUp = false }

        self.notificationManager = notificationManager
        let storage = URL.documentsDirectory.appending(path: "reticulum", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)

        // Enable wire-compatible bz2 compression for Resource transfers. Without
        // this, `Resource.compressor` stays `NoCompressor`, whose `decompress`
        // returns nil — so any COMPRESSED resource sent by a Python peer (large
        // NomadNet pages, large LXMF messages, RRC resources — all of which
        // Python bz2-compresses) fails to assemble ("decompression failed"),
        // tearing down the link ("Link closed before the page loaded"). Small
        // single-packet responses are unaffected, which masked this. Set once,
        // before any resource activity; idempotent across bring-up retries.
        Resource.compressor = BZip2Compressor()

        let stack = Reticulum(configuration: .init(storagePath: storage))
        do {
            try stack.start()

            // Acquire the identity up front — before registering any interfaces
            // or starting the Yggdrasil tunnel. A failure here (e.g. a corrupt
            // on-disk identity file) would otherwise jump to `catch` with the
            // AutoInterface / saved gateways / I2P daemon / VPN already running
            // and no handle to stop them, leaving the app wedged at "Starting…".
            let id = try stack.loadOrCreateIdentity()

            #if os(macOS)
            let useDaemon = await StackController.probeLocalDaemon()
            #else
            let useDaemon = false
            #endif

            if useDaemon {
                let localIf = LocalInterface()
                stack.transport.register(interface: localIf)
                try localIf.start()
                isClientMode = true
                Reticulum.log("StackController: connected to existing rnsd via LocalInterface", level: .notice)
            } else {
                #if canImport(Darwin)
                let autoIf = AutoInterface(name: "AutoInterface")
                stack.transport.register(interface: autoIf)
                try autoIf.start()
                #endif
                isClientMode = false
                Reticulum.log("StackController: started embedded Reticulum with AutoInterface", level: .notice)
            }

            // Restore user-added client interfaces from previous sessions.
            loadSavedInterfaces()
            #if DEBUG
            // Integration-test hook (DEBUG-only, never compiled into Release):
            // reticulum_integration's `make mobile-verify` launches the app with
            // RETIOS_INTEROP_TCP=host:port so the stack dials a Python RNS
            // TCPServer running on the host, proving Python↔mobile reachability.
            seedInteropInterfaceFromEnvironment()
            #endif
            for saved in savedInterfaces {
                let iface: any Interface
                switch saved.kind {
                case .tcp, .yggdrasil:
                    iface = TCPClientInterface(name: saved.name, host: saved.host, port: saved.port)
                case .backbone:
                    iface = BackboneInterface(name: saved.name, host: saved.host, port: saved.port)
                }
                stack.transport.register(interface: iface)
                try? iface.start()
                Reticulum.log("StackController: restored saved interface '\(saved.name)'", level: .notice)
            }

            // Restore I2P configuration — requires CI2PD.xcframework.
            // After running build_ci2pd_ios.sh the guard below is extended to include iOS.
            loadSavedI2PConfig()
            #if os(macOS) || os(iOS)
            if let i2pConfig = savedI2PConfig, !i2pConfig.peers.isEmpty {
                let daemon   = I2PDaemon()
                let dataDir  = storage.appending(path: "i2pd", directoryHint: .isDirectory)
                let i2pIface = I2PInterface(name: i2pConfig.name,
                                            daemon: daemon,
                                            dataDirectory: dataDir,
                                            connectable: i2pConfig.connectable,
                                            peers: i2pConfig.peers)
                stack.transport.register(interface: i2pIface)
                try? i2pIface.start()
                Reticulum.log("StackController: restored I2P interface '\(i2pConfig.name)' with \(i2pConfig.peers.count) peer(s)", level: .notice)
            }
            #endif

            // Restore the Yggdrasil node (system-VPN packet tunnel). The engine
            // runs in the YggdrasilTunnel extension; here we discover any existing
            // VPN profile and (re)start it if the user left it enabled. Once the
            // tunnel is up the device carries a real Yggdrasil IPv6, and Reticulum
            // rides over it via ordinary TCP/Backbone interfaces pointed at
            // Yggdrasil addresses (the "Add Yggdrasil Peer" flow) — wire-compatible
            // with Python RNS-over-Yggdrasil nodes.
            #if os(macOS) || os(iOS)
            loadSavedYggdrasilConfig()
            await yggdrasilVPN.refreshManager()
            if let ygg = savedYggdrasilConfig, ygg.enabled {
                await startYggdrasilNode()
                Reticulum.log("StackController: (re)started Yggdrasil node with \(ygg.peers.count) peer(s)", level: .notice)
            }
            #endif

            let router = LXMRouter(transport: stack.transport)
            let lxmfPath = storage.appendingPathComponent("lxmf").path
            try? FileManager.default.createDirectory(atPath: lxmfPath, withIntermediateDirectories: true)
            router.storagePath = lxmfPath
            router.messagePath = lxmfPath

            let nameForAnnounce = nodeDisplayName.isEmpty ? nil : nodeDisplayName
            if let delivery = try? router.register(identity: id, transport: stack.transport,
                                                   displayName: nameForAnnounce) {
                lxmfDeliveryHash = delivery.hash
                if lxmfAnnounceEnabled {
                    try? router.announce(destinationHash: delivery.hash)
                }
            }

            // Restore previously-configured propagation node.
            if let savedHex = UserDefaults.standard.string(forKey: Self.propagationNodeKey),
               let data = Data(hexString: savedHex) {
                router.outboundPropagationNode = data
                propagationNodeHash = savedHex
            }

            // Wire inbound message receipt → coalesced SwiftData insert.
            //
            // The router delivers one callback per message from a transport
            // background thread, and a propagation-node sync replays the whole
            // offline backlog back-to-back. Writing (and saving) per message on
            // the main context re-ran every on-screen @Query per message, which
            // is what hung the UI during the sync that runs on every launch.
            // LXMFMessageIngest buffers off-actor and writes one batch per
            // window, mirroring LXMFPeerAnnounceHandler.
            let myHex = id.hash.map { String(format: "%02x", $0) }.joined()
            let ingest = LXMFMessageIngest(container: modelContext.container,
                                           myHash: myHex,
                                           notificationManager: notificationManager)
            self.messageIngest = ingest
            router.onMessageReceived = { message in
                ingest.enqueue(message)
            }

            // Register peer announce handler so the Peers tab fills in.
            // It coalesces announce bursts into a single batched save per second,
            // so heavy mesh traffic can't starve the UI / keyboard.
            let peerHandler = LXMFPeerAnnounceHandler(container: modelContext.container)
            stack.transport.register(announceHandler: peerHandler)
            self.peerAnnounceHandler = peerHandler

            self.identity = id
            self.lxmfRouter = router
            self.transport = stack.transport
            self.reticulum = stack
            self.isRunning = true

            #if DEBUG
            // Interop-test hook: when launched by `make mobile-verify`
            // (RETIOS_INTEROP_TCP set), re-announce LXMF a few times after
            // bring-up so the Python oracle reliably catches an announce once
            // the seeded TCP link finishes connecting — the single startup
            // announce above can race the link coming up. DEBUG-only, env-gated.
            if ProcessInfo.processInfo.environment["RETIOS_INTEROP_TCP"] != nil {
                Task { @MainActor [weak self] in
                    for _ in 0..<20 where !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        self?.announceLXMFNow()
                    }
                }
            }
            #endif
        } catch {
            Reticulum.log("StackController.bringUp failed: \(error)", level: .error)
            self.isRunning = false
            // Stop anything that started before the failure so interfaces and
            // the RNS instance don't leak, and a later retry can start clean.
            stack.stop()
        }
    }

    // MARK: - Interface persistence

    /// Persist a user-added client interface so it is restored next launch.
    func saveInterface(name: String, host: String, port: UInt16, kind: SavedInterfaceKind = .tcp) {
        // Single assignment avoids two separate objectWillChange notifications.
        var updated = savedInterfaces
        updated.removeAll { $0.name == name }
        updated.append(SavedInterface(name: name, host: host, port: port, kind: kind))
        savedInterfaces = updated
        persistSavedInterfaces()
    }

    /// Register and start a client interface of the given kind immediately,
    /// then persist it for restoration on next launch. Used by both the
    /// manual "Add TCP Gateway" sheet and the public-directory quick-add.
    func addAndSaveInterface(name: String, host: String, port: UInt16, kind: SavedInterfaceKind) throws {
        guard let transport else {
            throw StackError.notRunning
        }
        // Strip square brackets from IPv6 literals (e.g. "[2001:db8::1]" → "2001:db8::1").
        let normalizedHost = Self.normalizeHost(host)
        let iface: any Interface
        switch kind {
        case .tcp, .yggdrasil:
            iface = TCPClientInterface(name: name, host: normalizedHost, port: port)
        case .backbone:
            iface = BackboneInterface(name: name, host: normalizedHost, port: port)
        }
        transport.register(interface: iface)
        interfacesRevision &+= 1
        do {
            try iface.start()
            saveInterface(name: name, host: normalizedHost, port: port, kind: kind)
        } catch {
            transport.halt(interfaceName: name)
            throw error
        }
    }

    /// Strip RFC 2732 square brackets from IPv6 address literals.
    static func normalizeHost(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("[") && h.hasSuffix("]") {
            h = String(h.dropFirst().dropLast())
        }
        return h
    }

    // MARK: - I2P interface persistence

    /// Save (or replace) the I2P configuration and restart the I2P interface if the stack is running.
    func saveI2PConfig(_ config: SavedI2PConfig) {
        savedI2PConfig = config
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.savedI2PConfigKey)
        }
    }

    /// Remove the persisted I2P config and halt the running I2P interface (if any).
    func removeI2PConfig() {
        let ifaceName = savedI2PConfig?.name ?? "I2P"
        savedI2PConfig = nil
        UserDefaults.standard.removeObject(forKey: Self.savedI2PConfigKey)
        deregisterLiveInterface(named: ifaceName)
    }

    private func loadSavedI2PConfig() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedI2PConfigKey),
              let config = try? JSONDecoder().decode(SavedI2PConfig.self, from: data) else { return }
        savedI2PConfig = config
    }

    // MARK: - Yggdrasil node persistence

    /// Save the Yggdrasil node preferences and (re)start or stop the tunnel to
    /// match. Starting reuses the node's existing key from the VPN profile if one
    /// exists, so the node keeps its identity/address across edits and restarts.
    func saveYggdrasilConfig(_ config: SavedYggdrasilConfig) async {
        savedYggdrasilConfig = config
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.savedYggdrasilConfigKey)
        }
        if config.enabled {
            await startYggdrasilNode()
        } else {
            yggdrasilVPN.stopTunnel()
        }
    }

    /// Remove the persisted Yggdrasil preferences and delete the VPN profile
    /// (which also discards the node key).
    func removeYggdrasilConfig() async {
        savedYggdrasilConfig = nil
        UserDefaults.standard.removeObject(forKey: Self.savedYggdrasilConfigKey)
        await yggdrasilVPN.removeTunnel()
    }

    private func loadSavedYggdrasilConfig() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedYggdrasilConfigKey),
              let config = try? JSONDecoder().decode(SavedYggdrasilConfig.self, from: data) else { return }
        savedYggdrasilConfig = config
    }

    /// Build the engine config from the saved preferences (preserving the
    /// existing node key when a profile already exists) and start the tunnel.
    private func startYggdrasilNode() async {
        let saved = savedYggdrasilConfig ?? SavedYggdrasilConfig()

        // Make sure we've actually queried NetworkExtension before deciding
        // whether a profile (and thus a persisted node key) already exists.
        if !yggdrasilVPN.didLoadManagers {
            await yggdrasilVPN.refreshManager()
        }

        let config: YggdrasilConfig
        if let existing = yggdrasilVPN.loadSavedConfig() {
            // A profile exists and its config is readable — reuse it so the node
            // keeps its identity / IPv6 address across restarts.
            config = existing
        } else if yggdrasilVPN.didLoadManagers && !yggdrasilVPN.isConfigured {
            // We successfully queried NE and there is genuinely no profile: this
            // is a true first run, so mint a fresh key.
            config = YggdrasilConfig(multicastEnabled: saved.multicastEnabled)
        } else {
            // Either NE couldn't be queried, or a profile exists but its config
            // is unreadable. Do NOT generate a new key — that would silently
            // change the node's identity/address and break peers keyed to it.
            // Fail closed and surface the error instead.
            let detail = yggdrasilVPN.lastError.map { " (\($0))" } ?? ""
            Reticulum.log("StackController: Yggdrasil profile unreadable — not regenerating node key\(detail)", level: .error)
            return
        }

        config.peers = saved.peers
        config.nodeName = saved.nodeName.isEmpty ? nil : saved.nodeName
        config.setMulticastEnabled(saved.multicastEnabled)
        await yggdrasilVPN.startTunnel(with: config)
    }

    enum StackError: LocalizedError {
        case notRunning
        var errorDescription: String? {
            switch self {
            case .notRunning: return "Stack is not running yet."
            }
        }
    }

    /// Remove a user-added interface: fully tears it down for the current session
    /// and removes it from persistence so it is not restored next launch.
    func removeInterface(named name: String) {
        savedInterfaces.removeAll { $0.name == name }
        persistSavedInterfaces()
        deregisterLiveInterface(named: name)
    }

    /// Stop a live interface *and* remove it from `transport.interfaces`.
    ///
    /// This replaced a bare `transport.halt(interfaceName:)`, which — by design,
    /// mirroring Python's `halt_interface` — only stops the interface but leaves
    /// it *registered*. The Interfaces screen lists the live `transport.interfaces`,
    /// so a halted-but-still-registered interface never left the list and its
    /// "Remove" action (gated on `isSaved`, which we've just cleared) also
    /// vanished: that was the "interface delete does nothing" bug, identical on
    /// iOS and macOS because this is shared code. `Transport` is not an
    /// `ObservableObject`, so mutating `interfaces` won't refresh SwiftUI on its
    /// own — hence the explicit `interfacesRevision` bump.
    private func deregisterLiveInterface(named name: String) {
        guard let transport,
              let iface = transport.interfaces.first(where: { $0.name == name }) else { return }
        iface.stop()
        transport.deregister(interface: iface)
        interfacesRevision &+= 1
    }

    /// Register a newly built interface with the live transport, keeping the
    /// Interfaces screen in sync. Every path that adds to `transport.interfaces`
    /// must go through here (or call `noteInterfacesChanged()`) — see the
    /// property's note on why an implicit refresh no longer exists.
    func registerLiveInterface(_ iface: any Interface) {
        transport?.register(interface: iface)
        interfacesRevision &+= 1
    }

    /// Signal that `transport.interfaces` changed by a route that owns its own
    /// registration (BLE Mesh and RNode each build and register their interface
    /// from their own controller). Without this the Interfaces screen keeps
    /// showing a stale Active list until the user navigates away and back:
    /// enabling BLE Mesh adds a live interface the list never shows, and
    /// disabling it leaves a ghost row.
    func noteInterfacesChanged() {
        interfacesRevision &+= 1
    }

    private func loadSavedInterfaces() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedInterfacesKey),
              let saved = try? JSONDecoder().decode([SavedInterface].self, from: data) else { return }
        savedInterfaces = saved
    }

    #if DEBUG
    /// Integration-test hook: if `RETIOS_INTEROP_TCP` (e.g. "127.0.0.1:4242") is
    /// present in the environment, add a transient TCP client interface dialing
    /// that host so `bringUp` connects to a Python RNS TCPServer. Not persisted
    /// (kept out of UserDefaults) and DEBUG-only, so it never affects Release
    /// builds or a user's saved interfaces. Host must be IPv4/hostname (the
    /// last ':' separates the port — bracketless IPv6 is intentionally unsupported).
    private func seedInteropInterfaceFromEnvironment() {
        guard let spec = ProcessInfo.processInfo.environment["RETIOS_INTEROP_TCP"],
              let sep = spec.lastIndex(of: ":") else { return }
        let host = String(spec[spec.startIndex..<sep])
        guard !host.isEmpty, let port = UInt16(spec[spec.index(after: sep)...]) else { return }
        guard !savedInterfaces.contains(where: { $0.host == host && $0.port == port }) else { return }
        savedInterfaces.append(SavedInterface(name: "Interop TCP", host: host, port: port, kind: .tcp))
        Reticulum.log("StackController: seeded interop TCP interface \(host):\(port) from RETIOS_INTEROP_TCP", level: .notice)
    }
    #endif

    private func persistSavedInterfaces() {
        if let data = try? JSONEncoder().encode(savedInterfaces) {
            UserDefaults.standard.set(data, forKey: Self.savedInterfacesKey)
        }
    }

    // MARK: - Announce

    /// Toggle LXMF address announce and persist the choice.
    /// When turning on, immediately sends an announce so peers learn the address right away.
    func setLXMFAnnounce(_ enabled: Bool) {
        lxmfAnnounceEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.lxmfAnnounceKey)
        if enabled, let hash = lxmfDeliveryHash {
            try? lxmfRouter?.announce(destinationHash: hash)
        }
    }

    /// Send an immediate LXMF announce regardless of the persisted toggle state.
    func announceLXMFNow() {
        guard let hash = lxmfDeliveryHash else { return }
        try? lxmfRouter?.announce(destinationHash: hash)
        Reticulum.log("StackController: ad-hoc LXMF announce sent", level: .notice)
    }

    /// Update the display name sent in LXMF announces and persist the choice.
    /// An immediate re-announce is sent so peers see the new name right away.
    func setNodeDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        nodeDisplayName = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.nodeDisplayNameKey)

        // Update the router's cached name so the next announce app data includes it.
        if let hash = lxmfDeliveryHash {
            lxmfRouter?.setDisplayName(trimmed.isEmpty ? nil : trimmed,
                                       forDestinationHash: hash)
            // Re-announce immediately so the mesh reflects the change.
            if lxmfAnnounceEnabled {
                try? lxmfRouter?.announce(destinationHash: hash)
            }
        }
    }

    // MARK: - Lifecycle

    func tearDown() {
        reticulum?.stop()
        isRunning = false
    }

    /// Set or clear the LXMF outbound propagation node.
    /// Pass a 32-character hex string to configure a node, or `nil` to clear.
    func setPropagationNode(_ hex: String?) {
        guard let router = lxmfRouter else { return }
        if let hex, !hex.isEmpty {
            let clean = String(hex.filter { $0.isHexDigit }.prefix(32))
            guard clean.count == 32, let data = Data(hexString: clean) else { return }
            router.outboundPropagationNode = data
            propagationNodeHash = clean
            UserDefaults.standard.set(clean, forKey: Self.propagationNodeKey)
        } else {
            router.outboundPropagationNode = nil
            propagationNodeHash = nil
            UserDefaults.standard.removeObject(forKey: Self.propagationNodeKey)
        }
    }

    // MARK: - Propagation node sync

    /// Request any messages held for us by the configured propagation node
    /// (store-and-forward "post box" retrieval). Safe to call repeatedly;
    /// no-ops if no node is configured or a sync is already running.
    func syncFromPropagationNode() {
        guard let router = lxmfRouter, let identity,
              router.outboundPropagationNode != nil else { return }
        guard propagationSyncState == .idle
                || propagationSyncState == .done
                || propagationSyncState == .failed else { return }
        router.requestMessagesFromPropagationNode(identity: identity)
        Reticulum.log("StackController: propagation node sync requested", level: .notice)
        startSyncPolling()
    }

    /// Cancel an in-progress propagation sync.
    func cancelPropagationSync() {
        lxmfRouter?.cancelPropagationNodeRequests()
        syncPollTask?.cancel()
        syncPollTask = nil
        propagationSyncState = .idle
        propagationSyncProgress = 0
    }

    /// Mirror the router's (non-observable) transfer state into /// properties twice a second until the sync reaches a terminal state.
    private func startSyncPolling() {
        syncPollTask?.cancel()
        syncPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let router = self.lxmfRouter else { return }
                // Assign only on change: notifies on every assignment,
                // equal or not, so writing both unconditionally invalidated every
                // observing view twice a second for the whole sync.
                let state    = router.propagationTransferState
                let progress = router.propagationTransferProgress
                if self.propagationSyncState != state { self.propagationSyncState = state }
                if self.propagationSyncProgress != progress { self.propagationSyncProgress = progress }
                if state == .done || state == .failed {
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    enum SendError: Error, LocalizedError {
        case unknownPeer
        var errorDescription: String? {
            "This peer's keys aren't known yet. They've been requested from the network — try again in a moment."
        }
    }

    // MARK: - Send

    /// Enqueue an outbound LXMF message and record it in SwiftData.
    /// Fails if the peer's identity has not been seen yet (no announce received).
    func send(content: String, title: String = "", to peerHash: Data,
              context: ModelContext) throws {
        // Throw rather than silently return: a bare `return` here made the
        // compose UI report success even though nothing was sent (stack not up).
        guard let router = lxmfRouter, let identity = identity else {
            throw StackError.notRunning
        }

        // Recall peer identity from the Transport announce store. If it isn't
        // known yet, request a path so the identity can be resolved from the
        // network (a shared-instance rnsd will answer with a path response),
        // then fail this attempt — a retry after the response arrives succeeds.
        // Mirrors NomadNet's Conversation.send(), which now calls
        // RNS.Transport.request_path(...) on an unknown destination instead of
        // silently giving up.
        guard let peerIdentity = Identity.recall(destinationHash: peerHash) else {
            try? transport?.requestPath(for: peerHash)
            throw SendError.unknownPeer
        }
        let source = try Destination(identity: identity, direction: .in,
                                     kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dest = try Destination(identity: peerIdentity, direction: .in,
                                   kind: .single, appName: "lxmf", aspects: ["delivery"])
        let msg = LXMessage(destination: dest, source: source,
                            content: content, title: title)

        let myHex = identity.hash.map { String(format: "%02x", $0) }.joined()
        let peerHex = peerHash.map { String(format: "%02x", $0) }.joined()
        let msgHashStr = msg.hash?.map { String(format: "%02x", $0) }.joined() ?? UUID().uuidString
        let entity = MessageEntity(
            messageHash: msgHashStr,
            conversationHash: peerHex,
            senderHash: myHex,
            recipientHash: peerHex,
            title: title,
            content: content,
            timestamp: Date(timeIntervalSince1970: msg.timestamp ?? Date().timeIntervalSince1970),
            isOutbound: true,
            deliveryState: Int16(LXMessage.State.outbound.rawValue)
        )
        context.insert(entity)
        try? context.save()

        msg.onDelivery = { [weak self] delivered in
            Task { @MainActor [weak self] in
                self?.updateDeliveryState(messageHash: msgHashStr,
                                          state: delivered.state,
                                          context: context)
            }
        }

        try router.send(msg)
    }

    // MARK: - Private helpers

    private func updateDeliveryState(messageHash: String, state: LXMessage.State, context: ModelContext) {
        let descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.messageHash == messageHash }
        )
        guard let entity = try? context.fetch(descriptor).first else { return }
        entity.deliveryState = Int16(state.rawValue)
        try? context.save()
    }

    // Inbound message persistence moved to `LXMFMessageIngest`, which coalesces
    // a burst (e.g. a propagation-node backlog replay) into one batched write
    // instead of one fetch + insert + save — and therefore one full @Query
    // re-run — per message.

    // MARK: - macOS daemon probe

    #if os(macOS)
    private static func probeLocalDaemon(port: UInt16 = 37428) async -> Bool {
        await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: port)!
            )
            let conn = NWConnection(to: endpoint, using: .tcp)
            let q = DispatchQueue(label: "RetiOS.daemonProbe")
            var resolved = false

            conn.stateUpdateHandler = { state in
                guard !resolved else { return }
                switch state {
                case .ready:
                    resolved = true
                    conn.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    resolved = true
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            q.asyncAfter(deadline: .now() + 1.0) {
                guard !resolved else { return }
                resolved = true
                conn.cancel()
                continuation.resume(returning: false)
            }
            conn.start(queue: q)
        }
    }
    #endif
}

// MARK: - Hex helper

private extension Data {
    init?(hexString: String) {
        let hex = hexString.filter { $0.isHexDigit }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        self = data
    }
}
