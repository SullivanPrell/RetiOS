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
import SwiftData
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

  /// iOS kills a backgrounded app, and Recents must still show the call it missed.
  func testCallHistoryRoundTripsThroughUserDefaults() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "test-\(UUID())"))
    var record = CallRecord(
      peerHash: "ab", peerName: "Mom", direction: .inbound,
      startTime: Date(timeIntervalSince1970: 1), outcome: .failed("busy"))
    record.endTime = Date(timeIntervalSince1970: 2)

    CallsController.saveHistory([record], to: defaults)
    let loaded = CallsController.loadHistory(from: defaults)

    XCTAssertEqual(loaded.map(\.id), [record.id])
    XCTAssertEqual(loaded.first?.outcome, .failed("busy"))
    XCTAssertEqual(loaded.first?.peerName, "Mom")
    XCTAssertEqual(loaded.first?.endTime, record.endTime)
  }

  /// The call screens and the call banner name a saved peer instead of showing a hash.
  @MainActor
  func testPeerNameComesFromTheCallersDeliveryPeer() throws {
    let container = try ModelContainer(
      for: MessageEntity.self, PeerEntity.self, NomadNodeEntity.self,
      ChannelEntity.self, ChannelMessageEntity.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let caller = Identity()
    let delivery = Destination.hash(identity: caller, appName: "lxmf", aspects: ["delivery"])
      .map { String(format: "%02x", $0) }.joined()
    container.mainContext.insert(PeerEntity(destinationHash: delivery, displayName: "Mom"))

    XCTAssertEqual(CallsController.peerName(for: caller, in: container.mainContext), "Mom")
    XCTAssertNil(CallsController.peerName(for: Identity(), in: container.mainContext))
  }

  /// Calls ▸ Peers fetches a call peer's delivery row before that destination announces, so
  /// the peer's name lands when the announce does.
  func testCallPeersFetchTheDeliveryHashBeforeItAnnounces() {
    let peer = Identity()
    let callHash = CallsController.callHash(for: peer)
    let delivery = Destination.hash(identity: peer, appName: "lxmf", aspects: ["delivery"])
    let onlyTheCallAnnounced: (Data) -> Identity? = { $0 == callHash ? peer : nil }

    XCTAssertEqual(
      CallPeerResolver.deliveryHexes(
        forCallHashes: [callHash.hexString, Identity().hash.hexString],
        recall: onlyTheCallAnnounced),
      [delivery.hexString])
  }
}
