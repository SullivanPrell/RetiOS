//===----------------------------------------------------------------------===//
// Copyright (c) 2026 RetiOS contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import Foundation
import SwiftData

@Model
final class PeerEntity {
  /// LXMF delivery destination hash (hex), unique per peer.
  @Attribute(.unique) var destinationHash: String
  /// The name the peer announces for itself; overwritten by every announce.
  var displayName: String?
  /// The name the user typed in Add Contact; announces never touch it.
  var nickname: String?
  var firstSeen: Date
  var lastSeen: Date
  /// True once the user has explicitly saved this peer as a contact
  /// (manually added, or pinned from the discovered-peers list).
  var isContact: Bool = false

  init(destinationHash: String, displayName: String? = nil, isContact: Bool = false) {
    self.destinationHash = destinationHash
    self.displayName = displayName
    self.firstSeen = Date()
    self.lastSeen = Date()
    self.isContact = isContact
  }

  var shortHash: String {
    String(destinationHash.prefix(8))
  }

  /// The name to show: the user's nickname, else the announced name.
  var name: String? { nickname ?? displayName }

  var label: String {
    name ?? "<\(shortHash)>"
  }
}
