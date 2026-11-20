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

final class ConversationSummaryTests: XCTestCase {
  private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
      for: MessageEntity.self, PeerEntity.self, NomadNodeEntity.self,
      ChannelEntity.self, ChannelMessageEntity.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
  }

  private func message(
    _ conversation: String, _ content: String, at seconds: TimeInterval, read: Bool = true
  ) -> MessageEntity {
    MessageEntity(
      messageHash: UUID().uuidString, conversationHash: conversation,
      senderHash: conversation, recipientHash: "me", title: "", content: content,
      timestamp: Date(timeIntervalSince1970: seconds), isOutbound: false, isRead: read)
  }

  /// Messages ▸ Messages lists each conversation once, newest first, with its latest
  /// message and its unread count.
  @MainActor
  func testSummariesGroupConversationsNewestFirstWithUnreadCounts() throws {
    let container = try makeContainer()
    let context = container.mainContext
    context.insert(message("a", "a-old", at: 10, read: false))
    context.insert(message("a", "a-new", at: 30, read: false))
    context.insert(message("b", "b-only", at: 20))
    try context.save()

    let summaries = try ConversationSummary.load(from: container)

    XCTAssertEqual(summaries.map(\.peerHash), ["a", "b"])
    XCTAssertEqual(summaries.map(\.preview), ["a-new", "b-only"])
    XCTAssertEqual(summaries.map(\.unread), [2, 0])
  }

  /// A peer announce saves a `PeerEntity` about once a second; only a save that touches a
  /// message may make the list reload every message.
  @MainActor
  func testOnlyASaveThatTouchesAMessageRefreshesTheList() throws {
    let container = try makeContainer()
    let context = container.mainContext
    var saves: [Notification] = []
    let token = NotificationCenter.default.addObserver(
      forName: ModelContext.didSave, object: context, queue: nil
    ) { saves.append($0) }
    defer { NotificationCenter.default.removeObserver(token) }

    context.insert(PeerEntity(destinationHash: String(repeating: "0", count: 32)))
    try context.save()
    let msg = message("a", "hello", at: 1)
    context.insert(msg)
    try context.save()
    msg.isRead = false
    try context.save()
    context.delete(msg)
    try context.save()

    XCTAssertEqual(saves.map(ConversationSummary.touchesMessages), [false, true, true, true])
  }
}
