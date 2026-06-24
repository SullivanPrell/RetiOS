import Foundation
import SwiftData

@Model
final class MessageEntity {
    var id: UUID
    /// SHA-256 truncated hash of the LXMF message (hex string for easy lookup).
    var messageHash: String
    /// The peer's destination hash (hex). Groups messages into a conversation.
    var conversationHash: String
    /// Sender destination hash (hex).
    var senderHash: String
    /// Recipient destination hash (hex).
    var recipientHash: String
    var title: String
    var content: String
    var timestamp: Date
    var isOutbound: Bool
    /// Raw value of LXMessage.State.
    var deliveryState: Int16
    /// False for inbound messages the user hasn't viewed yet.
    /// Defaulted (not just init-defaulted) so pre-existing rows migrate as read.
    var isRead: Bool = true

    /// Cheap indicator that this message carries LXMF `fields` (image, file
    /// attachments, audio, telemetry, …). Lets list rows show a 📎 without
    /// decoding the packed payload. Defaulted so pre-existing rows migrate cleanly.
    var hasAttachments: Bool = false

    /// The inbound message's raw packed bytes — present only when the message
    /// carries `fields`. Re-decoded lazily via `MessageAttachments.decode` to
    /// render attachments, which keeps this entity free of any field-encoding
    /// logic and lossless. `nil` for text-only and pre-attachment rows.
    /// External storage keeps large image/file blobs out of the main store.
    @Attribute(.externalStorage) var packedMessage: Data?

    init(
        id: UUID = .init(),
        messageHash: String,
        conversationHash: String,
        senderHash: String,
        recipientHash: String,
        title: String,
        content: String,
        timestamp: Date,
        isOutbound: Bool,
        deliveryState: Int16 = 0,
        isRead: Bool = true,
        hasAttachments: Bool = false,
        packedMessage: Data? = nil
    ) {
        self.id = id
        self.messageHash = messageHash
        self.conversationHash = conversationHash
        self.senderHash = senderHash
        self.recipientHash = recipientHash
        self.title = title
        self.content = content
        self.timestamp = timestamp
        self.isOutbound = isOutbound
        self.deliveryState = deliveryState
        self.isRead = isRead
        self.hasAttachments = hasAttachments
        self.packedMessage = packedMessage
    }
}
