import Foundation

nonisolated struct MessageReaction: Identifiable, Codable, Hashable, Sendable {
    var id: String {
        "\(messageID.uuidString):\(reactorPublicKey.base64EncodedString())"
    }

    let messageID: UUID
    let conversationID: UUID
    let groupID: UUID?
    let reactorPublicKey: Data
    let tapback: TapbackType
    let timestamp: Date

    init(
        messageID: UUID,
        conversationID: UUID,
        groupID: UUID? = nil,
        reactorPublicKey: Data,
        tapback: TapbackType,
        timestamp: Date = Date()
    ) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.groupID = groupID
        self.reactorPublicKey = reactorPublicKey
        self.tapback = tapback
        self.timestamp = timestamp
    }
}

nonisolated struct ReactionSummary: Identifiable, Hashable, Sendable {
    var id: String { "\(tapback.rawValue)-\(count)" }

    let tapback: TapbackType
    let count: Int
    let includesCurrentUser: Bool
}
