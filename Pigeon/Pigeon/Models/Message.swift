import Foundation

nonisolated enum MessageStatus: String, Codable, CaseIterable, Sendable {
    case sending
    case queued
    case sent
    case delivered
    case failed
}

nonisolated struct Message: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let conversationID: UUID
    let senderPublicKey: Data
    let recipientPublicKey: Data
    let plaintext: String
    let timestamp: Date
    var status: MessageStatus
    let isIncoming: Bool

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        senderPublicKey: Data,
        recipientPublicKey: Data,
        plaintext: String,
        timestamp: Date = Date(),
        status: MessageStatus,
        isIncoming: Bool
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderPublicKey = senderPublicKey
        self.recipientPublicKey = recipientPublicKey
        self.plaintext = plaintext
        self.timestamp = timestamp
        self.status = status
        self.isIncoming = isIncoming
    }
}
