//===----------------------------------------------------------------------===//
// Copyright (c) 2026 RetiOS contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import SwiftUI
import XCTest

@testable import RetiOS

final class RNSAdaptiveRowTests: XCTestCase {
  /// Pixel size of a row holding two 10 pt squares, at the given text size.
  @MainActor
  private func renderedSize(_ typeSize: DynamicTypeSize) throws -> CGSize {
    let row = RNSAdaptiveRow(spacing: 0) {
      Color.red.frame(width: 10, height: 10)
      Color.blue.frame(width: 10, height: 10)
    }
    .environment(\.dynamicTypeSize, typeSize)
    let renderer = ImageRenderer(content: row)
    renderer.scale = 1
    let image = try XCTUnwrap(renderer.cgImage)
    return CGSize(width: image.width, height: image.height)
  }

  /// A row keeps its trailing date or button beside the title at standard sizes, and moves
  /// it to its own line at accessibility sizes (HIG Typography, Supporting Dynamic Type).
  @MainActor
  func testRowStacksOnlyAtAccessibilitySizes() throws {
    XCTAssertEqual(try renderedSize(.large), CGSize(width: 20, height: 10))
    XCTAssertEqual(try renderedSize(.xxxLarge), CGSize(width: 20, height: 10))
    XCTAssertEqual(try renderedSize(.accessibility1), CGSize(width: 10, height: 20))
    XCTAssertEqual(try renderedSize(.accessibility5), CGSize(width: 10, height: 20))
  }
}
