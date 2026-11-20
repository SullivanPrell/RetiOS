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

final class FavoriteStarButtonTests: XCTestCase {
  /// The browser's star reads one node by its unique hash, never the whole favorites set.
  @MainActor
  func testStarMatchesOnlyTheBrowsedNodeWhenStarred() throws {
    let container = try ModelContainer(
      for: MessageEntity.self, PeerEntity.self, NomadNodeEntity.self,
      ChannelEntity.self, ChannelMessageEntity.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = container.mainContext
    let browsed = String(repeating: "a", count: 32)
    let other = String(repeating: "b", count: 32)
    context.insert(NomadNodeEntity(destinationHash: browsed))
    context.insert(NomadNodeEntity(destinationHash: other, isFavorite: true))

    func matches() throws -> [String] {
      try context.fetch(FavoriteStarButton.descriptor(hash: browsed)).map(\.destinationHash)
    }

    XCTAssertEqual(try matches(), [], "Another node's star must not light this one.")
    try context.fetch(
      FetchDescriptor<NomadNodeEntity>(
        predicate: #Predicate { $0.destinationHash == browsed })
    ).first?.isFavorite = true
    XCTAssertEqual(try matches(), [browsed])
  }
}
