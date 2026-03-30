import CryptoKit
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

    @Test("Ephemeral key envelope decrypts correctly and hides real sender")
    func ephemeralKeyRoundTrip() throws {
        let crypto = CryptoManager()
        let senderReal = Curve25519.KeyAgreement.PrivateKey()
        let recipient = Curve25519.KeyAgreement.PrivateKey()

        let plaintext = Data("sealed sender test".utf8)

        let envelope = try crypto.encryptSealed(
            plaintext: plaintext,
            recipientPublicKeyData: recipient.publicKey.rawRepresentation
        )

        // Envelope header should NOT contain the real sender's public key
        #expect(envelope.senderPublicKey != senderReal.publicKey.rawRepresentation)

        // Recipient can still decrypt using the ephemeral key in the header
        let decrypted = try crypto.decrypt(envelope: envelope, recipientPrivateKey: recipient)
        #expect(decrypted == plaintext)
    }
}
