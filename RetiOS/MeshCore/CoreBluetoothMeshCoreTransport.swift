import Foundation
import CoreBluetooth
import ReticulumSwift
import RNSOverMeshCore

// MARK: - CoreBluetoothMeshCoreTransport

/// CoreBluetooth implementation of `RNSOverMeshCore.MeshCoreTransport` over the
/// MeshCore companion BLE service (a Nordic UART-style GATT layout — the same
/// UUIDs RNode uses).
///
/// GATT layout (from `MeshCoreBLEUUID`):
///   Service  6E400001
///     RX char 6E400002 — write  (app → companion firmware)
///     TX char 6E400003 — notify (companion firmware → app)
///
/// Framing rule (companion protocol): over BLE **each notification/write is exactly
/// one companion frame** — there is *no* `0x3c`/`0x3e` serial length prefix. So each
/// inbound notification is delivered verbatim to `onFrame`, and each outbound frame
/// is written in a single `writeValue` (RNS-tunnel companion frames are ~100 bytes,
/// well under the negotiated MTU, so they never need splitting — splitting would
/// corrupt the one-write-per-frame contract the way RNode's chunking never can).
final class CoreBluetoothMeshCoreTransport: NSObject, MeshCoreTransport {

    static let serviceUUID = CBUUID(string: MeshCoreBLEUUID.service)
    static let rxUUID      = CBUUID(string: MeshCoreBLEUUID.rx)   // app → firmware (write)
    static let txUUID      = CBUUID(string: MeshCoreBLEUUID.tx)   // firmware → app (notify)

    // MeshCoreTransport conformance
    var onFrame: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var isConnected: Bool { peripheral.state == .connected }

    private let peripheral: CBPeripheral
    private let txChar: CBCharacteristic  // notify
    private let rxChar: CBCharacteristic  // write
    private let writeQueue = DispatchQueue(label: "MeshCoreTransport.write")
    private var startContinuation: CheckedContinuation<Void, Error>?

    /// Accepts a connected peripheral with the companion characteristics already discovered.
    init(peripheral: CBPeripheral, txChar: CBCharacteristic, rxChar: CBCharacteristic) {
        self.peripheral = peripheral
        self.txChar     = txChar
        self.rxChar     = rxChar
        super.init()
        peripheral.delegate = self
    }

    // MARK: MeshCoreTransport

    /// The peripheral is already connected (the scanner hands it over ready), so
    /// bring-up enables TX notifications and resolves once the firmware confirms
    /// they are on — so the companion's first `CMD_APP_START` write can't race
    /// ahead of notification delivery and miss the `SELF_INFO` reply.
    func start() async throws {
        guard peripheral.state == .connected else { throw MeshCoreTransportError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            startContinuation = cont
            peripheral.setNotifyValue(true, for: txChar)
        }
    }

    func stop() {
        if peripheral.state == .connected { peripheral.setNotifyValue(false, for: txChar) }
    }

    func send(_ frame: Data) throws {
        guard peripheral.state == .connected else { throw MeshCoreTransportError.notConnected }
        writeQueue.sync {
            self.peripheral.writeValue(frame, for: self.rxChar, type: .withoutResponse)
        }
    }

    /// Invoked by the owning scanner controller when CoreBluetooth reports the
    /// peripheral disconnected (that callback arrives on the `CBCentralManager`
    /// delegate, which the controller owns — not on this peripheral delegate).
    func peripheralDidDisconnect(_ error: Error?) {
        onDisconnect?(error)
    }
}

// MARK: - CBPeripheralDelegate

extension CoreBluetoothMeshCoreTransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil,
              characteristic.uuid == Self.txUUID,
              let data = characteristic.value else { return }
        onFrame?(data)          // one notification == one complete companion frame
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.txUUID else { return }
        if let error {
            Reticulum.log("[MeshCoreTransport] notify enable failed: \(error)", level: .error)
            startContinuation?.resume(throwing: error)
        } else {
            startContinuation?.resume()
        }
        startContinuation = nil
    }
}
