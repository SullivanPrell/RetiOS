//===----------------------------------------------------------------------===//
// Copyright (c) 2026 RetiOS contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import XCTest

@testable import RetiOS

/// IFAC passphrases go to the Keychain.
///
/// UserDefaults is in unencrypted backups, and on a Mac any process running as
/// the user can read it.
final class SavedInterfacePassphraseTests: XCTestCase {
  private let suite = "SavedInterfacePassphraseTests"
  private let ifaceName = "test-\(UUID().uuidString)"
  private var defaults: UserDefaults!

  override func setUp() {
    defaults = UserDefaults(suiteName: suite)
    defaults.removePersistentDomain(forName: suite)
  }

  override func tearDown() {
    IfacPassphraseStore.write(nil, for: ifaceName)
    defaults.removePersistentDomain(forName: suite)
  }

  private var storedJSON: String {
    String(decoding: defaults.data(forKey: "savedTCPInterfaces") ?? Data(), as: UTF8.self)
  }

  func testPassphraseIsKeptOutOfUserDefaultsAndReadBack() {
    StackController.persist(
      [.init(name: ifaceName, host: "h", port: 4242, networkName: "n", passphrase: "secret")],
      to: defaults)

    XCTAssertTrue(storedJSON.contains(ifaceName))
    XCTAssertFalse(storedJSON.contains("secret"))
    XCTAssertEqual(StackController.loadSavedInterfaces(from: defaults)?.first?.passphrase, "secret")
  }

  func testPlaintextPassphraseFromAnEarlierVersionMovesToTheKeychain() throws {
    let legacy = [
      StackController.SavedInterface(name: ifaceName, host: "h", port: 4242, passphrase: "secret")
    ]
    defaults.set(try JSONEncoder().encode(legacy), forKey: "savedTCPInterfaces")
    XCTAssertTrue(storedJSON.contains("secret"))

    XCTAssertEqual(StackController.loadSavedInterfaces(from: defaults)?.first?.passphrase, "secret")
    XCTAssertFalse(storedJSON.contains("secret"))
  }
}
