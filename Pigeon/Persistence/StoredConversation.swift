import Foundation
import SwiftData

@Model
final class StoredConversation {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var peerPublicKey: Data?
    var peerDisplayName: String?
    var peerPigeonID: String?
    var groupID: UUID?
    var groupName: String?
    var groupOwnerPublicKey: Data?
    var memberCount: Int
    var lastMessageTimestamp: Date?
    var lastMessagePreview: String?
    var unreadCount: Int

    var kind: ConversationKind {
        get { ConversationKind(rawValue: kindRaw) ?? .direct }
        set { kindRaw = newValue.rawValue }
    }

    init(
        id: UUID,
        kindRaw: String,
        peerPublicKey: Data?,
        peerDisplayName: String?,
        peerPigeonID: String?,
        groupID: UUID?,
        groupName: String?,
        groupOwnerPublicKey: Data?,
        memberCount: Int,
        lastMessageTimestamp: Date?,
        lastMessagePreview: String?,
        unreadCount: Int
    ) {
        self.id = id
        self.kindRaw = kindRaw
        self.peerPublicKey = peerPublicKey
        self.peerDisplayName = peerDisplayName
        self.peerPigeonID = peerPigeonID
        self.groupID = groupID
        self.groupName = groupName
        self.groupOwnerPublicKey = groupOwnerPublicKey
        self.memberCount = memberCount
        self.lastMessageTimestamp = lastMessageTimestamp
        self.lastMessagePreview = lastMessagePreview
        self.unreadCount = unreadCount
    }

    convenience init(from conversation: Conversation) {
        self.init(
            id: conversation.id,
            kindRaw: conversation.kind.rawValue,
            peerPublicKey: conversation.peerPublicKey,
            peerDisplayName: conversation.peerDisplayName,
            peerPigeonID: conversation.peerPigeonID,
            groupID: conversation.groupID,
            groupName: conversation.groupName,
            groupOwnerPublicKey: conversation.groupOwnerPublicKey,
            memberCount: conversation.memberCount,
            lastMessageTimestamp: conversation.lastMessageTimestamp,
            lastMessagePreview: conversation.lastMessagePreview,
            unreadCount: conversation.unreadCount
        )
    }

    func toDTO() -> Conversation {
        Conversation(
            id: id,
            kind: kind,
            peerPublicKey: peerPublicKey,
            peerDisplayName: peerDisplayName,
            peerPigeonID: peerPigeonID,
            groupID: groupID,
            groupName: groupName,
            groupOwnerPublicKey: groupOwnerPublicKey,
            memberCount: memberCount,
            lastMessageTimestamp: lastMessageTimestamp,
            lastMessagePreview: lastMessagePreview,
            unreadCount: unreadCount
        )
    }
}
