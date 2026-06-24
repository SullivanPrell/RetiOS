import Foundation
import SwiftData

/// A NomadNet RRC chat room (hub) that the user has joined or bookmarked.
///
/// Keyed by `channelHash` — the hex-encoded `RRCHub.hubHash` (16 bytes, 32 hex chars).
@Model
final class ChannelEntity {
    /// Hub destination hash in hex (32 chars / 16 bytes). Unique identifier.
    @Attribute(.unique) var channelHash: String
    /// Human-readable room name received in the T_WELCOME frame (`RRCHub.name`).
    var name: String
    /// Destination name used to build the RNS link (e.g. `"nomadnetwork.rrc"`).
    var destName: String
    /// When the user last received a message in this room.
    var lastActivity: Date
    /// Number of messages received since the user last viewed this room.
    var unreadCount: Int

    init(channelHash: String, name: String, destName: String = "") {
        self.channelHash = channelHash
        self.name = name
        self.destName = destName
        self.lastActivity = Date()
        self.unreadCount = 0
    }

    var shortHash: String { String(channelHash.prefix(8)) }

    var displayName: String { name.isEmpty ? "<\(shortHash)>" : name }
}
