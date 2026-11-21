//===----------------------------------------------------------------------===//
// Copyright (c) 2026 RetiOS contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import LXMF
import ReticulumSwift
import XCTest

@testable import RetiOS

/// The gravity and stamp settings a Python config file carries in an interface block, in
/// `[reticulum]` and in `[stamps]`, plus LXMF's delivery stamp value.
final class NetworkStampSettingsTests: XCTestCase {
  private let suite = "NetworkStampSettingsTests"
  private let ifaceName = "test-\(UUID().uuidString)"
  private var defaults: UserDefaults!

  override func setUp() {
    defaults = UserDefaults(suiteName: suite)
    defaults.removePersistentDomain(forName: suite)
    Reticulum.storedDefaultGravity = nil
  }

  override func tearDown() {
    IfacPassphraseStore.write(nil, for: ifaceName)
    defaults.removePersistentDomain(forName: suite)
    Reticulum.storedDefaultGravity = nil
  }

  private func makeStack() -> Reticulum {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return Reticulum(configuration: .init(storagePath: dir))
  }

  // MARK: - Per interface

  func testAnInterfaceListSavedByV073DecodesWithNoSettings() throws {
    let json =
      #"[{"name":"\#(ifaceName)","host":"10.0.0.2","port":4242,"kind":"backbone","networkName":"n"}]"#
    defaults.set(Data(json.utf8), forKey: "savedTCPInterfaces")

    let saved = try XCTUnwrap(StackController.loadSavedInterfaces(from: defaults)?.first)
    XCTAssertEqual(saved.host, "10.0.0.2")
    XCTAssertEqual(saved.kind, .backbone)
    XCTAssertEqual(saved.networkName, "n")
    XCTAssertNil(saved.gravity)
    XCTAssertNil(saved.destinationCost)
    XCTAssertNil(saved.prCost)
  }

  func testInterfaceSettingsPersistAndReachTheInterface() throws {
    StackController.persist(
      [
        .init(
          name: ifaceName, host: "h", port: 4242, networkName: "n", passphrase: "p",
          gravity: 3, destinationCost: 250, prCost: 12.5)
      ], to: defaults)
    let saved = try XCTUnwrap(StackController.loadSavedInterfaces(from: defaults)?.first)

    let iface = StackController.makeInterface(for: saved)
    XCTAssertEqual(iface.gravity, 3)
    // Clamped to `STAMP_COST_CAP` (`Reticulum.py:1079-1087`).
    XCTAssertEqual(iface.destinationCost, 100)
    XCTAssertEqual(iface.prCost, 12.5)
    XCTAssertEqual(iface.ifacNetname, "n")
    XCTAssertNotNil(iface.ifacKey)
  }

  func testAnInterfaceWithoutGravityTakesTheDefaultGravity() {
    var settings = StackController.NetworkSettings()
    settings.defaultGravity = 4
    settings.apply(to: makeStack())

    let iface = StackController.makeInterface(for: .init(name: ifaceName, host: "h", port: 1))
    XCTAssertEqual(iface.gravity, 4)
    XCTAssertNil(iface.destinationCost)
    XCTAssertNil(iface.prCost)
  }

  // MARK: - [stamps]

  func testStampSettingsReachTheTransportClampedAsPythonClampsThem() {
    var settings = StackController.NetworkSettings()
    settings.enforceStamps = true
    settings.alwaysStampLRs = true
    settings.destinationCost = 30
    settings.destinationValue = 250
    settings.prCost = -1
    settings.prValue = 14
    settings.lrCost = 60
    settings.lrStampTimeout = 0.001
    settings.prStampTimeout = 20
    let stack = makeStack()
    settings.apply(to: stack)

    let stamps = stack.transport.stamps
    XCTAssertTrue(stamps.enforced)
    XCTAssertTrue(stamps.lrEnforced)
    XCTAssertTrue(stamps.alwaysStampLRs)
    XCTAssertEqual(stamps.destinationCost, 30)
    XCTAssertEqual(stamps.destinationValue, 100)
    XCTAssertEqual(stamps.prCost, 0)
    XCTAssertEqual(stamps.prValue, 14)
    XCTAssertEqual(stamps.lrCost, 40)
    XCTAssertEqual(stamps.linkStampTimeout, 0.020)
    XCTAssertEqual(stamps.prStampTimeout, 20)
  }

  func testUnsetSettingsLeaveTheLibraryDefaults() {
    let stack = makeStack()
    let before = stack.transport.stamps
    StackController.NetworkSettings().apply(to: stack)
    XCTAssertEqual(stack.transport.stamps, before)
    XCTAssertNil(Reticulum.storedDefaultGravity)
  }

  func testNetworkSettingsPersist() {
    XCTAssertEqual(StackController.loadNetworkSettings(from: defaults), .init())

    var settings = StackController.NetworkSettings()
    settings.defaultGravity = 2
    settings.enforceStamps = true
    settings.prValue = 14
    settings.deliveryStampValue = 30
    StackController.persistNetworkSettings(settings, to: defaults)
    XCTAssertEqual(StackController.loadNetworkSettings(from: defaults), settings)
  }

  // MARK: - Wanted types and the LXMF stamp value

  func testTheStackWantsNomadNetNodesAndRRCHubs() {
    let stack = makeStack()
    StackController.NetworkSettings().apply(to: stack)
    for type in ["nomadnetwork.node", "rrc.hub"] {
      XCTAssertTrue(
        stack.transport.unwantsDestinationType(
          type, requester: stack.transport.applicationIdentity.hash), type)
    }
  }

  func testTheDeliveryStampValueReachesTheDeliveryDestination() throws {
    var settings = StackController.NetworkSettings()
    settings.deliveryStampValue = 30
    let transport = makeStack().transport
    let delivery = try LXMRouter(transport: transport).register(
      identity: Identity(), transport: transport, stampValue: settings.deliveryStampValue)
    // Above the default `destination_value` of 25 (`Transport.py:205`).
    XCTAssertEqual(delivery.targetValue(transport.stamps), 30)
  }
}
