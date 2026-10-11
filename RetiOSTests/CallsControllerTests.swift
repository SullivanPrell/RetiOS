//===----------------------------------------------------------------------===//
// Copyright (c) 2026 RetiOS contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import LXST
import ReticulumSwift
import XCTest

@testable import RetiOS

final class CallsControllerTests: XCTestCase {
  /// Recents redials through `startCall(to:)`, which recalls by destination
  /// hash, so an inbound record must hold the hash the caller announces.
  func testInboundCallHashIsTheCallersAnnouncedTelephonyDestination() throws {
    let caller = Identity()
    let announced = try Destination(
      identity: caller, direction: .in, kind: .single,
      appName: appName, aspects: [lxstTelephonyPrimitive])

    XCTAssertEqual(CallsController.callHash(for: caller), announced.hash)
    XCTAssertNotEqual(CallsController.callHash(for: caller), caller.hash)
  }
}
