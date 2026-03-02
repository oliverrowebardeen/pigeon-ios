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
    let groupID: UUID?
    let senderPublicKey: Data
    let recipientPublicKey: Data?
    let plaintext: String
    let timestamp: Date
    var status: MessageStatus
    let isIncoming: Bool
    let replyToMessageID: UUID?
    let replyPreview: String?
    let replySenderPublicKey: Data?

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        groupID: UUID? = nil,
        senderPublicKey: Data,
        recipientPublicKey: Data? = nil,
        plaintext: String,
        timestamp: Date = Date(),
        status: MessageStatus,
        isIncoming: Bool,
        replyToMessageID: UUID? = nil,
        replyPreview: String? = nil,
        replySenderPublicKey: Data? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.groupID = groupID
        self.senderPublicKey = senderPublicKey
        self.recipientPublicKey = recipientPublicKey
        self.plaintext = plaintext
        self.timestamp = timestamp
        self.status = status
        self.isIncoming = isIncoming
        self.replyToMessageID = replyToMessageID
        self.replyPreview = replyPreview
        self.replySenderPublicKey = replySenderPublicKey
    }

    func withStatus(_ newStatus: MessageStatus) -> Message {
        var copy = self
        copy.status = newStatus
        return copy
    }

    var replyMetadata: ReplyMetadataPayload? {
        guard let replyToMessageID, let replyPreview, let replySenderPublicKey else {
            return nil
        }
        return ReplyMetadataPayload(
            replyToMessageID: replyToMessageID,
            replyPreview: replyPreview,
            replySenderPublicKey: replySenderPublicKey
        )
    }
}
