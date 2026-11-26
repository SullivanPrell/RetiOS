//===----------------------------------------------------------------------===//
// Copyright (c) 2026 RetiOS contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import ReticulumSwift
import XCTest

@testable import RetiOS

/// The one `Data(hexString:)` every screen parses typed and stored hashes with.
final class HexStringTests: XCTestCase {
  func testParsesHexInEitherCase() {
    XCTAssertEqual(Data(hexString: "0aFF10"), Data([0x0A, 0xFF, 0x10]))
    XCTAssertEqual(Data(hexString: "<0aff>".dropFirst().dropLast()), Data([0x0A, 0xFF]))
  }

  /// Skipping a stray character would turn a typo into a different valid hash.
  func testRejectsAnythingButEvenLengthASCIIHex() {
    XCTAssertNil(Data(hexString: "ab-cd"))
    XCTAssertNil(Data(hexString: "abc"))
    XCTAssertNil(Data(hexString: "\u{FF11}a"))
    XCTAssertNil(Data(hexString: "0123456789abcdef 0123456789abcdef"))
  }

  func testRoundTripsWithHexString() {
    let bytes = Data((0...255).map { UInt8($0) })
    XCTAssertEqual(Data(hexString: bytes.hexString), bytes)
  }
}
