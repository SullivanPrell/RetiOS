import XCTest
import LXMF
import ReticulumSwift
@testable import RetiOS

/// `swift_devel/bugs/020`, the RetiOS half (design D5): the 2 Hz sync poll exited only on
/// `.done` or `.failed` — two states the library might never set — so a misbehaving callee hung
/// the caller for the lifetime of the process. The library now bounds its own stalls
/// (`cleanLinks(syncStallTimeout:)`), but this loop must terminate *independently of that*: a
/// caller that can only stop when its callee behaves is the same class of fault one level up.
@MainActor
final class SyncPollBoundTests: XCTestCase {

    /// A router that will never reach a terminal transfer state: freshly built, no propagation
    /// node configured, state parked at `.idle` — exactly what the poll saw in `bugs/020`.
    private func stuckRouter() -> LXMRouter {
        LXMRouter(transport: Transport())
    }

    func testThePollExitsOnItsBoundWhenTheLibraryNeverTerminates() async throws {
        let controller = StackController()
        let router = stuckRouter()

        controller.startSyncPolling(router: router, timeout: 0.4)

        // Give it the bound plus one poll period, then a margin.
        try await Task.sleep(nanoseconds: 1_200_000_000)

        XCTAssertEqual(controller.propagationSyncState, .failed,
                       """
                       the poll ran past its bound without publishing a terminal state — with \
                       a callee that never terminates, this loop spun at 2 Hz for the lifetime \
                       of the process before the bound existed
                       """)
        XCTAssertFalse(controller.isSyncPolling,
                       "the poll task itself must have exited, not merely published a state")
    }

    func testThePollStillReportsARealResultInsideTheBound() async throws {
        let controller = StackController()
        let router = stuckRouter()

        controller.startSyncPolling(router: router, timeout: 10)
        router.propagationTransferState = .done

        try await Task.sleep(nanoseconds: 1_100_000_000)

        XCTAssertEqual(controller.propagationSyncState, .done,
                       "a sync that terminates normally must be reported as what it was — the "
                       + "bound is a backstop, not the exit path")
        XCTAssertFalse(controller.isSyncPolling)
    }

    func testTheBoundOutlivesTheLibrarysOwnStallNet() {
        // 240 is `LXMRouter.propagationSyncStallTimeout`, hard-coded because the pinned
        // LXMFSwift (1.6.0) predates the symbol. When the pin reaches 1.7.0, replace the
        // literal with the constant so the two cannot drift.
        XCTAssertGreaterThan(StackController.syncPollTimeout, 240,
                             """
                             the app's bound must sit above the library's stall net \
                             (`cleanLinks(syncStallTimeout:)`, 240 s), so the library gets to \
                             report the failure it detects and the app's deadline only fires \
                             when the library's own protections did not
                             """)
    }
}
