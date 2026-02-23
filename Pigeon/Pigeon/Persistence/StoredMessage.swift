import Foundation
import SwiftData

@Model
final class StoredMessage {
    @Attribute(.unique) var id: UUID
    var conversationID: UUID
    var senderPublicKey: Data
    var recipientPublicKey: Data
    var plaintext: String
    var timestamp: Date
    var statusRaw: String
    var isIncoming: Bool

    var status: MessageStatus {
        get { MessageStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID,
        conversationID: UUID,
        senderPublicKey: Data,
        recipientPublicKey: Data,
        plaintext: String,
        timestamp: Date,
        statusRaw: String,
        isIncoming: Bool
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderPublicKey = senderPublicKey
        self.recipientPublicKey = recipientPublicKey
        self.plaintext = plaintext
        self.timestamp = timestamp
        self.statusRaw = statusRaw
        self.isIncoming = isIncoming
    }

    convenience init(from message: Message) {
        self.init(
            id: message.id,
            conversationID: message.conversationID,
            senderPublicKey: message.senderPublicKey,
            recipientPublicKey: message.recipientPublicKey,
            plaintext: message.plaintext,
            timestamp: message.timestamp,
            statusRaw: message.status.rawValue,
            isIncoming: message.isIncoming
        )
    }

    func toDTO() -> Message {
        Message(
            id: id,
            conversationID: conversationID,
            senderPublicKey: senderPublicKey,
            recipientPublicKey: recipientPublicKey,
            plaintext: plaintext,
            timestamp: timestamp,
            status: status,
            isIncoming: isIncoming
        )
    }
}
