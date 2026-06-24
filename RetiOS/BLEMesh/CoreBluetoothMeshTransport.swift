import Foundation
import CoreBluetooth
import ReticulumSwift

// MARK: - CoreBluetoothMeshTransport

/// CoreBluetooth implementation of `BLEMeshTransport` — lets this device mesh
/// directly with any number of nearby phones running the same app, with no
/// RNode hardware in between.
///
/// ## Why dual-role
///
/// `BLERNodeTransport` only ever needs the *central* role: the phone connects
/// out to one specific RNode peripheral. A phone-to-phone mesh can't work that
/// way — CoreBluetooth centrals can only discover *peripherals*, never other
/// centrals, so if every phone only scanned, no two phones could ever find
/// each other. Each device must therefore run both roles concurrently:
///
///   - **Peripheral**: advertise the mesh GATT service, so nearby phones can
///     find and connect to *us*.
///   - **Central**: scan for that same service, and connect out to whatever
///     we find.
///
/// Whichever side initiates the GATT connection, the link ends up fully
/// bidirectional — exactly like `BLERNodeTransport`'s Nordic UART pattern,
/// just with the roles potentially reversed:
///
///   - When **we are central** (we connected to them): we write to *their*
///     RX characteristic, and subscribe to notifications on *their* TX
///     characteristic.
///   - When **we are peripheral** (they connected to us): they write to
///     *our* RX characteristic, and we notify them via *our* TX
///     characteristic once they subscribe.
///
/// ## GATT layout
///
/// A custom "Reticulum Mesh" service — this isn't a Nordic UART link, so it
/// gets its own UUID space, but mirrors the NUS convention of sequential
/// service/RX/TX UUIDs for easy recognition:
///
/// ```
/// Service  98196A76 — Reticulum Mesh
///   RX char 98196A77 — write / write-without-response (peer → us)
///   TX char 98196A78 — notify                          (us → peer)
/// ```
///
/// ## Peer identity
///
/// `BLEMeshPeerID` is `CBPeripheral.identifier.uuidString` for links where we
/// are central, and `CBCentral.identifier.uuidString` where we are
/// peripheral. CoreBluetooth assigns these independently per role, so the
/// *same* physical device can show up under two different peer IDs — once for
/// each direction in which a connection was initiated. This transport makes
/// no attempt to reconcile the two: `BLEMeshInterface`'s flood-and-broadcast
/// model (mirroring `AutoInterface`) and `Transport`'s duplicate-hash
/// suppression already handle redundant links gracefully — a "phantom" extra
/// neighbour just means a packet gets flooded down one extra (redundant) edge,
/// not that anything breaks. Reconciling would require an application-layer
/// handshake exchanging stable identities, which is out of scope for a radio
/// transport whose only contract is "ferry bytes to opaque peer IDs".
final class CoreBluetoothMeshTransport: NSObject {

    // MARK: - GATT UUIDs

    static let meshSvcUUID = CBUUID(string: "98196A76-3A68-4651-AAA0-160700BB0E6C")
    /// Write / write-without-response: peer → us, when we are the GATT peripheral.
    static let meshRxUUID  = CBUUID(string: "98196A77-3A68-4651-AAA0-160700BB0E6C")
    /// Notify: us → peer, when we are the GATT peripheral.
    static let meshTxUUID  = CBUUID(string: "98196A78-3A68-4651-AAA0-160700BB0E6C")

    /// Human-readable `CBManagerState` for diagnostic logging — neither
    /// `CBManagerState` nor `CBPeripheralManagerState`/`CBCentralManagerState`
    /// (it's a single shared enum) conforms to `CustomStringConvertible`.
    private static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn:    return "poweredOn"
        case .poweredOff:   return "poweredOff"
        case .resetting:    return "resetting"
        case .unauthorized: return "unauthorized"
        case .unsupported:  return "unsupported"
        case .unknown:      return "unknown"
        @unknown default:   return "unknown(\(state.rawValue))"
        }
    }

    /// First 8 hex characters of a peer ID — enough to distinguish peers in
    /// logs without spamming full UUIDs.
    private static func short(_ peerID: BLEMeshPeerID) -> Substring { peerID.prefix(8) }

    // MARK: - Connection arbitration
    //
    // CoreBluetooth gives the two sides of a link no shared, symmetric way to
    // recognize each other: `CBPeripheral.identifier`/`CBCentral.identifier`
    // are independently assigned per role (see the "Peer identity" doc
    // comment on the type), and `CBPeripheralManager` exposes no "local
    // identifier" at all. Yet every device here runs *both* roles and
    // scans+advertises continuously — so any two devices in range inevitably
    // discover each other within milliseconds of one another and BOTH call
    // `central.connect(_:)` at nearly the same instant. In practice that
    // mutual cross-connection attempt deadlocks at least one side's radio:
    // neither `didConnect` nor `didFailToConnect` ever fires — exactly the
    // symptom reported ("discovered peer ... — connecting", then permanent
    // silence, 0 packets/0 peers on both ends despite both successfully
    // advertising and scanning).
    //
    // The standard fix for dual-role BLE meshing is to elect a single
    // initiator per pair so there's nothing left to race: on mutual
    // discovery, only one side calls `connect(_:)`; the other waits to be
    // connected to. Both keep advertising and scanning regardless, so the
    // link still forms either way — just from exactly one direction.
    //
    // ATTEMPT #1 (reverted): generate a random per-device ID, persist it,
    // and append it to the advertised local name (`"<name>\u{1F}<hex id>"`)
    // so peers could compare IDs and elect the numerically-lower side. This
    // built and ran, but made things *worse* in the field: appending even
    // ~9 bytes pushed the local-name AD structure past whatever headroom
    // `CBPeripheralManager` has left over once the 128-bit mesh service UUID
    // (16 bytes alone) is also in the advertisement. The system responded by
    // silently dropping `CBAdvertisementDataLocalNameKey` from the broadcast
    // *entirely* — confirmed by comparing the two test runs' logs:
    //   before the suffix: peers correctly saw "RetiOS" / "sully-iphone"
    //   after adding it:   peers instead saw "Sullivan's MacBook Pro" /
    //                      "Sully-iPhone" — the *system* Bluetooth device
    //                      names, i.e. `didDiscover`'s fallback to
    //                      `peripheral.name` because `CBAdvertisementData-
    //                      LocalNameKey` was simply absent from the payload.
    // With the custom name gone, `parseAdvertisedName` always returned a
    // `nil` ID, `connectionDecision`'s `guard let peerTieBreakID` always
    // failed, and *both* sides fell through to `.connect` — i.e. the exact
    // mutual cross-connection deadlock arbitration was meant to prevent,
    // just one layer further down.
    //
    // ATTEMPT #2: don't transmit anything new at all — there's no headroom
    // to do so safely alongside a 128-bit service UUID, full stop. Instead,
    // elect the initiator using data that's *already* proven to transmit
    // intact: the plain advertised display name. Lexicographic string
    // comparison is symmetric and deterministic — exactly one of
    // `nameA < nameB` / `nameB < nameA` holds for any two distinct names —
    // so "the side whose name sorts lower dials out" resolves identically
    // from both ends without adding a single byte to either advertisement.
    //
    // ATTEMPT #3 (current, additive — election logic itself is unchanged
    // from #2): in the field, election picked exactly one initiator
    // correctly — one side logged "connecting", the other "yielding the
    // connection to them" — and the link *still* never formed: the
    // "connecting" side fell silent forever, 0 packets/0 peers on both ends.
    // Two independent liveness gaps were compounding:
    //
    //   1. `central.connect(_:)` has **no built-in timeout**. CoreBluetooth
    //      can — and in the field, did — simply never call back: neither
    //      `didConnect` nor `didFailToConnect` fired. That latches
    //      `connectingPeripheralIDs` forever, so every subsequent
    //      `didDiscover` for that peer is silently swallowed by the
    //      `guard !alreadyConnecting`. (The likely trigger, visible by
    //      comparing the two sides' logs side by side: "sully-iphone" — 12
    //      bytes — doesn't fit in the legacy 31-byte advertisement PDU
    //      alongside the 18-byte 128-bit-service-UUID AD structure and
    //      3-byte flags structure, leaving ~10 bytes of headroom — 2 of
    //      which are the name structure's own length+type, an 8-character
    //      ceiling. "RetiOS" — 6 bytes — just squeaks under it. So the
    //      *winning* side here, the Mac, received the iPhone's advertisement
    //      with `CBAdvertisementDataLocalNameKey` silently dropped — exactly
    //      like ATTEMPT #1's postmortem — and fell back to `peripheral.name`,
    //      the cached *system* Bluetooth name "Sully-iPhone". Lexicographic
    //      comparison of "RetiOS"/"Sully-iPhone" happened to pick the same
    //      winner "RetiOS"/"sully-iphone" would have — pure luck of where
    //      capital vs. lowercase letters fall in ASCII — so the election
    //      *looked* perfectly correct in this trace. The actual failure was
    //      one layer further downstream: that winning side's `connect(_:)`
    //      call against the resulting peripheral simply never resolved.)
    //   2. `deferralTimeout`'s self-heal was only ever evaluated from inside
    //      `didDiscover` — but `scanForPeripherals` runs with
    //      `allowDuplicates: false` (the only sane choice for an always-on
    //      background scan), under which CoreBluetooth typically does *not*
    //      redeliver `didDiscover` for a peripheral it already reported. So
    //      the side that yielded the election had no event left to ever
    //      re-run `connectionDecision` — it would defer *forever*, blind to
    //      the winner being stuck on (1).
    //
    // Fixed both with watchdogs that don't depend on any particular
    // CoreBluetooth callback recurring: `scheduleConnectTimeout` cancels and
    // releases a `connect(_:)` attempt that's produced neither success nor
    // failure within `connectTimeout`, and `recheckDeferrals` is a periodic
    // timer — wholly independent of `didDiscover` — that promotes a
    // long-deferred peer to "connect ourselves" once `deferralTimeout`
    // elapses. Together they guarantee forward progress no matter *why*
    // CoreBluetooth went quiet — the same "an occasional redundant link
    // beats a permanent deadlock" trade-off `deferralTimeout` was already
    // built around.
    private enum ConnectionDecision { case connect, `defer` }

    /// How long a deferring side waits for the winning peer to complete the
    /// connection before giving up and connecting itself anyway. Guards
    /// against a stuck mesh in the (rare) event the winning side's attempt
    /// silently fails, both sides tie (identical advertised names — the one
    /// case lexicographic comparison can't break), or only one side
    /// understands arbitration — better an occasional redundant link (which
    /// `BLEMeshInterface`'s flood-and-suppress model absorbs for free, per
    /// its "Peer identity" doc comment) than two devices deadlocked forever
    /// each waiting on the other.
    private static let deferralTimeout: TimeInterval = 8

    /// How often `recheckDeferrals` re-evaluates `deferredPeripherals`
    /// against `deferralTimeout` — see ATTEMPT #3 above for why this can't
    /// simply ride on `didDiscover` recurring.
    private static let deferralRecheckInterval: TimeInterval = 2

    /// How long we wait for `didConnect`/`didFailToConnect` to fire after
    /// calling `central.connect(_:)` before cancelling the attempt
    /// ourselves and giving the next `didDiscover` a clean slate to retry —
    /// see ATTEMPT #3 above for the field evidence that CoreBluetooth's
    /// `connect` has no timeout of its own and can simply go silent forever.
    private static let connectTimeout: TimeInterval = 12

    /// A peer whose election we lost (their advertised name sorted lower) —
    /// recorded so `recheckDeferrals` can self-heal if they never finish
    /// connecting to us within `deferralTimeout`. Carries the `CBPeripheral`
    /// (not just its identifier) because healing means dialing out
    /// ourselves, which needs the live object — and `displayName` purely so
    /// the eventual "connecting ourselves instead" log line can name them.
    private struct DeferredPeer {
        let peripheral: CBPeripheral
        let displayName: String
        let since: Date
    }

    // MARK: - BLEMeshTransport requirements

    var peerConnected: ((BLEMeshPeerID) -> Void)?
    var peerDisconnected: ((BLEMeshPeerID) -> Void)?
    var peerDataHandler: ((BLEMeshPeerID, Data) -> Void)?

    var connectedPeers: [BLEMeshPeerID] {
        lock.lock(); defer { lock.unlock() }
        return Array(Set(centralLinks.keys).union(subscriptions.keys))
    }

    /// Fired whenever the device's Bluetooth radio state changes. This is
    /// deliberately NOT part of `BLEMeshTransport` — it's a CoreBluetooth-only
    /// concept the protocol's mock conformances (and `BLEMeshInterface`,
    /// which only ever speaks in peer IDs and bytes) have no reason to model.
    /// `BLEMeshController` observes it purely to drive "Bluetooth unavailable"
    /// UI state, the same job `RNodeScannerController` does for RNode.
    var radioStateHandler: ((CBManagerState) -> Void)?

    // MARK: - Shared mutable state
    //
    // CoreBluetooth delivers every delegate callback (central AND peripheral
    // role — both managers share `queue`) serially on `queue`, but `send`,
    // `connectedPeers`, and `stop` can be called from any thread (Transport's
    // calling thread, the controller's main-actor thread, …). `lock` is the
    // single source of truth guarding all of it — exactly the role
    // `BLEMeshInterface.peersLock` plays for the interface's own peer table.

    private struct CentralLink {
        let peripheral: CBPeripheral
        let rxChar: CBCharacteristic
        let txChar: CBCharacteristic
    }

    private let lock = NSLock()

    /// Links we initiated (we are GATT central), keyed by `peripheral.identifier.uuidString`.
    private var centralLinks: [BLEMeshPeerID: CentralLink] = [:]
    /// Centrals subscribed to our TX characteristic (we are GATT peripheral),
    /// keyed by `central.identifier.uuidString`. A central becomes sendable
    /// only once subscribed — that's what makes `updateValue` deliverable.
    private var subscriptions: [BLEMeshPeerID: CBCentral] = [:]
    /// Outbound notification chunks awaiting `CBPeripheralManager.updateValue`
    /// admission, drained opportunistically and from
    /// `peripheralManagerIsReady(toUpdateSubscribers:)`.
    private var pendingNotifications: [BLEMeshPeerID: [Data]] = [:]
    /// Outbound write-without-response chunks awaiting room in CoreBluetooth's
    /// transmit buffer (we are GATT central) — the central-role mirror of
    /// `pendingNotifications`, drained opportunistically and from
    /// `peripheralIsReady(toSendWriteWithoutResponse:)`. See
    /// `drainCentralWrites` for why this queue is required at all (it's the
    /// actual fix for "sending doesn't work").
    private var pendingCentralWrites: [BLEMeshPeerID: [Data]] = [:]
    /// Peripherals we've issued `connect(_:)` for but not yet finished GATT
    /// setup on — guards against duplicate connection attempts across the
    /// repeated `didDiscover` callbacks CoreBluetooth delivers while a
    /// peripheral remains in range.
    private var connectingPeripheralIDs: Set<UUID> = []
    /// Peripherals we've yielded the connection to (their advertised name
    /// sorted lower, winning the election) — see `connectionDecision`,
    /// `recheckDeferrals`, and `DeferredPeer`'s doc comment.
    private var deferredPeripherals: [UUID: DeferredPeer] = [:]
    private var txCharacteristic: CBMutableCharacteristic?
    private var serviceAdded = false

    // MARK: - CoreBluetooth managers

    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private let queue = DispatchQueue(label: "CoreBluetoothMeshTransport")
    private let advertisedName: String

    /// Periodic, `didDiscover`-independent liveness check for
    /// `deferredPeripherals` — see `recheckDeferrals` and ATTEMPT #3 above.
    private var deferralCheckTimer: DispatchSourceTimer?

    // MARK: - Init

    /// - Parameter localName: advertised local name — shown to nearby peers
    ///   exactly like `peripheral.name` surfaces in `RNodeScannerController`'s
    ///   discovered-device list (here, in their `didDiscover` advertisement
    ///   data, for any UI they choose to build on top of it). Also doubles as
    ///   this device's connection-arbitration key — see "Connection
    ///   arbitration" above for why piggybacking on it (rather than
    ///   transmitting a dedicated ID) is what actually works.
    init(localName: String) {
        self.advertisedName = localName
        super.init()
    }
}

// MARK: - BLEMeshTransport

extension CoreBluetoothMeshTransport: BLEMeshTransport {

    func start() throws {
        Reticulum.log("[BLEMesh] starting dual-role CoreBluetooth (advertising as \"\(advertisedName)\")", level: .info)
        central = CBCentralManager(delegate: self, queue: queue)
        peripheralManager = CBPeripheralManager(delegate: self, queue: queue)

        // See ATTEMPT #3 above: `didDiscover` is not a reliable heartbeat
        // for re-evaluating deferrals (CoreBluetooth doesn't redeliver it
        // for already-seen peripherals under `allowDuplicates: false`), so
        // `recheckDeferrals` needs its own clock, wholly independent of any
        // delegate callback recurring.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.deferralRecheckInterval, repeating: Self.deferralRecheckInterval)
        timer.setEventHandler { [weak self] in self?.recheckDeferrals() }
        timer.resume()
        deferralCheckTimer = timer
    }

    func stop() {
        Reticulum.log("[BLEMesh] stopping CoreBluetooth mesh transport", level: .info)
        central?.stopScan()
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()

        deferralCheckTimer?.cancel()
        deferralCheckTimer = nil

        lock.lock()
        let links = Array(centralLinks.values)
        centralLinks.removeAll()
        subscriptions.removeAll()
        pendingNotifications.removeAll()
        pendingCentralWrites.removeAll()
        connectingPeripheralIDs.removeAll()
        deferredPeripherals.removeAll()
        txCharacteristic = nil
        serviceAdded = false
        lock.unlock()

        for link in links {
            central?.cancelPeripheralConnection(link.peripheral)
        }

        central = nil
        peripheralManager = nil
    }

    /// Routes to whichever GATT role currently links us to `peer`: write (as
    /// central) or notify (as peripheral). `BLEMeshInterface` only ever calls
    /// this with peer IDs it learned from `peerConnected`/`peerDataHandler`,
    /// but a disconnect can race the call — `unknownPeer`/`notConnected`
    /// simply propagate to `BLEMeshInterface`'s `try?`, which drops the send
    /// for that one peer without disrupting the broadcast to the others.
    func send(_ data: Data, to peer: BLEMeshPeerID) throws {
        lock.lock()
        let link = centralLinks[peer]
        let subscriber = subscriptions[peer]
        lock.unlock()

        if let link {
            try writeAsCentral(data, link: link)
        } else if let subscriber {
            notifyAsPeripheral(data, peer: peer, central: subscriber)
        } else {
            throw CoreBluetoothMeshError.unknownPeer
        }
    }
}

// MARK: - Outbound: chunking + per-role delivery

extension CoreBluetoothMeshTransport {

    /// Splits `data` into pieces no larger than `mtu` — mirrors
    /// `BLERNodeTransport.write`'s chunking. BLE GATT writes and
    /// notifications are both bound by the link's negotiated MTU; handing
    /// over an oversized payload would simply be dropped or truncated.
    private func chunked(_ data: Data, mtu: Int) -> [Data] {
        guard mtu > 0, data.count > mtu else { return [data] }
        var pieces: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: mtu, limitedBy: data.endIndex) ?? data.endIndex
            pieces.append(Data(data[offset..<end]))
            offset = end
        }
        return pieces
    }

    /// We are GATT central for this peer: write to its RX characteristic
    /// without response. Queues the chunks and kicks off draining — see
    /// `drainCentralWrites` for why a blind write loop (what used to be here)
    /// is the actual root cause of "sending doesn't work".
    private func writeAsCentral(_ data: Data, link: CentralLink) throws {
        guard link.peripheral.state == .connected else {
            throw CoreBluetoothMeshError.notConnected
        }
        let peerID = link.peripheral.identifier.uuidString
        let mtu = link.peripheral.maximumWriteValueLength(for: .withoutResponse)
        let pieces = chunked(data, mtu: mtu)

        lock.lock()
        pendingCentralWrites[peerID, default: []].append(contentsOf: pieces)
        lock.unlock()

        drainCentralWrites(for: peerID, link: link)
    }

    /// Pushes queued chunks for `peerID` through
    /// `writeValue(_:for:type: .withoutResponse)` until either the queue
    /// empties or CoreBluetooth's outbound transmit buffer fills up.
    ///
    /// **This is the fix for "receiving works, sending doesn't":** unlike
    /// `CBPeripheralManager.updateValue` — which *tells you* the buffer is
    /// full by returning `false`, exactly what `drainNotifications` already
    /// checks for — `CBPeripheral.writeValue(type: .withoutResponse)` returns
    /// `Void` and, per Apple's own documentation, **silently drops** the
    /// write if the transmit buffer has no room: no error, no thrown
    /// exception, no delegate callback, nothing observable at all. The
    /// previous code wrote every chunk in a tight blind loop, so anything
    /// past whatever fit in CoreBluetooth's internal queue (in practice,
    /// often just the first chunk of the first packet after connecting)
    /// vanished without a trace — invisible on the sending side (the call
    /// "succeeded") and invisible on the receiving side (nothing ever
    /// arrived to log). Receiving was never affected because it's purely
    /// passive — driven by `didUpdateValueFor`/`didReceiveWrite` callbacks
    /// the *remote* side's send triggers, with no transmit buffer of ours
    /// in the loop.
    ///
    /// The fix is to do for central-role writes exactly what
    /// `drainNotifications` already correctly does for peripheral-role
    /// notifications: check `canSendWriteWithoutResponse` before every
    /// write, stop the instant it goes `false`, and resume from
    /// `peripheralIsReady(toSendWriteWithoutResponse:)` — the delegate
    /// callback CoreBluetooth fires exactly when buffer space frees up.
    private func drainCentralWrites(for peerID: BLEMeshPeerID, link: CentralLink) {
        while true {
            guard link.peripheral.state == .connected else {
                lock.lock()
                pendingCentralWrites.removeValue(forKey: peerID)
                lock.unlock()
                return
            }
            guard link.peripheral.canSendWriteWithoutResponse else { return }

            lock.lock()
            let next = pendingCentralWrites[peerID]?.first
            lock.unlock()

            guard let next else { return }
            link.peripheral.writeValue(next, for: link.rxChar, type: .withoutResponse)

            lock.lock()
            if pendingCentralWrites[peerID]?.isEmpty == false {
                pendingCentralWrites[peerID]?.removeFirst()
            }
            lock.unlock()
        }
    }

    /// We are GATT peripheral for this peer: notify it on our TX
    /// characteristic. Queues the chunks and kicks off draining — see
    /// `drainNotifications`.
    private func notifyAsPeripheral(_ data: Data, peer: BLEMeshPeerID, central: CBCentral) {
        let pieces = chunked(data, mtu: central.maximumUpdateValueLength)

        lock.lock()
        pendingNotifications[peer, default: []].append(contentsOf: pieces)
        lock.unlock()

        drainNotifications(for: peer, to: central)
    }

    /// Pushes queued chunks for `peer` through `updateValue` until either the
    /// queue empties or CoreBluetooth's transmit buffer fills up.
    /// `updateValue` returning `false` means "try again later" — we stop and
    /// wait for `peripheralManagerIsReady(toUpdateSubscribers:)` to resume,
    /// rather than busy-spinning or dropping data.
    private func drainNotifications(for peer: BLEMeshPeerID, to central: CBCentral) {
        guard let pm = peripheralManager else { return }
        while true {
            lock.lock()
            let next = pendingNotifications[peer]?.first
            let txChar = txCharacteristic
            lock.unlock()

            guard let next, let txChar else { return }
            guard pm.updateValue(next, for: txChar, onSubscribedCentrals: [central]) else { return }

            lock.lock()
            if pendingNotifications[peer]?.isEmpty == false {
                pendingNotifications[peer]?.removeFirst()
            }
            lock.unlock()
        }
    }
}

// MARK: - CBCentralManagerDelegate (central role: find + link to mesh peripherals)

extension CoreBluetoothMeshTransport: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Reticulum.log("[BLEMesh] central radio: \(Self.describe(central.state))", level: .info)
        radioStateHandler?(central.state)
        guard central.state == .poweredOn else { return }
        Reticulum.log("[BLEMesh] scanning for nearby mesh peers (service \(Self.meshSvcUUID.uuidString.prefix(8))…)", level: .info)
        central.scanForPeripherals(
            withServices: [Self.meshSvcUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let peerID = peripheral.identifier.uuidString
        // NOTE: deliberately *not* parsing any appended arbitration payload
        // out of this — see "Connection arbitration" above for why anything
        // beyond the plain advertised name doesn't survive the trip. If the
        // custom local name didn't make it across (foreign/older peer, or a
        // peripheral that simply never set one), `peripheral.name` — the
        // system-cached Bluetooth device name — is the next best identity to
        // log and arbitrate on; "unnamed" only as a last resort.
        let peerDisplayName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "unnamed"

        lock.lock()
        let alreadyLinked = centralLinks[peerID] != nil
        let alreadyConnecting = connectingPeripheralIDs.contains(peripheral.identifier)
        let decision = connectionDecision(for: peripheral, peerDisplayName: peerDisplayName)
        if !alreadyLinked && !alreadyConnecting && decision == .connect {
            connectingPeripheralIDs.insert(peripheral.identifier)
            deferredPeripherals.removeValue(forKey: peripheral.identifier)
        }
        lock.unlock()

        guard !alreadyLinked, !alreadyConnecting else { return }

        switch decision {
        case .connect:
            Reticulum.log("[BLEMesh] discovered peer \(Self.short(peerID))… (\"\(peerDisplayName)\", RSSI \(RSSI)) — connecting", level: .info)
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            scheduleConnectTimeout(for: peripheral)
        case .defer:
            // Their name sorted lower and won the election for this pair —
            // they'll connect to *us* (we're advertising + they're scanning
            // too). Logged at .info since this is the expected steady-state
            // for roughly half of all pairings, not an anomaly.
            Reticulum.log("[BLEMesh] discovered peer \(Self.short(peerID))… (\"\(peerDisplayName)\", RSSI \(RSSI)) — yielding the connection to them (name sorts higher)", level: .info)
        }
    }

    /// Decides whether *we* should dial out to a newly discovered peer or
    /// wait to be dialed — see "Connection arbitration" above. Must be
    /// called with `lock` held; mutates `deferredPeripherals`.
    ///
    /// Note this no longer self-heals inline (ATTEMPT #2 did): that logic
    /// only ever ran when `didDiscover` fired again, which — per ATTEMPT
    /// #3's finding — CoreBluetooth routinely never does once a peripheral's
    /// been reported under `allowDuplicates: false`. `recheckDeferrals`'
    /// timer now owns the self-heal exclusively, so a deferral recorded here
    /// is guaranteed to be revisited on a clock instead of a maybe-callback.
    private func connectionDecision(for peripheral: CBPeripheral, peerDisplayName: String) -> ConnectionDecision {
        let id = peripheral.identifier

        // Our name sorts *strictly* lower — we win the election outright,
        // dial out exactly like before arbitration existed. (Note this is
        // deliberately asymmetric with the tie case below: exactly one side
        // of any pair with distinct names satisfies this, and a tie must
        // make *both* sides defer — see `deferralTimeout`'s doc comment for
        // why "both connect" would be the one outcome to avoid.)
        if advertisedName < peerDisplayName {
            deferredPeripherals.removeValue(forKey: id)
            return .connect
        }

        if deferredPeripherals[id] == nil {
            deferredPeripherals[id] = DeferredPeer(peripheral: peripheral, displayName: peerDisplayName, since: Date())
        }
        return .defer
    }

    /// Watchdog for a single `central.connect(_:)` attempt — see
    /// `connectTimeout`'s doc comment and ATTEMPT #3 above for why
    /// CoreBluetooth needs one imposed from outside: it has none of its own,
    /// and in the field simply went silent forever, calling neither
    /// `didConnect` nor `didFailToConnect`.
    ///
    /// Runs on `queue` — the same serial queue every delegate callback lands
    /// on — so there's no race with a legitimate `didConnect`/
    /// `didFailToConnect` arriving right around the deadline. Checks
    /// `peripheral.state` in addition to `connectingPeripheralIDs`
    /// deliberately: `didConnect` doesn't clear that set itself (GATT
    /// service/characteristic discovery does, on success or
    /// `abandonCentralLink`), so without the state check this watchdog could
    /// misfire mid-handshake and cancel a connection that's actually
    /// progressing just fine.
    private func scheduleConnectTimeout(for peripheral: CBPeripheral) {
        let id = peripheral.identifier
        queue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
            guard let self else { return }

            lock.lock()
            let stillPending = connectingPeripheralIDs.contains(id) && peripheral.state != .connected
            if stillPending {
                connectingPeripheralIDs.remove(id)
                deferredPeripherals.removeValue(forKey: id)
            }
            lock.unlock()

            guard stillPending else { return }
            Reticulum.log("[BLEMesh] connection attempt to \(Self.short(id.uuidString))… produced neither success nor failure within \(Int(Self.connectTimeout))s — CoreBluetooth's `connect` has no timeout of its own, so cancelling it ourselves; will retry on rediscovery", level: .warning)
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    /// Periodic, `didDiscover`-independent self-heal for `deferredPeripherals`
    /// — see ATTEMPT #3 above for why this can no longer live inside
    /// `connectionDecision`. Runs every `deferralRecheckInterval` on `queue`;
    /// promotes any peer that's been waiting past `deferralTimeout` to
    /// "connect ourselves", on the theory that the side that should have
    /// dialed in by now (the election's actual winner) is stuck — most
    /// likely on exactly the silent-`connect`-hang `scheduleConnectTimeout`
    /// guards against on *their* end.
    private func recheckDeferrals() {
        lock.lock()
        let now = Date()
        var promoted: [DeferredPeer] = []
        for (id, deferred) in deferredPeripherals {
            guard now.timeIntervalSince(deferred.since) >= Self.deferralTimeout else { continue }
            guard centralLinks[id.uuidString] == nil, !connectingPeripheralIDs.contains(id) else {
                // A link formed (or is forming) some other way in the
                // meantime — e.g. they connected to *us* as planned, or a
                // prior `recheckDeferrals` tick already promoted this one.
                // Nothing left to heal.
                deferredPeripherals.removeValue(forKey: id)
                continue
            }
            deferredPeripherals.removeValue(forKey: id)
            connectingPeripheralIDs.insert(id)
            promoted.append(deferred)
        }
        lock.unlock()

        for deferred in promoted {
            Reticulum.log("[BLEMesh] peer \(Self.short(deferred.peripheral.identifier.uuidString))… (\"\(deferred.displayName)\") hasn't connected to us within \(Int(Self.deferralTimeout))s of yielding to them — connecting ourselves instead", level: .info)
            deferred.peripheral.delegate = self
            central?.connect(deferred.peripheral, options: nil)
            scheduleConnectTimeout(for: deferred.peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Reticulum.log("[BLEMesh] GATT-connected to \(Self.short(peripheral.identifier.uuidString))… — discovering mesh service", level: .info)
        peripheral.discoverServices([Self.meshSvcUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        Reticulum.log("[BLEMesh] failed to connect to \(Self.short(peripheral.identifier.uuidString))…: \(error?.localizedDescription ?? "no error reported")", level: .warning)
        lock.lock()
        connectingPeripheralIDs.remove(peripheral.identifier)
        deferredPeripherals.removeValue(forKey: peripheral.identifier)
        lock.unlock()
        // CoreBluetooth keeps scanning (we never stop it); if the peer is
        // still advertising it'll surface again via `didDiscover`, and
        // `connectionDecision` will re-run the election from scratch.
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        let peerID = peripheral.identifier.uuidString
        Reticulum.log("[BLEMesh] GATT link to \(Self.short(peerID))… dropped\(error.map { ": \($0.localizedDescription)" } ?? "")", level: .notice)

        lock.lock()
        connectingPeripheralIDs.remove(peripheral.identifier)
        deferredPeripherals.removeValue(forKey: peripheral.identifier)
        let wasLinked = centralLinks.removeValue(forKey: peerID) != nil
        pendingCentralWrites.removeValue(forKey: peerID)
        lock.unlock()

        if wasLinked {
            peerDisconnected?(peerID)
        }
        // No explicit reconnect loop: scanning never stops, so a peer that
        // wanders back into range is rediscovered and relinked automatically
        // — the same passive-recovery model AutoInterface relies on for its
        // UDP peer table.
    }
}

// MARK: - CBPeripheralDelegate (GATT setup + inbound bytes for links where we are central)

extension CoreBluetoothMeshTransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let peerID = peripheral.identifier.uuidString
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.meshSvcUUID }) else {
            Reticulum.log("[BLEMesh] \(Self.short(peerID))… has no mesh service — abandoning link\(error.map { ": \($0.localizedDescription)" } ?? "")", level: .warning)
            abandonCentralLink(to: peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.meshRxUUID, Self.meshTxUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        let characteristics = service.characteristics ?? []
        let peerID = peripheral.identifier.uuidString
        guard error == nil,
              let rx = characteristics.first(where: { $0.uuid == Self.meshRxUUID }),
              let tx = characteristics.first(where: { $0.uuid == Self.meshTxUUID }) else {
            Reticulum.log("[BLEMesh] \(Self.short(peerID))… missing mesh RX/TX characteristics — abandoning link\(error.map { ": \($0.localizedDescription)" } ?? "")", level: .warning)
            abandonCentralLink(to: peripheral)
            return
        }

        lock.lock()
        connectingPeripheralIDs.remove(peripheral.identifier)
        centralLinks[peerID] = CentralLink(peripheral: peripheral, rxChar: rx, txChar: tx)
        lock.unlock()

        Reticulum.log("[BLEMesh] mesh link UP with \(Self.short(peerID))… (we are central)", level: .notice)

        // Enable inbound notifications before announcing the peer as
        // reachable — mirrors `BLEMeshInterface.start` wiring its callbacks
        // before `transport.start()`, for the same reason: don't let early
        // bytes race past the point where we're ready to receive them.
        peripheral.setNotifyValue(true, for: tx)
        peerConnected?(peerID)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil,
              characteristic.uuid == Self.meshTxUUID,
              let data = characteristic.value else { return }
        peerDataHandler?(peripheral.identifier.uuidString, data)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            Reticulum.log("[BLEMesh] notify enable failed: \(error)", level: .error)
        }
    }

    /// CoreBluetooth's transmit buffer has drained enough to accept more
    /// write-without-response data — the central-role mirror of
    /// `peripheralManagerIsReady(toUpdateSubscribers:)`, and the other half
    /// of the `drainCentralWrites` fix (see its doc comment for the full
    /// story of why this callback existing — and previously going
    /// unimplemented — *is* the "sending doesn't work" bug).
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        let peerID = peripheral.identifier.uuidString
        lock.lock()
        let link = centralLinks[peerID]
        lock.unlock()
        guard let link else { return }
        drainCentralWrites(for: peerID, link: link)
    }

    /// GATT setup didn't complete — drop the half-formed link bookkeeping and
    /// let CoreBluetooth tear the connection down. No `peerConnected` was
    /// ever fired for it, so no `peerDisconnected` is owed either.
    private func abandonCentralLink(to peripheral: CBPeripheral) {
        lock.lock()
        connectingPeripheralIDs.remove(peripheral.identifier)
        lock.unlock()
        central?.cancelPeripheralConnection(peripheral)
    }
}

// MARK: - CBPeripheralManagerDelegate (peripheral role: advertise, accept writes, manage subscribers)

extension CoreBluetoothMeshTransport: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Reticulum.log("[BLEMesh] peripheral radio: \(Self.describe(peripheral.state))", level: .info)

        lock.lock()
        let alreadyAdded = serviceAdded
        if peripheral.state == .poweredOn { serviceAdded = true }
        lock.unlock()

        radioStateHandler?(peripheral.state)
        guard peripheral.state == .poweredOn, !alreadyAdded else { return }

        Reticulum.log("[BLEMesh] publishing mesh GATT service \(Self.meshSvcUUID.uuidString.prefix(8))…", level: .info)

        let rx = CBMutableCharacteristic(
            type: Self.meshRxUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let tx = CBMutableCharacteristic(
            type: Self.meshTxUUID,
            properties: [.notify],
            value: nil,
            permissions: []
        )

        lock.lock()
        txCharacteristic = tx
        lock.unlock()

        let service = CBMutableService(type: Self.meshSvcUUID, primary: true)
        service.characteristics = [rx, tx]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            Reticulum.log("[BLEMesh] failed to publish mesh service: \(error)", level: .error)
            return
        }
        Reticulum.log("[BLEMesh] mesh service published — advertising as \"\(advertisedName)\"", level: .info)
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.meshSvcUUID],
            CBAdvertisementDataLocalNameKey: advertisedName
        ])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didStartAdvertising error: Error?) {
        if let error {
            Reticulum.log("[BLEMesh] failed to start advertising: \(error.localizedDescription)", level: .error)
        } else {
            Reticulum.log("[BLEMesh] advertising mesh service to nearby peers", level: .info)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests where request.characteristic.uuid == Self.meshRxUUID {
            if let value = request.value {
                peerDataHandler?(request.central.identifier.uuidString, value)
            }
        }
        // ATT requires every batched request to be acknowledged exactly once;
        // since we accept all well-formed writes uniformly, responding to the
        // first with `.success` satisfies the whole batch (per
        // `CBPeripheralManagerDelegate.peripheralManager(_:didReceiveWrite:)`).
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.meshTxUUID else { return }
        let peerID = central.identifier.uuidString

        lock.lock()
        let isNew = subscriptions[peerID] == nil
        subscriptions[peerID] = central
        lock.unlock()

        // Subscription is what makes this peer *sendable* (notifications are
        // the only way we can push to a peripheral-role link), so that's the
        // right moment to announce it — mirrors how the central-role side
        // waits for characteristic discovery before calling `peerConnected`.
        if isNew {
            Reticulum.log("[BLEMesh] mesh link UP with \(Self.short(peerID))… (we are peripheral)", level: .notice)
            peerConnected?(peerID)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.meshTxUUID else { return }
        let peerID = central.identifier.uuidString

        lock.lock()
        let wasSubscribed = subscriptions.removeValue(forKey: peerID) != nil
        pendingNotifications.removeValue(forKey: peerID)
        lock.unlock()

        if wasSubscribed {
            Reticulum.log("[BLEMesh] mesh link DOWN with \(Self.short(peerID))… (peripheral role — unsubscribed)", level: .notice)
            peerDisconnected?(peerID)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        lock.lock()
        let snapshot = subscriptions
        lock.unlock()

        for (peer, central) in snapshot {
            drainNotifications(for: peer, to: central)
        }
    }
}

// MARK: - Errors

enum CoreBluetoothMeshError: Error, LocalizedError {
    case unknownPeer
    case notConnected

    var errorDescription: String? {
        switch self {
        case .unknownPeer:  return "Unknown mesh peer"
        case .notConnected: return "Mesh peer link is not connected"
        }
    }
}
