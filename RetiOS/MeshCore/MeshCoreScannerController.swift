import Foundation
import CoreBluetooth
import ReticulumSwift
import RNSOverMeshCore

// MARK: - MeshCoreScannerController

/// Scans for MeshCore companion devices over BLE, connects, discovers the
/// companion NUS characteristics, then builds a `MeshCoreDynamicInterface`
/// (`MeshCoreClient` over `CoreBluetoothMeshCoreTransport`) with the user's channel
/// settings and registers it with the Reticulum `Transport`.
///
/// Mirrors `RNodeScannerController`'s scan → connect → GATT → interface lifecycle;
/// the difference is MeshCore's interface bring-up is `async` (companion handshake:
/// app-start, set-channel, optional set-radio) so it runs in a `Task`.
@MainActor
final class MeshCoreScannerController: NSObject, ObservableObject {

    // MARK: Published state

    enum ConnectionState: Equatable {
        case idle
        case bluetoothUnavailable
        case scanning
        case connecting(String)
        case discoveringServices(String)
        case bringingUp(String)
        case online(String)
        case failed(String)

        var label: String {
            switch self {
            case .idle:                       return "Idle"
            case .bluetoothUnavailable:       return "Bluetooth unavailable"
            case .scanning:                   return "Scanning…"
            case .connecting(let n):          return "Connecting to \(n)…"
            case .discoveringServices(let n): return "Setting up \(n)…"
            case .bringingUp(let n):          return "Joining channel via \(n)…"
            case .online(let n):              return "Connected: \(n)"
            case .failed(let e):              return "Failed: \(e)"
            }
        }

        var isOnline: Bool { if case .online = self { return true }; return false }
    }

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var discovered: [DiscoveredDevice] = []
    @Published private(set) var meshInterface: MeshCoreDynamicInterface?

    // MARK: Editable channel configuration (bound by MeshCoreView)

    @Published var interfaceName: String = "MeshCore"
    @Published var channelName: String = "RNSTunnel"
    @Published var channelSecretHex: String = ""
    @Published var channelIndex: Int = 0
    /// access_point mode is recommended on LoRa segments (see RNSOverMeshCore README).
    @Published var accessPointMode: Bool = true
    @Published var canRoute: Bool = true

    /// True when `channelSecretHex` is a valid 16-byte (32 hex char) secret.
    var secretIsValid: Bool {
        let s = channelSecretHex.trimmingCharacters(in: .whitespaces)
        return s.count == 32 && s.allSatisfy { $0.isHexDigit }
    }

    // MARK: Discovered device

    struct DiscoveredDevice: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
        let peripheral: CBPeripheral
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    // MARK: Private

    private var central: CBCentralManager?
    private var connectingPeripheral: CBPeripheral?
    private var meshTransport: CoreBluetoothMeshCoreTransport?
    private var reticulumTransport: Transport?
    private weak var stack: StackController?
    private let bleQueue = DispatchQueue(label: "MeshCoreScanner.ble")

    // MARK: Public API

    /// Wire the Reticulum transport and pre-fill the channel form from any saved
    /// MeshCore config.
    func setup(transport: Transport, stack: StackController) {
        reticulumTransport = transport
        self.stack = stack
        if let saved = stack.savedMeshCoreConfig {
            interfaceName    = saved.name
            channelName      = saved.channelName
            channelSecretHex = saved.channelSecretHex
            channelIndex     = saved.channelIndex
            accessPointMode  = saved.accessPoint
            canRoute         = saved.canRoute
        }
    }

    func startScanning() {
        discovered = []
        if central == nil {
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

    // MARK: Private helpers

    private func beginScan() {
        state = .scanning
        central?.scanForPeripherals(
            withServices: [CoreBluetoothMeshCoreTransport.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func teardown() {
        if let iface = meshInterface {
            iface.stop()
            reticulumTransport?.deregister(interface: iface)
        }
        meshInterface = nil
        meshTransport = nil
        connectingPeripheral = nil
        state = .idle
    }

    private func buildConfig() -> MeshCoreDynamicConfig {
        var c = MeshCoreDynamicConfig()
        c.name             = interfaceName
        c.channelName      = channelName
        c.channelSecretHex = channelSecretHex.trimmingCharacters(in: .whitespaces)
        c.channelIndex     = channelIndex
        c.canRoute         = canRoute
        c.mode             = accessPointMode ? .accessPoint : .full
        return c
    }

    /// Called after GATT characteristics are discovered: build the transport +
    /// companion + interface, bring it up (async companion handshake), register it,
    /// and persist the channel config.
    private func onGATTReady(peripheral: CBPeripheral, tx: CBCharacteristic, rx: CBCharacteristic) {
        let transport = CoreBluetoothMeshCoreTransport(peripheral: peripheral, txChar: tx, rxChar: rx)
        let companion = MeshCoreClient(transport: transport)
        let iface = MeshCoreDynamicInterface(companion: companion, config: buildConfig())
        meshTransport = transport
        meshInterface = iface

        let name = peripheral.name ?? "MeshCore"
        state = .bringingUp(name)

        Task { [weak self, weak iface] in
            guard let self, let iface else { return }
            do {
                try await iface.bringUp()          // app-start, set-channel, set-radio, loops
                if let rns = self.reticulumTransport { rns.register(interface: iface) }
                self.stack?.saveMeshCoreConfig(self.currentSavedConfig(deviceUUID: peripheral.identifier))
                self.state = .online(name)
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func currentSavedConfig(deviceUUID: UUID) -> StackController.SavedMeshCoreConfig {
        StackController.SavedMeshCoreConfig(
            name: interfaceName, channelName: channelName,
            channelSecretHex: channelSecretHex.trimmingCharacters(in: .whitespaces),
            channelIndex: channelIndex, accessPoint: accessPointMode,
            canRoute: canRoute, deviceUUID: deviceUUID.uuidString
        )
    }
}

// MARK: - CBCentralManagerDelegate

extension MeshCoreScannerController: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch central.state {
            case .poweredOn:
                if case .scanning = self.state { self.beginScan() }
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
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "MeshCore"
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

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let name = peripheral.name ?? "MeshCore"
        DispatchQueue.main.async { [weak self] in self?.state = .discoveringServices(name) }
        peripheral.delegate = self
        peripheral.discoverServices([CoreBluetoothMeshCoreTransport.serviceUUID])
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let msg = error?.localizedDescription ?? "Connection failed"
        DispatchQueue.main.async { [weak self] in self?.state = .failed(msg) }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.meshTransport?.peripheralDidDisconnect(error)
            if self.meshInterface != nil {
                Reticulum.log("[MeshCore] companion disconnected", level: .notice)
            }
            self.teardown()
        }
    }
}

// MARK: - CBPeripheralDelegate (service/characteristic discovery)

extension MeshCoreScannerController: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            let msg = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.state = .failed(msg) }
            return
        }
        guard let svc = peripheral.services?.first(where: { $0.uuid == CoreBluetoothMeshCoreTransport.serviceUUID }) else {
            DispatchQueue.main.async { [weak self] in self?.state = .failed("MeshCore companion service not found") }
            return
        }
        peripheral.discoverCharacteristics(
            [CoreBluetoothMeshCoreTransport.rxUUID, CoreBluetoothMeshCoreTransport.txUUID], for: svc)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            let msg = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.state = .failed(msg) }
            return
        }
        let chars = service.characteristics ?? []
        guard let tx = chars.first(where: { $0.uuid == CoreBluetoothMeshCoreTransport.txUUID }),
              let rx = chars.first(where: { $0.uuid == CoreBluetoothMeshCoreTransport.rxUUID }) else {
            DispatchQueue.main.async { [weak self] in self?.state = .failed("Companion characteristics not found") }
            return
        }
        Task { @MainActor [weak self] in self?.onGATTReady(peripheral: peripheral, tx: tx, rx: rx) }
    }
}
