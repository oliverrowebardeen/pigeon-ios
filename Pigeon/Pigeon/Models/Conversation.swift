import Foundation

nonisolated struct Conversation: Identifiable, Hashable, Sendable {
    let id: UUID
    let peerPublicKey: Data
    var peerDisplayName: String?
    let peerPigeonID: String
    var lastMessageTimestamp: Date?
    var lastMessagePreview: String?
    var unreadCount: Int

    init(
        id: UUID = UUID(),
        peerPublicKey: Data,
        peerDisplayName: String?,
        peerPigeonID: String,
        lastMessageTimestamp: Date? = nil,
        lastMessagePreview: String? = nil,
        unreadCount: Int = 0
    ) {
        self.id = id
        self.peerPublicKey = peerPublicKey
        self.peerDisplayName = peerDisplayName
        self.peerPigeonID = peerPigeonID
        self.lastMessageTimestamp = lastMessageTimestamp
        self.lastMessagePreview = lastMessagePreview
        self.unreadCount = unreadCount
    }

    var derivedPeerPigeonID: String {
        PigeonIdentity.makePigeonID(fromPublicKeyData: peerPublicKey)
    }
}
