//===----------------------------------------------------------------------===//
// Copyright (c) 2026 RetiOS contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import ReticulumSwift
import XCTest

@testable import RetiOS

/// The Interfaces screen's Remove action and its per-interface `rnstatus` block.
@MainActor
final class InterfaceRemovalAndStatusTests: XCTestCase {
  private let suite = "InterfaceRemovalAndStatusTests"
  private var defaults: UserDefaults!

  override func setUp() {
    defaults = UserDefaults(suiteName: suite)
    defaults.removePersistentDomain(forName: suite)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
  }

  func testRemovingTheI2PRowDeletesTheSavedI2PConfig() {
    let stack = StackController()
    stack.defaults = defaults
    stack.saveI2PConfig(.init(name: "test I2P", peers: ["x.b32.i2p"]))
    XCTAssertNotNil(defaults.data(forKey: "savedI2PConfig"))

    stack.removeInterface(named: "test I2P")

    XCTAssertNil(stack.savedI2PConfig)
    XCTAssertNil(defaults.data(forKey: "savedI2PConfig"))
  }

  func testRemovingATCPRowDeletesItsSavedEntry() {
    let stack = StackController()
    stack.defaults = defaults
    stack.saveInterface(name: "test TCP", host: "h", port: 4242)

    stack.removeInterface(named: "test TCP")

    XCTAssertEqual(StackController.loadSavedInterfaces(from: defaults)?.count, 0)
  }

  func testStatusBlockShowsStateGravityAndIfacButNotThePassphrase() throws {
    let transport = Transport()
    let iface = TCPClientInterface(name: "gw", host: "127.0.0.1", port: 1)
    iface.gravity = 3
    let saved = StackController.SavedInterface(
      name: "gw", host: "127.0.0.1", port: 1, networkName: "testnet", passphrase: "hunter2")
    Reticulum.applyIfacConfiguration(to: iface, from: saved.configBlock)
    transport.register(interface: iface)

    let block = try XCTUnwrap(transport.rnstatusBlock(named: "gw"))

    XCTAssertTrue(block.contains("Status    : Down, gravity 3"), block)
    XCTAssertTrue(block.contains("Network   : testnet"), block)
    XCTAssertTrue(block.contains("-bit IFAC by <"), block)
    XCTAssertFalse(block.contains("hunter2"), block)
    XCTAssertNil(transport.rnstatusBlock(named: "absent"))
  }
}
