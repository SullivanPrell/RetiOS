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

final class PersistenceControllerTests: XCTestCase {
  private let fm = FileManager.default
  private var root: URL!
  private var url: URL { root.appending(path: "default.store") }

  override func setUpWithError() throws {
    root = fm.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? fm.removeItem(at: root)
  }

  /// Every build before `RetiOSSchemaV1` wrote its store with this unversioned schema.
  @MainActor
  private func writeUnversionedStore() throws {
    let schema = Schema([
      MessageEntity.self, PeerEntity.self, NomadNodeEntity.self, ChannelEntity.self,
      ChannelMessageEntity.self,
    ])
    let container = try ModelContainer(
      for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
    let context = container.mainContext
    context.insert(
      MessageEntity(
        messageHash: "m1", conversationHash: "peer", senderHash: "peer", recipientHash: "me",
        title: "", content: "kept", timestamp: Date(timeIntervalSince1970: 10),
        isOutbound: false, isRead: true))
    context.insert(PeerEntity(destinationHash: "peer", displayName: "Pat"))
    context.insert(ChannelEntity(channelHash: "chan", name: "general"))
    try context.save()
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<MessageEntity>()), 1)
  }

  @MainActor
  func testAStoreFromTheUnversionedSchemaKeepsItsRows() throws {
    try writeUnversionedStore()

    let (container, fellBack) = PersistenceController.makeContainer(url: url)

    XCTAssertFalse(fellBack)
    let context = container.mainContext
    XCTAssertEqual(try context.fetch(FetchDescriptor<MessageEntity>()).map(\.content), ["kept"])
    XCTAssertEqual(try context.fetch(FetchDescriptor<PeerEntity>()).map(\.displayName), ["Pat"])
    XCTAssertEqual(try context.fetch(FetchDescriptor<ChannelEntity>()).map(\.name), ["general"])
  }

  @MainActor
  func testAStoreThatCantOpenFallsBackToAWorkingMemoryStore() throws {
    let notAStore = Data("not a store".utf8)
    try notAStore.write(to: url)

    let (container, fellBack) = PersistenceController.makeContainer(url: url)

    XCTAssertTrue(fellBack)
    container.mainContext.insert(PeerEntity(destinationHash: "peer"))
    try container.mainContext.save()
    XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<PeerEntity>()), 1)
    XCTAssertEqual(try Data(contentsOf: url), notAStore, "the failed store was changed")
  }
}
