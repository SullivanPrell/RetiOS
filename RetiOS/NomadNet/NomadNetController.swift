import Foundation
import SwiftData
import ReticulumSwift
import NomadNet

// MARK: - NomadNetAppAdapter

/// Thin adapter satisfying NomadNetworkAppProtocol for use by RRCManager.
/// Holds strong references to the production Reticulum + Identity so that
/// RRCHub._connectWorker() can reach the transport. RRCManager holds this
/// via a `weak var app` so there is no retain cycle.
private final class NomadNetAppAdapter: NomadNetworkAppProtocol {
    let reticulum: Reticulum
    let identity: Identity
    let storagePath: URL?
    var peerDisplayName: String? { UserDefaults.standard.string(forKey: "rrcNickname") }

    init(reticulum: Reticulum, identity: Identity, storagePath: URL?) {
        self.reticulum = reticulum
        self.identity  = identity
        self.storagePath = storagePath
    }
}

// MARK: - NomadNetController

/// Drives NomadNetBrowserView and ChannelsView — owns the browser instance,
/// the RRCManager, and publishes navigation + channel state to SwiftUI.
@MainActor
final class NomadNetController: ObservableObject {

    // MARK: Browser state

    @Published private(set) var currentNodes: [MicronNode] = []
    @Published private(set) var currentURL: NomadNetURL?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    // MARK: RRC state

    /// Live hub manager — non-nil after setup().
    @Published private(set) var rrcManager: RRCManager?

    // MARK: Private

    private var browser: NomadNetBrowser?
    private var _modelContext: ModelContext?
    private var _appAdapter: NomadNetAppAdapter?   // keeps adapter alive (RRCManager holds weak ref)
    private var _nodeAnnounceHandler: NomadNetNodeAnnounceHandler?

    // MARK: - Setup

    func setup(transport: Transport,
               reticulum: Reticulum,
               identity: Identity,
               modelContext: ModelContext) {
        _modelContext = modelContext

        // Adapter feeds RRCHub with Reticulum transport + Identity.
        let storagePath = URL.documentsDirectory
            .appending(path: "nomadnet", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: storagePath, withIntermediateDirectories: true)
        let adapter = NomadNetAppAdapter(reticulum: reticulum, identity: identity,
                                         storagePath: storagePath)
        _appAdapter = adapter

        // Create RRCManager and wire message / change callbacks.
        let manager = RRCManager(app: adapter)
        manager.onMessageCallback = { [weak self] hub, msg in
            Task { @MainActor [weak self] in
                self?.handleRRCMessage(hub: hub, msg: msg)
            }
        }
        manager.onChangeCallback = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
        rrcManager = manager

        // Restore hubs persisted by RRCManager (rooms, nick overrides,
        // auto-reconnect flags, message history). Without this, every joined
        // channel comes back dead after a relaunch: the ChannelEntity rows
        // still render in ChannelsView, but findHub() returns nil so the
        // room view can never reconnect or send.
        manager.load()
        reconnectHubs()

        // Register nomadnetwork.node announce handler to populate the Peers tab
        // with actual NomadNet nodes (separate from the LXMF peer list).
        let nodeHandler = NomadNetNodeAnnounceHandler(context: modelContext)
        transport.register(announceHandler: nodeHandler)
        _nodeAnnounceHandler = nodeHandler

        // Browser.
        let b = ReticulumNomadNetBrowser(transport: transport)
        b.onPageLoaded = { [weak self] nodes, url in
            Task { @MainActor [weak self] in
                self?.currentNodes = nodes
                self?.currentURL   = url
                self?.isLoading    = false
                self?.errorMessage = nil
                self?.updateHistory()
            }
        }
        b.onError = { [weak self] reason, _ in
            Task { @MainActor [weak self] in
                self?.isLoading    = false
                self?.errorMessage = reason
            }
        }
        browser = b
    }

    // MARK: - Browser navigation

    func navigate(to urlString: String) {
        guard let url = NomadNetURL.parse(urlString) else {
            errorMessage = "Invalid NomadNet URL"
            return
        }
        navigate(to: url)
    }

    func navigate(to url: NomadNetURL) {
        isLoading = true
        errorMessage = nil
        currentURL = url          // populate URL bar immediately, not just on success
        browser?.navigate(to: url)
    }

    func goBack() {
        isLoading = true
        errorMessage = nil
        browser?.goBack()
        updateHistory()
    }

    func goForward() {
        isLoading = true
        errorMessage = nil
        browser?.goForward()
        updateHistory()
    }

    func reload() {
        isLoading = true
        errorMessage = nil
        browser?.reload()
    }

    // MARK: - RRC channel management

    /// Join an RRC hub and start receiving messages.
    /// Returns the hub (existing one if already joined; new one otherwise).
    @discardableResult
    func joinChannel(hubHash: Data,
                     destName: String = RRC.defaultDestName,
                     name: String? = nil) -> RRCHub? {
        guard let manager = rrcManager else { return nil }
        let hub = manager.addHub(hash: hubHash, destName: destName, name: name)
        // Joined channels should come back automatically after a relaunch or
        // when the app returns to the foreground (see reconnectHubs()).
        hub.setAutoReconnect(true)
        hub.connect()
        // Upsert ChannelEntity so it appears in ChannelsView immediately.
        if let ctx = _modelContext {
            let hexHash = hubHash.map { String(format: "%02x", $0) }.joined()
            let desc = FetchDescriptor<ChannelEntity>(
                predicate: #Predicate { $0.channelHash == hexHash }
            )
            if (try? ctx.fetch(desc))?.first == nil {
                ctx.insert(ChannelEntity(channelHash: hexHash,
                                         name: name ?? hub.name,
                                         destName: destName))
                try? ctx.save()
            }
        }
        return hub
    }

    /// Reconnect any auto-reconnect hubs that have dropped their link.
    /// Called after setup (restoring persisted hubs) and whenever the app
    /// returns to the foreground — iOS tears down idle network connections
    /// while backgrounded, so open hubs are usually dead on resume.
    func reconnectHubs() {
        guard let manager = rrcManager else { return }
        for hub in manager.hubs where hub.autoReconnect {
            if hub.status == .disconnected || hub.status == .failed {
                hub.connect()
            }
        }
    }

    /// Disconnect and remove an RRC hub.
    func leaveChannel(channelHash: String) {
        guard let manager = rrcManager,
              let hashData = Data(hexString: channelHash) else { return }
        // Look up the stored destName so we find the right hub even with custom dest names.
        var destName: String = RRC.defaultDestName
        if let ctx = _modelContext {
            let chanDesc = FetchDescriptor<ChannelEntity>(
                predicate: #Predicate { $0.channelHash == channelHash }
            )
            destName = (try? ctx.fetch(chanDesc))?.first?.destName ?? RRC.defaultDestName
        }
        if let hub = manager.findHub(hash: hashData, destName: destName) {
            manager.removeHub(hub)
        }
        // Remove the persisted ChannelEntity + its messages.
        if let ctx = _modelContext {
            let chanDesc = FetchDescriptor<ChannelEntity>(
                predicate: #Predicate { $0.channelHash == channelHash }
            )
            if let entity = (try? ctx.fetch(chanDesc))?.first {
                ctx.delete(entity)
            }
            let msgDesc = FetchDescriptor<ChannelMessageEntity>(
                predicate: #Predicate { $0.channelHash == channelHash }
            )
            (try? ctx.fetch(msgDesc))?.forEach { ctx.delete($0) }
            try? ctx.save()
        }
    }

    // MARK: - Private helpers

    private func updateHistory() {
        canGoBack    = browser?.history.canGoBack    ?? false
        canGoForward = browser?.history.canGoForward ?? false
    }

    /// Persist an inbound RRC message to SwiftData and bump the channel unread count.
    private func handleRRCMessage(hub: RRCHub, msg: RRCMessage) {
        guard msg.kind == "msg" || msg.kind == "action",
              let ctx = _modelContext else { return }

        let hubHex    = hub.hubHash.map { String(format: "%02x", $0) }.joined()
        let senderHex = msg.src?.map { String(format: "%02x", $0) }.joined() ?? ""
        let ts        = msg.ts > 0
                        ? Date(timeIntervalSince1970: Double(msg.ts) / 1000.0)
                        : Date()
        // Deterministic message ID: hub + room + timestamp + sender.
        let msgID = "\(hubHex):\(msg.room ?? ""):\(msg.ts):\(senderHex)"

        // Dedup.
        let dedup = FetchDescriptor<ChannelMessageEntity>(
            predicate: #Predicate { $0.messageID == msgID }
        )
        guard (try? ctx.fetch(dedup))?.isEmpty != false else { return }

        // Upsert ChannelEntity.
        let chanDesc = FetchDescriptor<ChannelEntity>(
            predicate: #Predicate { $0.channelHash == hubHex }
        )
        let channel: ChannelEntity
        if let existing = (try? ctx.fetch(chanDesc))?.first {
            channel = existing
        } else {
            channel = ChannelEntity(channelHash: hubHex,
                                     name: hub.name,
                                     destName: hub.destName)
            ctx.insert(channel)
        }
        channel.lastActivity = ts
        channel.unreadCount += 1

        // Insert message.
        ctx.insert(ChannelMessageEntity(
            channelHash: hubHex,
            messageID:   msgID,
            senderHash:  senderHex,
            senderNick:  msg.nick,
            room:        msg.room,
            content:     msg.text,
            timestamp:   ts
        ))
        try? ctx.save()
    }
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
