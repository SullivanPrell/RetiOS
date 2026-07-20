import Foundation
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
final class StackController: ObservableObject {

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

    // GPL BOUNDARY: MeshCore support links the GPL-3.0 RNSOverMeshCore package and
    // is compiled only into the `RetiOS-MeshCore` target (which defines MESHCORE).
    // The clean `RetiOS` (App Store) target excludes it entirely. See project.yml
    // and docs/MESHCORE_BUILD.md.
    #if MESHCORE
    /// Configuration for a MeshCore (RNS-over-MeshCore) interface that survives app
    /// restarts. Persists the channel settings (so the form is pre-filled) and the
    /// last companion device UUID; the BLE connection itself is re-established via
    /// the MeshCore scanner (companion links are not auto-reconnected on launch yet).
    struct SavedMeshCoreConfig: Codable {
        var name: String
        var channelName: String
        var channelSecretHex: String
        var channelIndex: Int
        var accessPoint: Bool
        var canRoute: Bool
        var deviceUUID: String?

        init(name: String = "MeshCore", channelName: String = "RNSTunnel",
             channelSecretHex: String = "", channelIndex: Int = 0,
             accessPoint: Bool = true, canRoute: Bool = true, deviceUUID: String? = nil) {
            self.name = name
            self.channelName = channelName
            self.channelSecretHex = channelSecretHex
            self.channelIndex = channelIndex
            self.accessPoint = accessPoint
            self.canRoute = canRoute
            self.deviceUUID = deviceUUID
        }
    }
    #endif

    /// All user-added interfaces that will be restored on next launch.
    @Published private(set) var savedInterfaces: [SavedInterface] = []
    /// Saved I2P configuration (one I2PInterface, multiple peers).
    @Published private(set) var savedI2PConfig: SavedI2PConfig?
    #if MESHCORE
    /// Saved MeshCore configuration (channel settings + last companion device).
    @Published private(set) var savedMeshCoreConfig: SavedMeshCoreConfig?
    #endif

    private static let savedInterfacesKey  = "savedTCPInterfaces"
    private static let savedI2PConfigKey   = "savedI2PConfig"
    #if MESHCORE
    private static let savedMeshCoreKey    = "savedMeshCoreConfig"
    #endif
    private static let propagationNodeKey  = "propagationNodeHash"

    // MARK: - Stack state

    @Published private(set) var isRunning = false
    @Published private(set) var identity: Identity?
    @Published private(set) var lxmfRouter: LXMRouter?
    /// True when we connected to an external rnsd rather than starting our own.
    @Published private(set) var isClientMode = false
    /// Hex string of the configured LXMF outbound propagation node, if any.
    @Published private(set) var propagationNodeHash: String?
    /// Live state of an inbound propagation-node sync (mirrors the router's
    /// state machine; polled while a sync runs since LXMRouter is not observable).
    @Published private(set) var propagationSyncState: PropagationTransferState = .idle
    /// 0.0–1.0 progress of the current propagation sync.
    @Published private(set) var propagationSyncProgress: Double = 0
    private var syncPollTask: Task<Void, Never>?
    /// 16-byte hash of our lxmf.delivery destination (available after bringUp).
    @Published private(set) var lxmfDeliveryHash: Data?
    /// Whether we actively announce our LXMF delivery address to the mesh.
    @Published private(set) var lxmfAnnounceEnabled: Bool = {
        UserDefaults.standard.object(forKey: "lxmfAnnounceEnabled") as? Bool ?? true
    }()

    private(set) var reticulum: Reticulum?
    private(set) var transport: Transport?

    /// Human-readable name for this node, included in LXMF announces.
    /// Peers see this name instead of a raw hash in their peer lists.
    @Published private(set) var nodeDisplayName: String = {
        UserDefaults.standard.string(forKey: "nodeDisplayName") ?? ""
    }()

    private var peerAnnounceHandler: LXMFPeerAnnounceHandler?
    private var notificationManager: NotificationManager?
    private static let lxmfAnnounceKey    = "lxmfAnnounceEnabled"
    private static let nodeDisplayNameKey = "nodeDisplayName"

    func bringUp(modelContext: ModelContext, notificationManager: NotificationManager? = nil) async {
        self.notificationManager = notificationManager
        let storage = URL.documentsDirectory.appending(path: "reticulum", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)

        let stack = Reticulum(configuration: .init(storagePath: storage))
        do {
            try stack.start()

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

            #if MESHCORE
            // Load the saved MeshCore channel config so the scanner form is
            // pre-filled. The BLE companion link is re-established interactively via
            // the MeshCore scanner (auto-reconnect on launch is a follow-up).
            loadSavedMeshCoreConfig()
            #endif

            let id = try stack.loadOrCreateIdentity()

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

            // Wire inbound message receipt → SwiftData insert.
            let myHex = id.hash.map { String(format: "%02x", $0) }.joined()
            router.onMessageReceived = { [weak self] message in
                guard let self else { return }
                Task { @MainActor in
                    self.insertMessage(message, myHash: myHex, context: modelContext)
                }
            }

            // Register peer announce handler so the Peers tab fills in.
            // It coalesces announce bursts into a single batched save per second,
            // so heavy mesh traffic can't starve the UI / keyboard.
            let peerHandler = LXMFPeerAnnounceHandler(context: modelContext)
            stack.transport.register(announceHandler: peerHandler)
            self.peerAnnounceHandler = peerHandler

            self.identity = id
            self.lxmfRouter = router
            self.transport = stack.transport
            self.reticulum = stack
            self.isRunning = true
        } catch {
            Reticulum.log("StackController.bringUp failed: \(error)", level: .error)
            self.isRunning = false
        }
    }

    // MARK: - Interface persistence

    /// Persist a user-added client interface so it is restored next launch.
    func saveInterface(name: String, host: String, port: UInt16, kind: SavedInterfaceKind = .tcp) {
        // Single assignment avoids two separate @Published objectWillChange notifications.
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

    #if MESHCORE
    // MARK: - MeshCore interface persistence

    /// Save (or replace) the MeshCore channel configuration. The live interface is
    /// created/registered by the MeshCore scanner over BLE, not here.
    func saveMeshCoreConfig(_ config: SavedMeshCoreConfig) {
        savedMeshCoreConfig = config
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.savedMeshCoreKey)
        }
    }

    /// Forget the persisted MeshCore config and tear down the live interface (if any).
    func removeMeshCoreConfig() {
        let ifaceName = savedMeshCoreConfig?.name ?? "MeshCore"
        savedMeshCoreConfig = nil
        UserDefaults.standard.removeObject(forKey: Self.savedMeshCoreKey)
        deregisterLiveInterface(named: ifaceName)
    }

    private func loadSavedMeshCoreConfig() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedMeshCoreKey),
              let config = try? JSONDecoder().decode(SavedMeshCoreConfig.self, from: data) else { return }
        savedMeshCoreConfig = config
    }
    #endif

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
    /// own — hence the explicit `objectWillChange`.
    private func deregisterLiveInterface(named name: String) {
        guard let transport,
              let iface = transport.interfaces.first(where: { $0.name == name }) else { return }
        objectWillChange.send()
        iface.stop()
        transport.deregister(interface: iface)
    }

    private func loadSavedInterfaces() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedInterfacesKey),
              let saved = try? JSONDecoder().decode([SavedInterface].self, from: data) else { return }
        savedInterfaces = saved
    }

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

    /// Mirror the router's (non-observable) transfer state into @Published
    /// properties twice a second until the sync reaches a terminal state.
    private func startSyncPolling() {
        syncPollTask?.cancel()
        syncPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let router = self.lxmfRouter else { return }
                self.propagationSyncState    = router.propagationTransferState
                self.propagationSyncProgress = router.propagationTransferProgress
                if router.propagationTransferState == .done
                    || router.propagationTransferState == .failed {
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
        guard let router = lxmfRouter, let identity = identity else { return }

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

    private func insertMessage(_ message: LXMessage, myHash: String, context: ModelContext) {
        let senderHex    = message.sourceHash.map { String(format: "%02x", $0) }.joined()
        let recipientHex = message.destinationHash.map { String(format: "%02x", $0) }.joined()
        // conversationHash is always the peer's side — not us.
        let peerHex  = senderHex == myHash ? recipientHex : senderHex
        let msgHash  = message.hash?.map { String(format: "%02x", $0) }.joined() ?? UUID().uuidString
        let isInbound = senderHex != myHash

        // Deduplicate: skip if we already have this exact message.
        let dedup = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.messageHash == msgHash }
        )
        if (try? context.fetch(dedup).isEmpty) == false { return }

        // Preserve attachments (image / files / audio / telemetry) carried in
        // the LXMF `fields`. Inbound fields are recovered as of the C1 unpack
        // fix; we keep the raw packed bytes so the thread view can re-decode
        // them on demand (see MessageAttachments). Text-only messages store nil.
        let carriesFields = !message.fields.isEmpty
        let entity = MessageEntity(
            messageHash: msgHash,
            conversationHash: peerHex,
            senderHash: senderHex,
            recipientHash: recipientHex,
            title: message.titleAsString ?? "",
            content: message.contentAsString ?? "",
            timestamp: Date(timeIntervalSince1970: message.timestamp ?? Date().timeIntervalSince1970),
            isOutbound: !isInbound,
            deliveryState: Int16(message.state.rawValue),
            isRead: !isInbound,
            hasAttachments: carriesFields,
            packedMessage: carriesFields ? message.packed : nil
        )
        context.insert(entity)
        try? context.save()

        // Fire a local notification for inbound messages only.
        if isInbound, let nm = notificationManager {
            // Look up sender's display name from the peer list.
            let peerDesc = FetchDescriptor<PeerEntity>(
                predicate: #Predicate { $0.destinationHash == peerHex }
            )
            let senderName = (try? context.fetch(peerDesc).first?.displayName) ?? "\(peerHex.prefix(8))…"
            let preview    = message.contentAsString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            nm.scheduleMessageNotification(senderName: senderName, preview: preview, peerHash: peerHex)
        }
    }

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
