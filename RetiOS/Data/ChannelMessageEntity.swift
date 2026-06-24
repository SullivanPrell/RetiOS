import Foundation
import SwiftData

/// A single message received in an RRC chat room.
///
/// Mirrors `RRCMessage`: kind, room, src, nick, text, ts.
/// `channelHash` links back to the parent `ChannelEntity.channelHash`.
@Model
final class ChannelMessageEntity {
    /// Hub destination hash (hex) — foreign key to `ChannelEntity.channelHash`.
    var channelHash: String
    /// RRC message ID (hex of `RRC.Envelope.id`). Used for deduplication.
    @Attribute(.unique) var messageID: String
    /// Sender identity hash (hex of `RRC.Envelope.src`). Empty for system messages.
    var senderHash: String
    /// Sender nickname from the T_MSG `nick` field, if present.
    var senderNick: String?
    /// Room sub-name, when the hub hosts multiple rooms.
    var room: String?
    /// Plain-text message body.
    var content: String
    /// Unix timestamp from the envelope (milliseconds → converted to Date).
    var timestamp: Date

    init(
        channelHash: String,
        messageID: String,
        senderHash: String,
        senderNick: String? = nil,
        room: String? = nil,
        content: String,
        timestamp: Date = Date()
    ) {
        self.channelHash = channelHash
        self.messageID = messageID
        self.senderHash = senderHash
        self.senderNick = senderNick
        self.room = room
        self.content = content
        self.timestamp = timestamp
    }

    /// Display name: nick if available, otherwise first-8 chars of senderHash.
    var displaySender: String {
        if let nick = senderNick, !nick.isEmpty { return nick }
        return senderHash.isEmpty ? "?" : "<\(senderHash.prefix(8))>"
    }
}
