//===----------------------------------------------------------------------===//
// Copyright (c) 2026 RetiOS contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import CoreBluetooth
import Foundation
import Observation
import ReticulumSwift

// MARK: - RNodeScannerController

/// Manages BLE scanning, connection, GATT setup, and RNodeInterface lifecycle.
///
/// State machine:
///   idle → scanning → connecting → discoveringServices
///       → detecting → online; any error or dropped link → failed
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
      case .idle: return "Idle"
      case .bluetoothUnavailable: return "Bluetooth unavailable"
      case .scanning: return "Scanning…"
      case .connecting(let n): return "Connecting to \(n)…"
      case .discoveringServices(let n): return "Setting up \(n)…"
      case .detecting(let n): return "Detecting \(n)…"
      case .online(let n): return "Connected: \(n)"
      case .failed(let e): return "Failed: \(e)"
      }
    }

    var isOnline: Bool {
      if case .online = self { return true }
      return false
    }

    /// A peripheral is connected or being connected, so Disconnect applies.
    var hasLink: Bool {
      switch self {
      case .connecting, .discoveringServices, .detecting, .online: return true
      default: return false
      }
    }
  }

  private(set) var state: ConnectionState = .idle
  private(set) var discovered: [DiscoveredDevice] = []
  private(set) var rNodeInterface: RNodeInterface?

  /// Called after this controller adds or removes its interface from
  /// `Transport`—see `BLEMeshController.onInterfacesChanged`.
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
  @ObservationIgnored private var radio: RNodeRadioSettings?

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

  func connect(to device: DiscoveredDevice, radio: RNodeRadioSettings) {
    guard let central, central.state == .poweredOn else { return }
    central.stopScan()
    self.radio = radio
    connectingPeripheral = device.peripheral
    state = .connecting(device.name)
    central.connect(device.peripheral, options: nil)
  }

  func disconnect() {
    if let p = connectingPeripheral { central?.cancelPeripheralConnection(p) }
    teardown()
  }

  /// Ends a failed attempt.
  ///
  /// Drops the link first, so the RNode isn't left connected and unusable.
  private func fail(_ reason: String) {
    disconnect()
    state = .failed(reason)
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
    bleTransport = nil
    connectingPeripheral = nil
    state = .idle
  }

  /// Brings the RNode up once its UART characteristics are found.
  ///
  /// `RNodeInterface.start()` detects the device, sends the radio settings and
  /// checks that the device echoes them back, then reports the outcome.
  private func onGATTReady(peripheral: CBPeripheral, tx: CBCharacteristic, rx: CBCharacteristic) {
    guard let radio else { return fail("No radio settings") }
    let transport = BLERNodeTransport(peripheral: peripheral, txChar: tx, rxChar: rx)
    bleTransport = transport

    let ifaceName = peripheral.name ?? "RNode"
    let iface = RNodeInterface(name: ifaceName, transport: transport)
    iface.frequency = radio.frequency
    iface.bandwidth = radio.bandwidth
    iface.sf = radio.spreadingFactor
    iface.cr = radio.codingRate
    iface.txPower = radio.txPower
    rNodeInterface = iface
    state = .detecting(ifaceName)

    do {
      try iface.start()
    } catch {
      return fail(error.localizedDescription)
    }

    // The wait blocks, so it runs off the main thread.
    let timeout = iface.detectTimeout + iface.validateTimeout + 1
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let online = iface.waitUntilOnline(timeout: timeout)
      DispatchQueue.main.async {
        guard let self, self.rNodeInterface === iface else { return }
        guard online else {
          return self.fail(
            iface.detected
              ? "The RNode did not accept these radio settings. Check that its band covers "
                + "the frequency and that it supports the TX power."
              : "RNode did not respond")
        }
        self.reticulumTransport?.register(interface: iface)
        self.onInterfacesChanged?()
        self.state = .online(ifaceName)
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
        // wait for user tap
        if case .scanning = self.state { self.beginScan() } else if case .idle = self.state {}
      case .poweredOff, .resetting:
        self.state = .idle
      case .unauthorized, .unsupported:
        self.state = .bluetoothUnavailable
      default:
        break
      }
    }
  }

  nonisolated func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi: NSNumber
  ) {
    let name =
      peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "RNode"
    let device = DiscoveredDevice(
      id: peripheral.identifier, name: name,
      rssi: rssi.intValue, peripheral: peripheral)
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if let idx = self.discovered.firstIndex(where: { $0.id == device.id }) {
        self.discovered[idx] = device
      } else {
        self.discovered.append(device)
      }
    }
  }

  nonisolated func centralManager(
    _ central: CBCentralManager,
    didConnect peripheral: CBPeripheral
  ) {
    let name = peripheral.name ?? "RNode"
    DispatchQueue.main.async { [weak self] in
      self?.state = .discoveringServices(name)
    }
    peripheral.delegate = self
    peripheral.discoverServices([BLERNodeTransport.nusSvcUUID])
  }

  nonisolated func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    let msg = error?.localizedDescription ?? "Connection failed"
    DispatchQueue.main.async { [weak self] in self?.fail(msg) }
  }

  nonisolated func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    DispatchQueue.main.async { [weak self] in
      // A disconnect this controller asked for has already torn down.
      guard let self, self.connectingPeripheral?.identifier == peripheral.identifier else { return }
      Reticulum.log("[BLE] RNode disconnected", level: .notice)
      self.fail("RNode disconnected")
    }
  }
}

// MARK: - CBPeripheralDelegate

extension RNodeScannerController: CBPeripheralDelegate {

  nonisolated func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverServices error: Error?
  ) {
    if let error {
      let msg = error.localizedDescription
      DispatchQueue.main.async { [weak self] in self?.fail(msg) }
      return
    }
    guard let svc = peripheral.services?.first(where: { $0.uuid == BLERNodeTransport.nusSvcUUID })
    else {
      DispatchQueue.main.async { [weak self] in self?.fail("Nordic UART service not found") }
      return
    }
    peripheral.discoverCharacteristics(
      [BLERNodeTransport.nusRxUUID, BLERNodeTransport.nusTxUUID], for: svc)
  }

  nonisolated func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    if let error {
      let msg = error.localizedDescription
      DispatchQueue.main.async { [weak self] in self?.fail(msg) }
      return
    }
    let chars = service.characteristics ?? []
    guard let tx = chars.first(where: { $0.uuid == BLERNodeTransport.nusTxUUID }),
      let rx = chars.first(where: { $0.uuid == BLERNodeTransport.nusRxUUID })
    else {
      DispatchQueue.main.async { [weak self] in self?.fail("UART characteristics not found") }
      return
    }
    Task { @MainActor [weak self] in
      self?.onGATTReady(peripheral: peripheral, tx: tx, rx: rx)
    }
  }
}

// MARK: - RNodeRadioSettings

/// LoRa parameters applied to the RNode before bring-up.
///
/// There is no default frequency. The legal band depends on the user's region,
/// so the radio stays down until one is entered.
struct RNodeRadioSettings {
  var frequency: UInt32
  var bandwidth: UInt32
  var spreadingFactor: Int
  var codingRate: Int
  var txPower: Int

  /// Bandwidths the RNode firmware accepts, in Hz. 203.125 kHz and the steps
  /// above 500 kHz are SX128x (2.4 GHz) only.
  static let bandwidths: [UInt32] = [
    7_800, 10_400, 15_600, 20_800, 31_250, 41_700, 62_500, 125_000, 203_125, 250_000,
    406_250, 500_000, 812_500, 1_625_000,
  ]

  /// Parses a frequency typed in MHz, with either decimal separator.
  ///
  /// Nil when empty, malformed, or outside the range the firmware tunes.
  static func frequency(megahertz text: String) -> UInt32? {
    let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    guard let mhz = Double(cleaned) else { return nil }
    let hz = (mhz * 1_000_000).rounded()
    guard hz >= Double(RNodeInterface.freqMin), hz <= Double(RNodeInterface.freqMax) else {
      return nil
    }
    return UInt32(hz)
  }
}
