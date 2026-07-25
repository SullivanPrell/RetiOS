import XCTest
@testable import RetiOS

/// Covers the pure, CoreBluetooth-free half of connection arbitration —
/// nonce generation and the comparison that decides who dials out. The
/// CoreBluetooth-entangled half (advertising, scanning, GATT setup) needs
/// live radio hardware and stays untested here, same as `BLERNodeTransport`.
final class CoreBluetoothMeshTransportArbitrationTests: XCTestCase {

    // MARK: - Nonce generation

    func testNonceIsSixLowercaseHexCharacters() {
        for _ in 0..<50 {
            let nonce = CoreBluetoothMeshTransport.makeArbitrationNonce()
            XCTAssertEqual(nonce.count, 6)
            XCTAssertTrue(nonce.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                           "expected lowercase hex, got \"\(nonce)\"")
        }
    }

    func testNoncesVaryAcrossCalls() {
        let nonces = Set((0..<20).map { _ in CoreBluetoothMeshTransport.makeArbitrationNonce() })
        XCTAssertGreaterThan(nonces.count, 1, "expected randomness across generated nonces")
    }

    // MARK: - Arbitration decision

    func testLowerNonceConnects() {
        XCTAssertEqual(
            CoreBluetoothMeshTransport.arbitrationDecision(ourNonce: "111111", peerNonce: "222222"),
            .connect
        )
    }

    func testHigherNonceDefers() {
        XCTAssertEqual(
            CoreBluetoothMeshTransport.arbitrationDecision(ourNonce: "222222", peerNonce: "111111"),
            .defer
        )
    }

    func testTieDefersOnBothSides() {
        // Identical nonces (astronomically unlikely at 24 bits, but not
        // impossible) must not make both sides connect — that's the exact
        // mutual cross-connect deadlock arbitration exists to prevent.
        // Deferring on both sides is safe: `deferralTimeout`'s self-heal
        // promotes one side automatically.
        XCTAssertEqual(
            CoreBluetoothMeshTransport.arbitrationDecision(ourNonce: "abcdef", peerNonce: "abcdef"),
            .defer
        )
    }

    func testMissingPeerNonceDefers() {
        // A peer with no advertised nonce compares as empty, the smallest
        // possible value, so we always defer to it. This can't occur in
        // practice — anything discovered here already advertised our exact
        // custom service UUID to be seen at all — but the comparison still
        // needs to resolve to *something* deterministic rather than
        // force-unwrapping or crashing.
        XCTAssertEqual(
            CoreBluetoothMeshTransport.arbitrationDecision(ourNonce: "abcdef", peerNonce: ""),
            .defer
        )
    }
}
