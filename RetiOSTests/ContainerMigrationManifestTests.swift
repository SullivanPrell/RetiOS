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

/// The Mac app runs in the App Sandbox. On its first sandboxed
/// launch macOS copies what `container-migration.plist` lists into the
/// container; anything left off stays outside, where the app can no longer read
/// it, and the user starts over with a new address.
final class ContainerMigrationManifestTests: XCTestCase {
  func testListsEverythingTheUnsandboxedMacAppWrote() throws {
    let url = try XCTUnwrap(
      Bundle(for: StackController.self).url(
        forResource: "container-migration", withExtension: "plist"),
      "container-migration.plist is missing from the app bundle")
    let manifest = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        as? [String: Any])
    let moved = Set(try XCTUnwrap(manifest["Move"] as? [String]))

    XCTAssertEqual(
      moved,
      [
        // StackController.bringUp: the stack, with the identity's private key.
        "${ApplicationSupport}/${BundleId}",
        // The same, from builds before the stack left Documents.
        "${Documents}/reticulum",
        // PersistenceController's unnamed SwiftData store and its
        // `.externalStorage` blobs.
        "${ApplicationSupport}/default.store",
        "${ApplicationSupport}/default.store-shm",
        "${ApplicationSupport}/default.store-wal",
        "${ApplicationSupport}/.default_SUPPORT",
        // NomadNetController: RRC hubs, and the Pages default root.
        "${Documents}/nomadnet",
        // Settings: saved interfaces, propagation node, network settings.
        "${Library}/Preferences/${BundleId}.plist",
      ])
  }
}
