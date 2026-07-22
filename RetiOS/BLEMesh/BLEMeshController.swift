import Foundation
import Observation
import CoreBluetooth
import ReticulumSwift

// MARK: - BLEMeshController

/// Manages the BLE mesh radio lifecycle and `BLEMeshInterface` registration —
/// the BLE-mesh counterpart to `RNodeScannerController`.
///
/// ## Why this state machine looks different from RNode's
///
/// `RNodeScannerController` walks through a multi-step pairing flow because
/// it's connecting to *one specific piece of hardware* the user picks from a
/// scan list: scan → connect → discover services → discover characteristics
/// → detect firmware → online.
///
/// A BLE mesh has no such device to pick — every nearby phone running this
/// app *is* a peer, arriving and leaving on its own schedule. So there's
/// nothing to "connect to": the user simply switches meshing on, and from
/// then on `CoreBluetoothMeshTransport` discovers and links with whoever it
/// finds, fully automatically. This controller's job shrinks accordingly —
/// it owns enable/disable, surfaces Bluetooth-availability, and republishes
/// `BLEMeshInterface.peerCount` for the UI. The actual peer table lives in
/// `BLEMeshInterface`/`CoreBluetoothMeshTransport`, exactly as the RNode
/// radio-config readout lives in `RNodeInterface`, not the scanner.
@MainActor
@Observable
final class BLEMeshController: NSObject {

    // MARK: - Published state

    enum MeshState: Equatable {
        case idle
        case bluetoothUnavailable
        case starting
        case online
        case failed(String)

        var label: String {
            switch self {
            case .idle:                  return "Off"
            case .bluetoothUnavailable:  return "Bluetooth unavailable"
            case .starting:              return "Starting…"
            case .online:                return "Meshing"
            case .failed(let reason):    return "Failed: \(reason)"
            }
        }

        var isOnline: Bool {
            if case .online = self { return true }
            return false
        }
    }

    private(set) var state: MeshState = .idle
    private(set) var peerCount: Int = 0
    private(set) var meshInterface: BLEMeshInterface?
    private(set) var enableOnStart: Bool = {
        UserDefaults.standard.bool(forKey: "bleMeshEnableOnStart")
    }()

    // MARK: - Private

    @ObservationIgnored private var bleTransport: CoreBluetoothMeshTransport?
    @ObservationIgnored private var reticulumTransport: Transport?
    @ObservationIgnored private var peerPollTask: Task<Void, Never>?
    private static let enableOnStartKey = "bleMeshEnableOnStart"

    // MARK: - Public API

    func setup(transport: Transport) {
        reticulumTransport = transport
    }

    func setEnableOnStart(_ enabled: Bool) {
        enableOnStart = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enableOnStartKey)
    }

    /// Switches the mesh radio on: brings up dual-role CoreBluetooth
    /// (advertise as peripheral + scan as central, both inside
    /// `CoreBluetoothMeshTransport`), starts a fresh `BLEMeshInterface` over
    /// it, and registers that interface with `Transport` so the wider
    /// Reticulum stack can route through it.
    ///
    /// - Parameter localName: advertised name nearby peers will see (e.g. the
    ///   node's display name) — purely cosmetic, has no protocol meaning.
    func enable(localName: String) {
        guard !state.isOnline, state != .starting else { return }
        state = .starting

        let transport = CoreBluetoothMeshTransport(localName: localName)
        transport.radioStateHandler = { [weak self] cbState in
            DispatchQueue.main.async { [weak self] in
                self?.handleRadioStateChange(cbState)
            }
        }

        let iface = BLEMeshInterface(name: "ble-mesh", transport: transport)
        do {
            try iface.start()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        bleTransport = transport
        meshInterface = iface
        reticulumTransport?.register(interface: iface)
        state = .online
        startPeerPolling()
    }

    /// Switches the mesh off: stops the interface, deregisters it, and tears
    /// down all CoreBluetooth state (mirrors `RNodeScannerController.teardown`).
    func disable() {
        peerPollTask?.cancel()
        peerPollTask = nil

        if let iface = meshInterface {
            iface.stop()
            reticulumTransport?.deregister(interface: iface)
        }

        meshInterface = nil
        bleTransport = nil
        peerCount = 0
        if state != .bluetoothUnavailable {
            state = .idle
        }
    }

    // MARK: - Private helpers

    private func handleRadioStateChange(_ cbState: CBManagerState) {
        // Ignore stale callbacks from a transport we've already torn down —
        // `disable()`/a fresh `enable()` may have raced this notification.
        guard bleTransport != nil else { return }

        switch cbState {
        case .poweredOn:
            if state == .starting { state = .online }
        case .unauthorized, .unsupported:
            state = .bluetoothUnavailable
        case .poweredOff, .resetting:
            // Mirrors RNodeScannerController's `case .poweredOff, .resetting:
            // self.state = .idle` — the radio is gone, so the link is too;
            // tear everything down rather than limping along with a half-dead
            // interface. The user can switch meshing back on once Bluetooth
            // returns (CoreBluetooth doesn't reliably resurrect existing
            // managers across a full power cycle).
            disable()
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    /// `BLEMeshInterface.peerCount` is a thread-safe snapshot, not a
    /// publisher. Polling at UI-refresh cadence is the simplest correct way
    /// to keep `peerCount` current — wiring up a bespoke
    /// peer-table change notification through `BLEMeshTransport` would add
    /// real protocol surface for what is purely a display nicety.
    private func startPeerPolling() {
        peerPollTask?.cancel()
        peerPollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard self.state.isOnline, let iface = self.meshInterface else { return }
                // Assign only on change. sends objectWillChange for
                // EVERY assignment, equal or not — writing unconditionally
                // re-rendered every view observing this controller once a
                // second for as long as the mesh stayed online, even though the
                // peer count almost never changes between ticks.
                let count = iface.peerCount
                if self.peerCount != count { self.peerCount = count }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
