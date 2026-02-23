import Foundation
import SwiftData

@Model
final class StoredConversation {
    @Attribute(.unique) var id: UUID
    var peerPublicKey: Data
    var peerDisplayName: String?
    var peerPigeonID: String
    var lastMessageTimestamp: Date?
    var lastMessagePreview: String?
    var unreadCount: Int

    init(
        id: UUID,
        peerPublicKey: Data,
        peerDisplayName: String?,
        peerPigeonID: String,
        lastMessageTimestamp: Date?,
        lastMessagePreview: String?,
        unreadCount: Int
    ) {
        self.id = id
        self.peerPublicKey = peerPublicKey
        self.peerDisplayName = peerDisplayName
        self.peerPigeonID = peerPigeonID
        self.lastMessageTimestamp = lastMessageTimestamp
        self.lastMessagePreview = lastMessagePreview
        self.unreadCount = unreadCount
    }

    convenience init(from conversation: Conversation) {
        self.init(
            id: conversation.id,
            peerPublicKey: conversation.peerPublicKey,
            peerDisplayName: conversation.peerDisplayName,
            peerPigeonID: conversation.peerPigeonID,
            lastMessageTimestamp: conversation.lastMessageTimestamp,
            lastMessagePreview: conversation.lastMessagePreview,
            unreadCount: conversation.unreadCount
        )
    }

    func toDTO() -> Conversation {
        Conversation(
            id: id,
            peerPublicKey: peerPublicKey,
            peerDisplayName: peerDisplayName,
            peerPigeonID: peerPigeonID,
            lastMessageTimestamp: lastMessageTimestamp,
            lastMessagePreview: lastMessagePreview,
            unreadCount: unreadCount
        )
    }
}
