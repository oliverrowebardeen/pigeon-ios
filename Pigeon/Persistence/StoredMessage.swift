import Foundation
import SwiftData

@Model
final class StoredMessage {
    @Attribute(.unique) var id: UUID
    var conversationID: UUID
    var groupID: UUID?
    var senderPublicKey: Data
    var recipientPublicKey: Data?
    var plaintext: String
    var timestamp: Date
    var statusRaw: String
    var isIncoming: Bool
    var replyToMessageID: UUID?
    var replyPreview: String?
    var replySenderPublicKey: Data?

    var status: MessageStatus {
        get { MessageStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID,
        conversationID: UUID,
        groupID: UUID?,
        senderPublicKey: Data,
        recipientPublicKey: Data?,
        plaintext: String,
        timestamp: Date,
        statusRaw: String,
        isIncoming: Bool,
        replyToMessageID: UUID?,
        replyPreview: String?,
        replySenderPublicKey: Data?
    ) {
        self.id = id
        self.conversationID = conversationID
        self.groupID = groupID
        self.senderPublicKey = senderPublicKey
        self.recipientPublicKey = recipientPublicKey
        self.plaintext = plaintext
        self.timestamp = timestamp
        self.statusRaw = statusRaw
        self.isIncoming = isIncoming
        self.replyToMessageID = replyToMessageID
        self.replyPreview = replyPreview
        self.replySenderPublicKey = replySenderPublicKey
    }

    convenience init(from message: Message) {
        self.init(
            id: message.id,
            conversationID: message.conversationID,
            groupID: message.groupID,
            senderPublicKey: message.senderPublicKey,
            recipientPublicKey: message.recipientPublicKey,
            plaintext: message.plaintext,
            timestamp: message.timestamp,
            statusRaw: message.status.rawValue,
            isIncoming: message.isIncoming,
            replyToMessageID: message.replyToMessageID,
            replyPreview: message.replyPreview,
            replySenderPublicKey: message.replySenderPublicKey
        )
    }

    func toDTO() -> Message {
        Message(
            id: id,
            conversationID: conversationID,
            groupID: groupID,
            senderPublicKey: senderPublicKey,
            recipientPublicKey: recipientPublicKey,
            plaintext: plaintext,
            timestamp: timestamp,
            status: status,
            isIncoming: isIncoming,
            replyToMessageID: replyToMessageID,
            replyPreview: replyPreview,
            replySenderPublicKey: replySenderPublicKey
        )
    }
}
