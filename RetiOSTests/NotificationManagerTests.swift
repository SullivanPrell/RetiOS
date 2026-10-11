//===----------------------------------------------------------------------===//
// Copyright (c) 2026 RetiOS contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import UserNotifications
import XCTest

@testable import RetiOS

final class NotificationManagerTests: XCTestCase {
  /// A message for the thread on screen updates it quietly instead of covering it.
  @MainActor
  func testOpenThreadGetsNoBanner() {
    let notifs = NotificationManager.shared
    notifs.visibleConversationHash = "aa"
    defer { notifs.visibleConversationHash = nil }

    XCTAssertEqual(notifs.presentationOptions(peerHash: "aa"), [])
    XCTAssertEqual(notifs.presentationOptions(peerHash: "bb"), [.banner, .sound])
    XCTAssertEqual(notifs.presentationOptions(peerHash: nil), [.banner, .sound])
  }
}
