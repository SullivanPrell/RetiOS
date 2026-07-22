import Foundation
import Observation
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
@Observable
final class NomadNetController {

    // MARK: Browser state

    private(set) var currentNodes: [MicronNode] = []
    private(set) var currentURL: NomadNetURL?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    /// Whether we identify ("log in") to the *currently loaded* node. Reflects
    /// the persisted per-node toggle and drives the URL-bar identify control.
    /// Mirrors Python NomadNet's per-node `should_identify_on_connect`.
    private(set) var identifyToNode = false

    // MARK: RRC state

    /// Live hub manager — non-nil after setup().
    private(set) var rrcManager: RRCManager?

    /// Bumped whenever `RRCManager` reports a change to its hub/room state.
    ///
    /// `RRCManager` is a plain library type with no observation support, so
    /// views showing hub state have nothing to depend on. Under
    /// `ObservableObject` this was a blanket `objectWillChange.send()`, which
    /// only worked because it invalidated *every* observer. `@Observable`
    /// notifies per-property, so the dependency must be explicit — hub views
    /// read this counter.
    private(set) var rrcRevision: Int = 0

    // MARK: Private

    @ObservationIgnored private var browser: NomadNetBrowser?
    @ObservationIgnored private var _modelContext: ModelContext?
    @ObservationIgnored private var _appAdapter: NomadNetAppAdapter?   // keeps adapter alive (RRCManager holds weak ref)
    @ObservationIgnored private var _nodeAnnounceHandler: NomadNetNodeAnnounceHandler?

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
                self?.rrcRevision &+= 1
            }
        }
        rrcManager = manager

        // Restore hubs persisted by RRCManager (rooms, nick overrides,
        // auto-reconnect flags, message history). Without this, every joined
        // channel comes back dead after a relaunch: the ChannelEntity rows
        // still render in ChannelsView, but findHub() returns nil so the
        // room view can never reconnect or send.
        manager.load()
        // Restoring hub *state* is what makes joined channels usable again;
        // redialling their links is not, and an offline UI-test run must not.
        if !StackController.isOfflineUITestRun {
            reconnectHubs()
        }

        // Register nomadnetwork.node announce handler to populate the Peers tab
        // with actual NomadNet nodes (separate from the LXMF peer list).
        let nodeHandler = NomadNetNodeAnnounceHandler(container: modelContext.container)
        transport.register(announceHandler: nodeHandler)
        _nodeAnnounceHandler = nodeHandler

        // Browser. Pass our identity so the browser can identify to nodes on the
        // link (parity with Python's Browser — lets nodes gate / personalise pages).
        let b = ReticulumNomadNetBrowser(transport: transport, identity: identity)
        // Per-node identify predicate (parity with Python's
        // `directory.should_identify_on_connect`). Reads the persisted per-node
        // toggle directly from UserDefaults so it's correct for whichever node is
        // actually being contacted — no MainActor hop, no pushed state, no race.
        b.shouldIdentify = { hash in
            UserDefaults.standard.bool(forKey: NomadNetController.identifyKey(for: hash))
        }
        b.onPageLoaded = { [weak self] nodes, url in
            Task { @MainActor [weak self] in
                self?.currentNodes = nodes
                self?.currentURL   = url
                self?.isLoading    = false
                self?.errorMessage = nil
                // Reflect the loaded node's persisted identify state in the URL bar.
                self?.identifyToNode = UserDefaults.standard.bool(
                    forKey: NomadNetController.identifyKey(for: url.destinationHash))
                self?.updateHistory()
            }
        }
        b.onError = { [weak self] reason, _ in
            Task { @MainActor [weak self] in
                self?.isLoading    = false
                self?.errorMessage = reason
                // Refresh Back/Forward enablement too — a failed navigation can
                // still have moved the history cursor, leaving the buttons stale.
                self?.updateHistory()
            }
        }
        browser = b
    }

    // MARK: - Browser navigation

    func navigate(to urlString: String, fields: [String: String] = [:]) {
        guard let url = NomadNetURL.parse(urlString) else {
            errorMessage = "Invalid NomadNet URL"
            return
        }
        navigate(to: url, fields: fields)
    }

    /// Navigate to a page, optionally carrying form-field values. `fields` are
    /// sent to the node as `field_<name>` (widget/form inputs), distinct from the
    /// URL's `var_<name>` variables — matching Python's NomadNet Browser. Passing
    /// them here (rather than flattening them into the URL string) is what keeps
    /// a submitted form field from being mis-sent as a URL variable.
    func navigate(to url: NomadNetURL, fields: [String: String] = [:]) {
        isLoading = true
        errorMessage = nil
        currentURL = url          // populate URL bar immediately, not just on success
        browser?.navigate(to: url, fields: fields)
    }

    /// Toggle whether we identify ("log in") to the current node, persist the
    /// choice per-node, and reload so it takes effect immediately — turning it on
    /// re-requests the page with our identity revealed (so the node can serve
    /// logged-in content); turning it off re-requests anonymously. Mirrors Python
    /// NomadNet's per-node "Identify when connecting" setting, surfaced in the URL
    /// bar. No-op when no page is loaded (nothing to identify to).
    func setIdentify(_ on: Bool) {
        guard let url = currentURL else { return }
        UserDefaults.standard.set(on, forKey: Self.identifyKey(for: url.destinationHash))
        identifyToNode = on
        reload()
    }

    /// UserDefaults key for a node's persisted "identify on connect" toggle.
    /// Static so the browser's `shouldIdentify` predicate can read it without a
    /// MainActor hop.
    static func identifyKey(for destinationHash: Data) -> String {
        "nnIdentify." + destinationHash.map { String(format: "%02x", $0) }.joined()
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
        // With no page loaded there is nothing to reload, and the browser fires
        // neither onPageLoaded nor onError — so setting isLoading would leave the
        // spinner spinning forever. No-op instead.
        guard currentURL != nil else { return }
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
        // Our own messages are echoed back by the hub — they must not inflate
        // the channel's unread badge (ownSrc == rrcManager.identity.hash).
        let ownHex = rrcManager?.identity?.hash.map { String(format: "%02x", $0) }.joined()
        if ownHex != senderHex {
            channel.unreadCount += 1
        }

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
