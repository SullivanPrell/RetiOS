//===----------------------------------------------------------------------===//
// Copyright (c) 2026 RetiOS contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import LXMF
import ReticulumSwift
import SwiftData
import XCTest

@testable import RetiOS

final class LXMFMessageIngestTests: XCTestCase {
  func testSameMessageEnqueuedTwiceIsStoredOnce() async throws {
    let container = try ModelContainer(
      for: MessageEntity.self, PeerEntity.self, NomadNodeEntity.self,
      ChannelEntity.self, ChannelMessageEntity.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let source = try Destination(
      identity: Identity(), direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
    let local = try Destination(
      identity: Identity(), direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
    let message = LXMessage(destination: local, source: source, content: "hello")
    try message.pack()

    let ingest = LXMFMessageIngest(
      container: container,
      myHash: local.hash.map { String(format: "%02x", $0) }.joined(),
      notificationManager: nil)
    ingest.enqueue(message)
    ingest.enqueue(message)

    let context = ModelContext(container)
    let all = FetchDescriptor<MessageEntity>()
    var polls = 0
    // 30 s: a CI simulator can starve the utility queue the 0.4 s flush runs on.
    while try context.fetchCount(all) == 0, polls < 300 {
      try await Task.sleep(for: .milliseconds(100))
      polls += 1
    }
    XCTAssertEqual(try context.fetchCount(all), 1)
  }
}
