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

extension Transport {
  /// One interface's block of `rnstatus -A` output, found by `Interface.name`.
  ///
  /// Rendered from the payload Python's `rnstatus` reads (`Reticulum.get_interface_stats()`), so
  /// it lists only the fields this interface reports. The payload carries no IFAC passphrase.
  func rnstatusBlock(named name: String) -> String? {
    var options = RNStatusRenderer.Options()
    options.announceStats = true
    return RNStatusStats(InterfaceStatsPayload.build(self))?.interfaces
      .first { $0.string("short_name") == name }
      .map {
        RNStatusRenderer(options: options).renderInterface($0).trimmingCharacters(in: .newlines)
      }
  }
}
