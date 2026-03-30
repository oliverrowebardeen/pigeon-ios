import Foundation
import Testing
@testable import Pigeon

@Suite("CompactEnvelopeCodec")
struct CompactEnvelopeCodecTests {

    // MARK: - Direct Envelope Round-Trip

    @Test func directEnvelopeRoundTrip() throws {
        let original = MessageEnvelope(
            senderPublicKey: Data(repeating: 0xAA, count: 32),
            recipientPublicKey: Data(repeating: 0xBB, count: 32),
            timestamp: Date(timeIntervalSince1970: 1_711_700_000),
            nonce: Data(repeating: 0x01, count: 12),
            ciphertext: Data("hello world".utf8),
            tag: Data(repeating: 0x02, count: 16)
        )

        let encoded = CompactEnvelopeCodec.encodeDirectEnvelope(original)
        let decoded = try CompactEnvelopeCodec.decodeDirectEnvelope(encoded)

        #expect(decoded.id == original.id)
        #expect(decoded.senderPublicKey == original.senderPublicKey)
        #expect(decoded.recipientPublicKey == original.recipientPublicKey)
        #expect(decoded.nonce == original.nonce)
        #expect(decoded.ciphertext == original.ciphertext)
        #expect(decoded.tag == original.tag)
        #expect(decoded.hopCount == 0)
        #expect(decoded.ttl == 1)

        // Timestamp should be preserved to second-level precision
        let timeDiff = abs(decoded.timestamp.timeIntervalSince(original.timestamp))
        #expect(timeDiff < 1.0)
    }

    @Test func directEnvelopeHeaderSize() {
        let envelope = MessageEnvelope(
            senderPublicKey: Data(repeating: 0xAA, count: 32),
            recipientPublicKey: Data(repeating: 0xBB, count: 32),
            nonce: Data(repeating: 0x01, count: 12),
            ciphertext: Data(),
            tag: Data(repeating: 0x02, count: 16)
        )

        let encoded = CompactEnvelopeCodec.encodeDirectEnvelope(envelope)
        // With empty ciphertext, size should equal header size exactly
        #expect(encoded.count == CompactEnvelopeCodec.directHeaderSize)
    }

    // MARK: - Group Broadcast Envelope Round-Trip

    @Test func groupBroadcastRoundTrip() throws {
        let sealed = GroupSealedPayload(
            nonce: Data(repeating: 0x03, count: 12),
            ciphertext: Data("group message".utf8),
            tag: Data(repeating: 0x04, count: 16)
        )
        let groupID = UUID()
        let epoch = 5
        let senderKey = Data(repeating: 0xCC, count: 32)
        let timestamp = Date(timeIntervalSince1970: 1_711_700_000)

        let encoded = CompactEnvelopeCodec.encodeGroupBroadcastEnvelope(
            sealed: sealed, groupID: groupID, epoch: epoch,
            senderPublicKey: senderKey, timestamp: timestamp
        )

        let decoded = try CompactEnvelopeCodec.decodeGroupBroadcastEnvelope(encoded)

        #expect(decoded.groupID == groupID)
        #expect(decoded.epoch == epoch)
        #expect(decoded.senderPublicKey == senderKey)
        #expect(decoded.sealed.nonce == sealed.nonce)
        #expect(decoded.sealed.ciphertext == sealed.ciphertext)
        #expect(decoded.sealed.tag == sealed.tag)

        let timeDiff = abs(decoded.timestamp.timeIntervalSince(timestamp))
        #expect(timeDiff < 1.0)
    }

    @Test func groupBroadcastHeaderSize() throws {
        let sealed = GroupSealedPayload(
            nonce: Data(repeating: 0x03, count: 12),
            ciphertext: Data(),
            tag: Data(repeating: 0x04, count: 16)
        )

        let encoded = CompactEnvelopeCodec.encodeGroupBroadcastEnvelope(
            sealed: sealed, groupID: UUID(), epoch: 1,
            senderPublicKey: Data(repeating: 0xCC, count: 32)
        )

        #expect(encoded.count == CompactEnvelopeCodec.groupHeaderSize)
    }

    // MARK: - Type Detection

    @Test func isGroupBroadcastDetection() {
        let directEnvelope = CompactEnvelopeCodec.encodeDirectEnvelope(
            MessageEnvelope(
                senderPublicKey: Data(repeating: 0xAA, count: 32),
                recipientPublicKey: Data(repeating: 0xBB, count: 32),
                nonce: Data(repeating: 0x01, count: 12),
                ciphertext: Data([0x42]),
                tag: Data(repeating: 0x02, count: 16)
            )
        )

        let groupEnvelope = CompactEnvelopeCodec.encodeGroupBroadcastEnvelope(
            sealed: GroupSealedPayload(
                nonce: Data(repeating: 0x03, count: 12),
                ciphertext: Data([0x42]),
                tag: Data(repeating: 0x04, count: 16)
            ),
            groupID: UUID(),
            epoch: 1,
            senderPublicKey: Data(repeating: 0xCC, count: 32)
        )

        #expect(CompactEnvelopeCodec.isGroupBroadcast(directEnvelope) == false)
        #expect(CompactEnvelopeCodec.isGroupBroadcast(groupEnvelope) == true)
    }

    // MARK: - Error Cases

    @Test func decodeTooShortThrows() {
        #expect(throws: CompactEnvelopeError.self) {
            _ = try CompactEnvelopeCodec.decodeDirectEnvelope(Data([0x01, 0x00]))
        }
    }

    @Test func decodeWrongVersionThrows() {
        var data = Data(repeating: 0x00, count: CompactEnvelopeCodec.directHeaderSize)
        data[0] = 0xFF // Bad version
        #expect(throws: CompactEnvelopeError.self) {
            _ = try CompactEnvelopeCodec.decodeDirectEnvelope(data)
        }
    }

    @Test func decodeWrongFlagsThrows() {
        var data = Data(repeating: 0x00, count: CompactEnvelopeCodec.directHeaderSize)
        data[0] = 1    // Valid version
        data[1] = 0x01 // Group flag, but trying to decode as direct
        #expect(throws: CompactEnvelopeError.self) {
            _ = try CompactEnvelopeCodec.decodeDirectEnvelope(data)
        }
    }
}
