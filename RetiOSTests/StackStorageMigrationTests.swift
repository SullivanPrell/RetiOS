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

final class StackStorageMigrationTests: XCTestCase {
  private let fm = FileManager.default
  private var root: URL!
  private var old: URL!
  private let key = Data("private key".utf8)

  override func setUpWithError() throws {
    root = fm.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    old = root.appending(path: "Documents/reticulum", directoryHint: .isDirectory)
    try fm.createDirectory(at: old, withIntermediateDirectories: true)
    try key.write(to: old.appending(path: "identity"))
  }

  override func tearDownWithError() throws {
    try? fm.removeItem(at: root)
  }

  func testMovesTheExistingDirectoryKeepingTheIdentity() throws {
    let new = root.appending(path: "Support/app/reticulum", directoryHint: .isDirectory)

    XCTAssertEqual(StackController.migrateStorage(from: old, to: new), new)
    XCTAssertEqual(try Data(contentsOf: new.appending(path: "identity")), key)
    XCTAssertFalse(fm.fileExists(atPath: old.path))
  }

  func testFailedMoveKeepsUsingTheOldDirectory() throws {
    // A file where the parent directory should go makes the move fail.
    try Data().write(to: root.appending(path: "Support"))
    let new = root.appending(path: "Support/app/reticulum", directoryHint: .isDirectory)

    XCTAssertEqual(StackController.migrateStorage(from: old, to: new), old)
    XCTAssertEqual(try Data(contentsOf: old.appending(path: "identity")), key)
  }
}
