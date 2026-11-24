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
import XCTest

@testable import RetiOS

/// `swift_devel/bugs/020`, the RetiOS half (design D5): the 2 Hz sync poll exited only on
/// `.done` or `.failed`—two states the library might never set—so a misbehaving callee hung
/// the caller for the lifetime of the process.
///
/// The library now bounds its own stalls
/// (`cleanLinks(syncStallTimeout:)`), but this loop must terminate *independently of that*: a
/// caller that can only stop when its callee behaves is the same class of fault one level up.
@MainActor
final class SyncPollBoundTests: XCTestCase {

  /// A router that never reaches a terminal transfer state: freshly built, no propagation
  /// node configured, state parked at `.idle`—exactly what the poll saw in `bugs/020`.
  private func stuckRouter() -> LXMRouter {
    LXMRouter(transport: Transport())
  }

  func testThePollExitsOnItsBoundWhenTheLibraryNeverTerminates() async throws {
    let controller = StackController()
    let router = stuckRouter()

    controller.startSyncPolling(router: router, timeout: 0.4)

    // Give it the bound plus one poll period, then a margin.
    try await Task.sleep(nanoseconds: 1_200_000_000)

    XCTAssertEqual(
      controller.propagationSyncState, .failed,
      """
      the poll ran past its bound without publishing a terminal state — with \
      a callee that never terminates, this loop spun at 2 Hz for the lifetime \
      of the process before the bound existed
      """)
    XCTAssertFalse(
      controller.isSyncPolling,
      "the poll task itself must have exited, not merely published a state")
  }

  func testThePollStillReportsARealResultInsideTheBound() async throws {
    let controller = StackController()
    let router = stuckRouter()

    controller.startSyncPolling(router: router, timeout: 10)
    router.acknowledgeSyncCompletion(failureState: .done)

    try await Task.sleep(nanoseconds: 1_100_000_000)

    XCTAssertEqual(
      controller.propagationSyncState, .done,
      "a sync that terminates normally must be reported as what it was — the "
        + "bound is a backstop, not the exit path")
    XCTAssertFalse(controller.isSyncPolling)
  }

  /// A background refresh has about 30 s before iOS suspends the app, so its wait for the
  /// sync must give up on its own budget, well inside the 300 s poll bound.
  func testABackgroundWaitGivesUpOnItsBudgetWhileThePollRuns() async {
    let controller = StackController()
    controller.startSyncPolling(router: stuckRouter(), timeout: 10)

    let started = Date()
    await controller.waitForSyncPoll(budget: 0.3)

    XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    XCTAssertTrue(controller.isSyncPolling, "the wait gives up; the sync itself keeps going")
    controller.cancelPropagationSync()
  }

  func testABackgroundWaitReturnsAsSoonAsTheSyncEnds() async {
    let controller = StackController()
    let router = stuckRouter()
    controller.startSyncPolling(router: router, timeout: 10)
    router.acknowledgeSyncCompletion(failureState: .done)

    let started = Date()
    await controller.waitForSyncPoll(budget: 10)

    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    XCTAssertFalse(controller.isSyncPolling)
  }

  func testTheBoundOutlivesTheLibrarysOwnStallNet() {
    XCTAssertGreaterThan(
      StackController.syncPollTimeout,
      LXMRouter.propagationSyncStallTimeout,
      """
      the app's bound must sit above the library's stall net \
      (`cleanLinks(syncStallTimeout:)`), so the library gets to report \
      the failure it detects and the app's deadline only fires when the \
      library's own protections did not. Compared against the library's \
      own constant rather than a copy of its value: two numbers that \
      must stay ordered cannot be allowed to drift apart silently
      """)
  }
}
