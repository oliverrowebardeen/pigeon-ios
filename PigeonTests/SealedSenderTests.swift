import Foundation
import Testing
@testable import Pigeon

@Suite("Sealed Sender")
struct SealedSenderTests {

    private static let wireEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let wireDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    @Test("DeliveryAckPayload round-trips through JSON")
    func deliveryAckPayloadRoundTrip() throws {
        let ackMessageID = UUID()
        let payload = WirePayloadV2(
            eventType: .deliveryAck,
            logicalMessageID: UUID(),
            senderPublicKey: Data(repeating: 0xAA, count: 32),
            deliveryAck: DeliveryAckPayload(ackedMessageID: ackMessageID)
        )

        let data = try Self.wireEncoder.encode(payload)
        let decoded = try Self.wireDecoder.decode(WirePayloadV2.self, from: data)

        #expect(decoded.eventType == .deliveryAck)
        #expect(decoded.deliveryAck?.ackedMessageID == ackMessageID)
        #expect(decoded.directText == nil)
    }
}
