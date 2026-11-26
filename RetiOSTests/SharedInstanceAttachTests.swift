//===----------------------------------------------------------------------===//
// Copyright (c) 2026 RetiOS contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import Darwin
import ReticulumSwift
import XCTest

@testable import RetiOS

final class SharedInstanceAttachTests: XCTestCase {
  private let fm = FileManager.default
  private var root: URL!
  private var listener: Int32 = -1
  private var stack: Reticulum?
  private var client: LocalInterface?

  override func setUpWithError() throws {
    root = fm.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    client?.stop()
    stack?.stop()
    if listener >= 0 { close(listener) }
    try? fm.removeItem(at: root)
  }

  /// A loopback listener on a port the kernel picks, so the test never reaches a real rnsd.
  private func listen() throws -> UInt16 {
    listener = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, length) == 0 && Darwin.listen(listener, 4) == 0
          && getsockname(listener, $0, &length) == 0
      }
    }
    XCTAssertTrue(bound, "loopback listener: errno \(errno)")
    return UInt16(bigEndian: address.sin_port)
  }

  func testAttachingTakesTheClientRoleSoStartDisablesTransport() throws {
    let port = try listen()
    // A config that turns transport on, so only the client role can turn it off.
    try "[reticulum]\n  enable_transport = Yes\n".write(
      to: root.appending(path: "config"), atomically: true, encoding: .utf8)
    let stack = Reticulum(
      configuration: .init(
        storagePath: root.appending(path: "storage", directoryHint: .isDirectory)))
    self.stack = stack

    client = try StackController.attachToSharedInstance(stack, port: port)
    try stack.start()

    XCTAssertTrue(stack.transport.isConnectedToSharedInstance)
    XCTAssertFalse(stack.transport.transportEnabled)
  }
}
