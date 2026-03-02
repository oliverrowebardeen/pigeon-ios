import Foundation
import SwiftData

@Model
final class StoredReaction {
    @Attribute(.unique) var id: String
    var messageID: UUID
    var conversationID: UUID
    var groupID: UUID?
    var reactorPublicKey: Data
    var tapbackRaw: String
    var timestamp: Date

    var tapback: TapbackType {
        get { TapbackType(rawValue: tapbackRaw) ?? .like }
        set { tapbackRaw = newValue.rawValue }
    }

    init(
        id: String,
        messageID: UUID,
        conversationID: UUID,
        groupID: UUID?,
        reactorPublicKey: Data,
        tapbackRaw: String,
        timestamp: Date
    ) {
        self.id = id
        self.messageID = messageID
        self.conversationID = conversationID
        self.groupID = groupID
        self.reactorPublicKey = reactorPublicKey
        self.tapbackRaw = tapbackRaw
        self.timestamp = timestamp
    }

    convenience init(from reaction: MessageReaction) {
        self.init(
            id: reaction.id,
            messageID: reaction.messageID,
            conversationID: reaction.conversationID,
            groupID: reaction.groupID,
            reactorPublicKey: reaction.reactorPublicKey,
            tapbackRaw: reaction.tapback.rawValue,
            timestamp: reaction.timestamp
        )
    }

    func toDTO() -> MessageReaction {
        MessageReaction(
            messageID: messageID,
            conversationID: conversationID,
            groupID: groupID,
            reactorPublicKey: reactorPublicKey,
            tapback: tapback,
            timestamp: timestamp
        )
    }
}
