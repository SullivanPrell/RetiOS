import Foundation
import SwiftData

/// A NomadNet node that has announced the nomadnetwork.node destination.
@Model
final class NomadNodeEntity {
    /// 32-hex destination hash — unique per node.
    @Attribute(.unique) var destinationHash: String
    var displayName: String?
    var lastSeen: Date
    /// True once the user has starred this node as a favorite for quick access.
    var isFavorite: Bool = false

    init(destinationHash: String, displayName: String? = nil, isFavorite: Bool = false) {
        self.destinationHash = destinationHash
        self.displayName = displayName
        self.lastSeen = Date()
        self.isFavorite = isFavorite
    }

    var label: String { displayName ?? "<\(String(destinationHash.prefix(8)))>" }
    var shortHash: String { String(destinationHash.prefix(8)) }
}
