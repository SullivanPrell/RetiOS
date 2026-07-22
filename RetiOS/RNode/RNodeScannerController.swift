import Foundation
import Observation
import CoreBluetooth
import ReticulumSwift

// MARK: - RNodeScannerController

/// Manages BLE scanning, connection, GATT setup, and RNodeInterface lifecycle.
///
/// State machine:
///   idle → scanning → connecting → discoveringServices
///       → discoveringCharacteristics → detecting → online → idle (on disconnect)
@MainActor
@Observable
final class RNodeScannerController: NSObject {

    // MARK: - Published state

    enum ConnectionState: Equatable {
        case idle
        case bluetoothUnavailable
        case scanning
        case connecting(String)
        case discoveringServices(String)
        case detecting(String)
        case online(String)
        case failed(String)

        var label: String {
            switch self {
            case .idle:                        return "Idle"
            case .bluetoothUnavailable:        return "Bluetooth unavailable"
            case .scanning:                    return "Scanning…"
            case .connecting(let n):           return "Connecting to \(n)…"
            case .discoveringServices(let n):  return "Setting up \(n)…"
            case .detecting(let n):            return "Detecting \(n)…"
            case .online(let n):               return "Connected: \(n)"
            case .failed(let e):               return "Failed: \(e)"
            }
        }

        var isOnline: Bool {
            if case .online = self { return true }
            return false
        }
    }

    private(set) var state: ConnectionState = .idle
    private(set) var discovered: [DiscoveredDevice] = []
    private(set) var rNodeInterface: RNodeInterface?

    /// Called after this controller adds or removes its interface from
    /// `Transport` — see `BLEMeshController.onInterfacesChanged`.
    @ObservationIgnored var onInterfacesChanged: (() -> Void)?

    // MARK: - Discovered device

    struct DiscoveredDevice: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
        let peripheral: CBPeripheral

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    // MARK: - Private

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var connectingPeripheral: CBPeripheral?
    @ObservationIgnored private var bleTransport: BLERNodeTransport?
    @ObservationIgnored private var reticulumTransport: Transport?

    @ObservationIgnored private let bleQueue = DispatchQueue(label: "RNodeScanner.ble")

    // MARK: - Public API

    func setup(transport: Transport) {
        reticulumTransport = transport
    }

    func startScanning() {
        discovered = []
        if central == nil {
            // Record scan intent *before* the async power-on. A freshly created
            // central starts in .unknown and only reports .poweredOn later via
            // centralManagerDidUpdateState, which begins scanning only when
            // state == .scanning. Without setting it here the very first tap
            // creates the central but never scans (state stays .idle), so the
            // screen looks broken until a second tap. The delegate resets this
            // to .idle / .bluetoothUnavailable if the radio isn't actually on.
            state = .scanning
            central = CBCentralManager(delegate: self, queue: bleQueue)
        } else if central?.state == .poweredOn {
            beginScan()
        }
    }

    func stopScanning() {
        central?.stopScan()
        if case .scanning = state { state = .idle }
    }

    func connect(to device: DiscoveredDevice) {
        guard let central, central.state == .poweredOn else { return }
        central.stopScan()
        connectingPeripheral = device.peripheral
        state = .connecting(device.name)
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        if let p = connectingPeripheral { central?.cancelPeripheralConnection(p) }
        teardown()
    }

    // MARK: - Private helpers

    private func beginScan() {
        state = .scanning
        central?.scanForPeripherals(
            withServices: [BLERNodeTransport.nusSvcUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func teardown() {
        if let iface = rNodeInterface {
            iface.stop()
            reticulumTransport?.deregister(interface: iface)
            onInterfacesChanged?()
        }
        rNodeInterface = nil
        bleTransport   = nil
        connectingPeripheral = nil
        state = .idle
    }

    /// Called on the BLE queue; hops to main before mutating state.
    private func onGATTReady(peripheral: CBPeripheral, tx: CBCharacteristic, rx: CBCharacteristic) {
        let transport = BLERNodeTransport(peripheral: peripheral, txChar: tx, rxChar: rx)
        bleTransport = transport

        let ifaceName = peripheral.name ?? "RNode"
        let iface = RNodeInterface(name: ifaceName, transport: transport)

        do {
            try iface.start()          // enables TX notifications
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.state = .failed(error.localizedDescription)
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rNodeInterface = iface
            self.state = .detecting(ifaceName)
        }

        // Detect: send probe, poll up to 5 s for response.
        Task { [weak self, weak iface] in
            guard let self, let iface else { return }
            do {
                try iface.detect()
                var attempts = 0
                while !iface.detected && attempts < 50 {
                    try await Task.sleep(for: .milliseconds(100))
                    attempts += 1
                }
                guard iface.detected else {
                    await MainActor.run { self.state = .failed("RNode did not respond to detect") }
                    return
                }
                try iface.initRadio()
                if let rns = self.reticulumTransport {
                    rns.register(interface: iface)
                    await MainActor.run { self.onInterfacesChanged?() }
                }
                await MainActor.run { self.state = .online(ifaceName) }
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension RNodeScannerController: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch central.state {
            case .poweredOn:
                if case .scanning = self.state { self.beginScan() }
                else if case .idle = self.state { } // wait for user tap
            case .poweredOff, .resetting:
                self.state = .idle
            case .unauthorized, .unsupported:
                self.state = .bluetoothUnavailable
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "RNode"
        let device = DiscoveredDevice(id: peripheral.identifier, name: name,
                                       rssi: RSSI.intValue, peripheral: peripheral)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let idx = self.discovered.firstIndex(where: { $0.id == device.id }) {
                self.discovered[idx] = device
            } else {
                self.discovered.append(device)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        let name = peripheral.name ?? "RNode"
        DispatchQueue.main.async { [weak self] in
            self?.state = .discoveringServices(name)
        }
        peripheral.delegate = self
        peripheral.discoverServices([BLERNodeTransport.nusSvcUUID])
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        let msg = error?.localizedDescription ?? "Connection failed"
        DispatchQueue.main.async { [weak self] in self?.state = .failed(msg) }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.rNodeInterface != nil {
                Reticulum.log("[BLE] RNode disconnected", level: .notice)
            }
            self.teardown()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension RNodeScannerController: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        guard error == nil else {
            let msg = error!.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.state = .failed(msg) }
            return
        }
        guard let svc = peripheral.services?.first(where: { $0.uuid == BLERNodeTransport.nusSvcUUID }) else {
            DispatchQueue.main.async { [weak self] in
                self?.state = .failed("Nordic UART service not found")
            }
            return
        }
        peripheral.discoverCharacteristics([BLERNodeTransport.nusRxUUID, BLERNodeTransport.nusTxUUID], for: svc)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        guard error == nil else {
            let msg = error!.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.state = .failed(msg) }
            return
        }
        let chars = service.characteristics ?? []
        guard let tx = chars.first(where: { $0.uuid == BLERNodeTransport.nusTxUUID }),
              let rx = chars.first(where: { $0.uuid == BLERNodeTransport.nusRxUUID }) else {
            DispatchQueue.main.async { [weak self] in
                self?.state = .failed("UART characteristics not found")
            }
            return
        }
        Task { @MainActor [weak self] in
            self?.onGATTReady(peripheral: peripheral, tx: tx, rx: rx)
        }
    }
}
