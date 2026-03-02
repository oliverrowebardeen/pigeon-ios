import Foundation

nonisolated enum ConversationKind: String, Codable, Hashable, Sendable {
    case direct
    case group
}

nonisolated struct Conversation: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: ConversationKind
    let peerPublicKey: Data?
    var peerDisplayName: String?
    var peerPigeonID: String?
    let groupID: UUID?
    var groupName: String?
    var groupOwnerPublicKey: Data?
    var memberCount: Int
    var lastMessageTimestamp: Date?
    var lastMessagePreview: String?
    var unreadCount: Int

    init(
        id: UUID = UUID(),
        kind: ConversationKind,
        peerPublicKey: Data? = nil,
        peerDisplayName: String? = nil,
        peerPigeonID: String? = nil,
        groupID: UUID? = nil,
        groupName: String? = nil,
        groupOwnerPublicKey: Data? = nil,
        memberCount: Int = 0,
        lastMessageTimestamp: Date? = nil,
        lastMessagePreview: String? = nil,
        unreadCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
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

    static func direct(
        id: UUID = UUID(),
        peerPublicKey: Data,
        peerDisplayName: String?,
        peerPigeonID: String,
        lastMessageTimestamp: Date? = nil,
        lastMessagePreview: String? = nil,
        unreadCount: Int = 0
    ) -> Conversation {
        Conversation(
            id: id,
            kind: .direct,
            peerPublicKey: peerPublicKey,
            peerDisplayName: peerDisplayName,
            peerPigeonID: peerPigeonID,
            lastMessageTimestamp: lastMessageTimestamp,
            lastMessagePreview: lastMessagePreview,
            unreadCount: unreadCount
        )
    }

    static func group(
        id: UUID,
        groupName: String,
        groupOwnerPublicKey: Data,
        memberCount: Int,
        lastMessageTimestamp: Date? = nil,
        lastMessagePreview: String? = nil,
        unreadCount: Int = 0
    ) -> Conversation {
        Conversation(
            id: id,
            kind: .group,
            groupID: id,
            groupName: groupName,
            groupOwnerPublicKey: groupOwnerPublicKey,
            memberCount: memberCount,
            lastMessageTimestamp: lastMessageTimestamp,
            lastMessagePreview: lastMessagePreview,
            unreadCount: unreadCount
        )
    }

    var derivedPeerPigeonID: String {
        guard let peerPublicKey else {
            return "group"
        }
        return PigeonIdentity.makePigeonID(fromPublicKeyData: peerPublicKey)
    }

    var displayTitle: String {
        switch kind {
        case .direct:
            return peerDisplayName ?? (peerPigeonID ?? derivedPeerPigeonID)
        case .group:
            return groupName ?? "Group"
        }
    }
}
