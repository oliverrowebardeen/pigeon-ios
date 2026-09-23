import Foundation

nonisolated enum WireEventType: String, Codable, Hashable, Sendable {
    case directText = "direct_text"
    case directReadReceipt = "direct_read_receipt"
    case directReaction = "direct_reaction"
    case groupKeyShare = "group_key_share"
    case groupControl = "group_control"
    case groupMessage = "group_message"
    case groupReaction = "group_reaction"
    case deliveryAck = "delivery_ack"

    // Acknowledging acknowledgments causes an endless relay exchange.
    var requiresDeliveryAcknowledgment: Bool { self != .deliveryAck }
}

nonisolated enum GroupControlAction: String, Codable, Hashable, Sendable {
    case membershipUpdate = "membership_update"
    case rename = "rename"
}

nonisolated struct ReplyMetadataPayload: Codable, Hashable, Sendable {
    let replyToMessageID: UUID
    let replyPreview: String
    let replySenderPublicKey: Data
}

nonisolated struct DirectTextPayload: Codable, Hashable, Sendable {
    let text: String
    let reply: ReplyMetadataPayload?
}

nonisolated struct DirectReactionPayload: Codable, Hashable, Sendable {
    let targetMessageID: UUID
    let tapback: TapbackType
    let isRemoval: Bool
}

nonisolated struct DirectReadReceiptPayload: Codable, Hashable, Sendable {
    let targetMessageID: UUID
}

nonisolated struct GroupKeySharePayload: Codable, Hashable, Sendable {
    let groupID: UUID
    let groupName: String
    let ownerPublicKey: Data
    let epoch: Int
    let keyB64: String
    let members: [Data]
}

nonisolated struct GroupControlPayload: Codable, Hashable, Sendable {
    let groupID: UUID
    let action: GroupControlAction
    let groupName: String?
    let epoch: Int
    let addedMemberKeys: [Data]
    let removedMemberKeys: [Data]
}

nonisolated struct GroupEncryptedPayload: Codable, Hashable, Sendable {
    let groupID: UUID
    let epoch: Int
    let nonceB64: String
    let ciphertextB64: String
    let tagB64: String

    static func encrypting(
        _ plaintext: Data,
        groupID: UUID,
        epoch: Int,
        using crypto: GroupCryptoManager,
        keyData: Data
    ) throws -> GroupEncryptedPayload {
        let sealed = try crypto.encrypt(plaintext, keyData: keyData)
        return GroupEncryptedPayload(
            groupID: groupID,
            epoch: epoch,
            nonceB64: sealed.nonce.base64EncodedString(),
            ciphertextB64: sealed.ciphertext.base64EncodedString(),
            tagB64: sealed.tag.base64EncodedString()
        )
    }

    func decrypt(using crypto: GroupCryptoManager, keyData: Data) throws -> Data {
        guard let nonce = Data(base64Encoded: nonceB64),
              let ciphertext = Data(base64Encoded: ciphertextB64),
              let tag = Data(base64Encoded: tagB64)
        else {
            throw AppCoordinatorError.invalidWirePayload
        }
        return try crypto.decrypt(
            GroupSealedPayload(nonce: nonce, ciphertext: ciphertext, tag: tag),
            keyData: keyData
        )
    }
}

nonisolated struct DeliveryAckPayload: Codable, Hashable, Sendable {
    let ackedMessageID: UUID
}

nonisolated struct WirePayloadV2: Codable, Hashable, Sendable {
    static func makeWireEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static func makeWireDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    let version: Int
    let eventType: WireEventType
    let logicalMessageID: UUID
    let conversationID: UUID?
    let groupID: UUID?
    let senderPublicKey: Data
    let timestamp: Date
    let senderSigningPublicKey: Data?
    let signature: Data?

    let directText: DirectTextPayload?
    let directReadReceipt: DirectReadReceiptPayload?
    let directReaction: DirectReactionPayload?
    let groupKeyShare: GroupKeySharePayload?
    let groupControl: GroupControlPayload?
    let groupEncrypted: GroupEncryptedPayload?
    let deliveryAck: DeliveryAckPayload?

    init(
        eventType: WireEventType,
        logicalMessageID: UUID,
        conversationID: UUID? = nil,
        groupID: UUID? = nil,
        senderPublicKey: Data,
        timestamp: Date = Date(),
        senderSigningPublicKey: Data? = nil,
        signature: Data? = nil,
        directText: DirectTextPayload? = nil,
        directReadReceipt: DirectReadReceiptPayload? = nil,
        directReaction: DirectReactionPayload? = nil,
        groupKeyShare: GroupKeySharePayload? = nil,
        groupControl: GroupControlPayload? = nil,
        groupEncrypted: GroupEncryptedPayload? = nil,
        deliveryAck: DeliveryAckPayload? = nil
    ) {
        version = 2
        self.eventType = eventType
        self.logicalMessageID = logicalMessageID
        self.conversationID = conversationID
        self.groupID = groupID
        self.senderPublicKey = senderPublicKey
        self.timestamp = timestamp
        self.senderSigningPublicKey = senderSigningPublicKey
        self.signature = signature
        self.directText = directText
        self.directReadReceipt = directReadReceipt
        self.directReaction = directReaction
        self.groupKeyShare = groupKeyShare
        self.groupControl = groupControl
        self.groupEncrypted = groupEncrypted
        self.deliveryAck = deliveryAck
    }

    func unsignedSignaturePayload(senderSigningPublicKey override: Data? = nil) -> WirePayloadV2 {
        WirePayloadV2(
            eventType: eventType,
            logicalMessageID: logicalMessageID,
            conversationID: conversationID,
            groupID: groupID,
            senderPublicKey: senderPublicKey,
            timestamp: timestamp,
            senderSigningPublicKey: override ?? senderSigningPublicKey,
            signature: nil,
            directText: directText,
            directReadReceipt: directReadReceipt,
            directReaction: directReaction,
            groupKeyShare: groupKeyShare,
            groupControl: groupControl,
            groupEncrypted: groupEncrypted,
            deliveryAck: deliveryAck
        )
    }

    func withSenderAuthentication(senderSigningPublicKey: Data, signature: Data) -> WirePayloadV2 {
        WirePayloadV2(
            eventType: eventType,
            logicalMessageID: logicalMessageID,
            conversationID: conversationID,
            groupID: groupID,
            senderPublicKey: senderPublicKey,
            timestamp: timestamp,
            senderSigningPublicKey: senderSigningPublicKey,
            signature: signature,
            directText: directText,
            directReadReceipt: directReadReceipt,
            directReaction: directReaction,
            groupKeyShare: groupKeyShare,
            groupControl: groupControl,
            groupEncrypted: groupEncrypted,
            deliveryAck: deliveryAck
        )
    }

    func serializedForSigning(senderSigningPublicKey override: Data? = nil) throws -> Data {
        try Self.makeWireEncoder().encode(
            unsignedSignaturePayload(senderSigningPublicKey: override)
        )
    }
}

nonisolated enum GroupInnerPayloadType: String, Codable, Hashable, Sendable {
    case text
    case reaction
}

nonisolated struct GroupTextPayload: Codable, Hashable, Sendable {
    let text: String
    let reply: ReplyMetadataPayload?
}

nonisolated struct GroupReactionPayload: Codable, Hashable, Sendable {
    let targetMessageID: UUID
    let tapback: TapbackType
    let isRemoval: Bool
}

nonisolated struct GroupInnerPayload: Codable, Hashable, Sendable {
    let payloadType: GroupInnerPayloadType
    let text: GroupTextPayload?
    let reaction: GroupReactionPayload?

    init(text: GroupTextPayload) {
        payloadType = .text
        self.text = text
        reaction = nil
    }

    init(reaction: GroupReactionPayload) {
        payloadType = .reaction
        text = nil
        self.reaction = reaction
    }
}
