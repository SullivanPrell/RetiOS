//===----------------------------------------------------------------------===//
// Copyright (c) 2026 RetiOS contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import SwiftData
import XCTest

@testable import RetiOS

final class LXMFPeersContentTests: XCTestCase {
  /// Messages ▸ Peers lists the newest peers, and its search reaches the older ones.
  @MainActor
  func testListShowsTheNewestPeersAndSearchFindsOlderOnes() throws {
    let container = try ModelContainer(
      for: MessageEntity.self, PeerEntity.self, NomadNodeEntity.self,
      ChannelEntity.self, ChannelMessageEntity.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = container.mainContext
    let oldest = PeerEntity(destinationHash: "ab12" + String(repeating: "0", count: 28))
    oldest.lastSeen = .distantPast
    oldest.displayName = "Alice"
    oldest.nickname = "Mom"
    context.insert(oldest)
    for i in 0..<LXMFPeersContent.limit {
      context.insert(PeerEntity(destinationHash: String(format: "%032x", i), displayName: "peer"))
    }

    func hashes(_ search: String) throws -> [String] {
      try context.fetch(LXMFPeersContent.descriptor(search: search)).map(\.destinationHash)
    }

    let newest = try hashes("")
    XCTAssertEqual(newest.count, LXMFPeersContent.limit)
    XCTAssertFalse(newest.contains(oldest.destinationHash))
    XCTAssertEqual(try hashes(" MOM "), [oldest.destinationHash])
    XCTAssertEqual(try hashes("AB12"), [oldest.destinationHash])
    XCTAssertEqual(try hashes("alice"), [], "A nickname hides the announced name, as in `name`.")
    XCTAssertEqual(try hashes("PEER").count, LXMFPeersContent.limit)
  }
}
