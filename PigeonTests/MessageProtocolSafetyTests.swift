import Foundation
import Testing
@testable import Pigeon

@Suite("Untrusted message boundaries")
struct MessageProtocolSafetyTests {
    @Test("Extreme chunk sizes throw instead of overflowing", arguments: [0, -1, 481, 65536, Int.max])
    func invalidChunkSize(size: Int) {
        #expect(throws: MessageProtocolError.self) {
            try MessageProtocol.chunk(data: Data([1]), messageID: UUID(), maxChunkPayloadSize: size)
        }
    }

    @Test("Reassembly handles out-of-order chunks and identical retransmits")
    func reorderedRoundTrip() throws {
        let data = Data((0..<1000).map { UInt8($0 % 256) })
        let packets = try MessageProtocol.chunk(data: data, messageID: UUID())
        #expect(try MessageProtocol.reassemblePayload(from: [packets[2], packets[0], packets[0], packets[1]]) == data)
    }

    @Test("Conflicting retransmits are rejected")
    func conflictingDuplicate() throws {
        let packets = try MessageProtocol.chunk(data: Data(repeating: 7, count: 600), messageID: UUID())
        var changed = packets[0]
        changed[changed.count - 1] = 8
        #expect(throws: MessageProtocolError.self) {
            try MessageProtocol.reassemblePayload(from: [packets[0], changed, packets[1]])
        }
    }

    @Test("Untrusted chunk declarations are bounded")
    func invalidHeaders() throws {
        let valid = try MessageProtocol.chunk(data: Data([1]), messageID: UUID())[0]
        for (offset, value) in [(18, UInt16(0)), (18, UInt16(257)), (16, UInt16(1)), (20, UInt16(481))] {
            var malformed = valid
            malformed[offset] = UInt8(value >> 8)
            malformed[offset + 1] = UInt8(value & 255)
            #expect(throws: MessageProtocolError.self) { try MessageProtocol.decodePacket(malformed) }
        }
    }

    @Test("Buffers reject mixed transfers and expire")
    func bufferValidation() throws {
        let id = UUID()
        let packets = try MessageProtocol.chunk(data: Data(repeating: 1, count: 600), messageID: id)
        let buffer = ReassemblyBuffer(messageID: id, expectedChunkCount: 2)
        #expect(!buffer.addChunk(index: 0, data: packets[0]))
        var conflict = packets[1]
        conflict[19] = 3
        #expect(!buffer.addChunk(index: 1, data: conflict))
        #expect(!buffer.isComplete)
        #expect(buffer.addChunk(index: 1, data: packets[1]))
        let expired = ReassemblyBuffer(messageID: id, expectedChunkCount: 2, createdAt: .distantPast)
        #expect(!expired.addChunk(index: 0, data: packets[0]))
        #expect(expired.assembledPacketData().isEmpty)
    }

    @Test("Delivery acknowledgment terminates a relay exchange")
    func acknowledgmentDoesNotRecurse() throws {
        let original = WirePayloadV2(eventType: .directText, logicalMessageID: UUID(), senderPublicKey: Data(repeating: 1, count: 32))
        let ack = WirePayloadV2(eventType: .deliveryAck, logicalMessageID: UUID(), senderPublicKey: Data(repeating: 2, count: 32), deliveryAck: DeliveryAckPayload(ackedMessageID: original.logicalMessageID))
        let received = try WirePayloadV2.makeWireDecoder().decode(WirePayloadV2.self, from: WirePayloadV2.makeWireEncoder().encode(ack))
        #expect(original.eventType.requiresDeliveryAcknowledgment)
        #expect(!received.eventType.requiresDeliveryAcknowledgment)
    }
}
