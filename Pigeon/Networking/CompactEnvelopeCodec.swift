import Foundation

/// Binary serialization for Pigeon envelopes over LoRa (compact alternative to JSON).
///
/// **Direct envelope (114 bytes overhead):**
/// ```
/// [version:1][flags:1][messageID:16][timestamp:4][senderPubKey:32][recipientPubKey:32][nonce:12][tag:16][ciphertext:N]
/// ```
///
/// **Group broadcast envelope (84 bytes overhead):**
/// ```
/// [version:1][flags:1][groupID:16][epoch:2][timestamp:4][senderPubKey:32][nonce:12][tag:16][ciphertext:N]
/// ```
nonisolated enum CompactEnvelopeCodec {

    static let currentVersion: UInt8 = 1

    // Flags byte
    private static let flagDirect: UInt8 = 0x00
    private static let flagGroup: UInt8 = 0x01

    // Fixed sizes
    static let directHeaderSize = 114   // 1+1+16+4+32+32+12+16
    static let groupHeaderSize = 84     // 1+1+16+2+4+32+12+16

    // MARK: - Direct Envelope

    static func encodeDirectEnvelope(_ envelope: MessageEnvelope) -> Data {
        var buf = Data(capacity: directHeaderSize + envelope.ciphertext.count)

        buf.append(currentVersion)
        buf.append(flagDirect)

        // messageID (16 bytes UUID)
        buf.append(contentsOf: envelope.id.byteArray)

        // timestamp (4 bytes, epoch seconds, little-endian)
        appendTimestamp(envelope.timestamp, to: &buf)

        // senderPublicKey (32 bytes)
        buf.append(envelope.senderPublicKey.prefix(32))

        // recipientPublicKey (32 bytes)
        buf.append(envelope.recipientPublicKey.prefix(32))

        // nonce (12 bytes)
        buf.append(envelope.nonce.prefix(12))

        // tag (16 bytes)
        buf.append(envelope.tag.prefix(16))

        // ciphertext (variable)
        buf.append(envelope.ciphertext)

        return buf
    }

    static func decodeDirectEnvelope(_ data: Data) throws -> MessageEnvelope {
        guard data.count >= directHeaderSize else {
            throw CompactEnvelopeError.dataTooShort
        }

        var offset = 0

        let version = data[offset]; offset += 1
        guard version == currentVersion else {
            throw CompactEnvelopeError.unsupportedVersion(version)
        }

        let flags = data[offset]; offset += 1
        guard flags == flagDirect else {
            throw CompactEnvelopeError.unexpectedFlags(flags)
        }

        let uuidBytes = Array(data[offset ..< offset + 16])
        guard let messageID = UUID(byteArray: uuidBytes[...]) else {
            throw CompactEnvelopeError.invalidUUID
        }
        offset += 16

        let timestamp = readTimestamp(from: data, at: &offset)

        let senderPubKey = Data(data[offset ..< offset + 32]); offset += 32
        let recipientPubKey = Data(data[offset ..< offset + 32]); offset += 32
        let nonce = Data(data[offset ..< offset + 12]); offset += 12
        let tag = Data(data[offset ..< offset + 16]); offset += 16
        let ciphertext = Data(data[offset...])

        return MessageEnvelope(
            id: messageID,
            senderPublicKey: senderPubKey,
            recipientPublicKey: recipientPubKey,
            timestamp: timestamp,
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag,
            hopCount: 0,
            ttl: 1  // LoRa messages don't re-hop through Pigeon mesh
        )
    }

    // MARK: - Group Broadcast Envelope

    static func encodeGroupBroadcastEnvelope(
        sealed: GroupSealedPayload,
        groupID: UUID,
        epoch: Int,
        senderPublicKey: Data,
        timestamp: Date = Date()
    ) -> Data {
        var buf = Data(capacity: groupHeaderSize + sealed.ciphertext.count)

        buf.append(currentVersion)
        buf.append(flagGroup)

        // groupID (16 bytes UUID)
        buf.append(contentsOf: groupID.byteArray)

        // epoch (2 bytes big-endian)
        buf.appendUInt16(UInt16(clamping: epoch))

        // timestamp (4 bytes, epoch seconds, little-endian)
        appendTimestamp(timestamp, to: &buf)

        // senderPublicKey (32 bytes)
        buf.append(senderPublicKey.prefix(32))

        // nonce (12 bytes)
        buf.append(sealed.nonce.prefix(12))

        // tag (16 bytes)
        buf.append(sealed.tag.prefix(16))

        // ciphertext (variable)
        buf.append(sealed.ciphertext)

        return buf
    }

    static func decodeGroupBroadcastEnvelope(_ data: Data) throws -> (
        sealed: GroupSealedPayload,
        groupID: UUID,
        epoch: Int,
        senderPublicKey: Data,
        timestamp: Date
    ) {
        guard data.count >= groupHeaderSize else {
            throw CompactEnvelopeError.dataTooShort
        }

        var offset = 0

        let version = data[offset]; offset += 1
        guard version == currentVersion else {
            throw CompactEnvelopeError.unsupportedVersion(version)
        }

        let flags = data[offset]; offset += 1
        guard flags == flagGroup else {
            throw CompactEnvelopeError.unexpectedFlags(flags)
        }

        let uuidBytes = Array(data[offset ..< offset + 16])
        guard let groupID = UUID(byteArray: uuidBytes[...]) else {
            throw CompactEnvelopeError.invalidUUID
        }
        offset += 16

        guard let epoch = data.readUInt16(at: offset) else {
            throw CompactEnvelopeError.dataTooShort
        }
        offset += 2

        let timestamp = readTimestamp(from: data, at: &offset)

        let senderPubKey = Data(data[offset ..< offset + 32]); offset += 32
        let nonce = Data(data[offset ..< offset + 12]); offset += 12
        let tag = Data(data[offset ..< offset + 16]); offset += 16
        let ciphertext = Data(data[offset...])

        let sealed = GroupSealedPayload(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return (sealed, groupID, Int(epoch), senderPubKey, timestamp)
    }

    // MARK: - Timestamp Helpers

    /// Appends a Date as 4-byte little-endian epoch seconds.
    private static func appendTimestamp(_ date: Date, to buf: inout Data) {
        var epochSeconds = UInt32(date.timeIntervalSince1970).littleEndian
        buf.append(Data(bytes: &epochSeconds, count: 4))
    }

    /// Reads a 4-byte little-endian epoch seconds timestamp, advancing offset.
    private static func readTimestamp(from data: Data, at offset: inout Int) -> Date {
        let epochSeconds = data.withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4
        return Date(timeIntervalSince1970: TimeInterval(UInt32(littleEndian: epochSeconds)))
    }

    // MARK: - Type Detection

    /// Returns true if the data appears to be a group broadcast envelope
    static func isGroupBroadcast(_ data: Data) -> Bool {
        data.count >= 2 && data[0] == currentVersion && data[1] == flagGroup
    }
}

// MARK: - Errors

nonisolated enum CompactEnvelopeError: Error {
    case dataTooShort
    case unsupportedVersion(UInt8)
    case unexpectedFlags(UInt8)
    case invalidUUID
}
