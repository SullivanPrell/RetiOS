import Foundation
import CoreBluetooth
import ReticulumSwift

// MARK: - BLERNodeTransport

/// CoreBluetooth implementation of RNodeTransport using the Nordic UART Service (NUS).
///
/// GATT layout:
///   Service  6E400001 — Nordic UART
///     RX char 6E400002 — write (phone → RNode, no response)
///     TX char 6E400003 — notify (RNode → phone)
///
/// write() chunks outbound data to the peripheral's negotiated MTU so BLE
/// packet boundaries don't truncate KISS frames. Incoming notifications
/// are forwarded directly to byteHandler.
final class BLERNodeTransport: NSObject {

    static let nusSvcUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let nusRxUUID  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let nusTxUUID  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    // RNodeTransport requirement
    var byteHandler: ((Data) -> Void)?

    /// RNodeTransport requirement: the interface's device-loss surface.
    ///
    /// Required by the protocol rather than defaulted, because a transport that cannot report
    /// loss leaves its interface Up over a dead radio forever (`bugs/058`). CoreBluetooth
    /// already delivers the signal — a write attempted on a disconnected peripheral, or a
    /// notify that fails — so this is a matter of forwarding what the framework says instead of
    /// dropping it. `RNodeInterface` reacts by going offline and redialling, which is what the
    /// scanner previously did by hand for disconnects it happened to observe.
    var onTransportError: ((Error) -> Void)?

    private let peripheral: CBPeripheral
    private let txChar: CBCharacteristic  // notify: RNode → phone
    private let rxChar: CBCharacteristic  // write:  phone → RNode

    private let writeQueue = DispatchQueue(label: "BLERNodeTransport.write")

    // MARK: - Init

    /// Accepts a connected peripheral with NUS characteristics already discovered.
    init(peripheral: CBPeripheral, txChar: CBCharacteristic, rxChar: CBCharacteristic) {
        self.peripheral = peripheral
        self.txChar     = txChar
        self.rxChar     = rxChar
        super.init()
        peripheral.delegate = self
    }
}

// MARK: - RNodeTransport

extension BLERNodeTransport: RNodeTransport {

    /// Enable TX notifications so the RNode can push bytes to us.
    func open() throws {
        peripheral.setNotifyValue(true, for: txChar)
    }

    func close() {
        peripheral.setNotifyValue(false, for: txChar)
    }

    /// Chunk data to the negotiated BLE MTU (typically 182 bytes for NUS) and
    /// write each chunk without response for maximum throughput.
    func write(_ data: Data) throws {
        guard peripheral.state == .connected else {
            let error = BLETransportError.notConnected
            onTransportError?(error)
            throw error
        }
        writeQueue.sync {
            let mtu = self.peripheral.maximumWriteValueLength(for: .withoutResponse)
            var offset = data.startIndex
            while offset < data.endIndex {
                let end = data.index(offset, offsetBy: mtu, limitedBy: data.endIndex) ?? data.endIndex
                self.peripheral.writeValue(data[offset..<end], for: self.rxChar, type: .withoutResponse)
                offset = end
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLERNodeTransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil,
              characteristic.uuid == Self.nusTxUUID,
              let data = characteristic.value else { return }
        byteHandler?(data)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let err = error {
            Reticulum.log("[BLERNodeTransport] notify enable failed: \(err)", level: .error)
            // Without the notify subscription the radio can never deliver a byte, so this is
            // device loss even though the connection is nominally up.
            onTransportError?(err)
        }
    }

    /// The peripheral told us a characteristic write failed. On a link that has gone away
    /// CoreBluetooth reports it here rather than by throwing from `writeValue`.
    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let err = error {
            Reticulum.log("[BLERNodeTransport] write failed: \(err)", level: .error)
            onTransportError?(err)
        }
    }
}

// MARK: - Errors

enum BLETransportError: Error, LocalizedError {
    case notConnected
    case detectTimeout

    var errorDescription: String? {
        switch self {
        case .notConnected:   return "BLE peripheral not connected"
        case .detectTimeout:  return "RNode did not respond to detect command"
        }
    }
}
