import Foundation
import SwiftData

@Model
final class PeerEntity {
    /// LXMF delivery destination hash (hex), unique per peer.
    @Attribute(.unique) var destinationHash: String
    var displayName: String?
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

    var label: String {
        displayName ?? "<\(shortHash)>"
    }
}
