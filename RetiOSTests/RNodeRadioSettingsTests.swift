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

final class RNodeRadioSettingsTests: XCTestCase {
  func testFrequencyParsesMegahertzInEitherDecimalSeparator() {
    XCTAssertEqual(RNodeRadioSettings.frequency(megahertz: "868.1"), 868_100_000)
    XCTAssertEqual(RNodeRadioSettings.frequency(megahertz: " 915,5 "), 915_500_000)
  }

  /// There is no default band: an empty field must not bring the radio up.
  func testFrequencyRejectsEmptyMalformedAndOutOfRange() {
    for text in ["", "abc", "nan", "inf", "136.9", "3000.1"] {
      XCTAssertNil(RNodeRadioSettings.frequency(megahertz: text), text)
    }
    XCTAssertEqual(RNodeRadioSettings.frequency(megahertz: "137"), RNodeInterface.freqMin)
    XCTAssertEqual(RNodeRadioSettings.frequency(megahertz: "3000"), RNodeInterface.freqMax)
  }
}
