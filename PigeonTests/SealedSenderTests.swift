import CryptoKit
import Foundation
import Testing
@testable import Pigeon

@Suite("Sealed Sender")
struct SealedSenderTests {

    private static let wireEncoder = WirePayloadV2.makeWireEncoder()
    private static let wireDecoder = WirePayloadV2.makeWireDecoder()

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

    @Test("RelayMessageDeliverPayload decodes without sender_hash_hex")
    func deliverPayloadWithoutSenderHash() throws {
        let json = """
        {"message_id":"550e8400-e29b-41d4-a716-446655440000","envelope_b64":"dGVzdA==","queued_at_ms":1234567890000}
        """
        let data = Data(json.utf8)
        let decoder = JSONDecoder()

        let payload = try decoder.decode(RelayMessageDeliverPayload.self, from: data)
        #expect(payload.senderHashHex == nil)
        #expect(payload.messageID == "550e8400-e29b-41d4-a716-446655440000")
    }

    @Test("RelayMessageDeliverPayload still decodes with sender_hash_hex")
    func deliverPayloadWithSenderHash() throws {
        let json = """
        {"message_id":"550e8400-e29b-41d4-a716-446655440000","sender_hash_hex":"abcdef","envelope_b64":"dGVzdA==","queued_at_ms":1234567890000}
        """
        let data = Data(json.utf8)
        let decoder = JSONDecoder()

        let payload = try decoder.decode(RelayMessageDeliverPayload.self, from: data)
        #expect(payload.senderHashHex == "abcdef")
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

    // MARK: - Integration Tests

    @Test("Full sealed sender flow: sender identity only in decrypted payload")
    func sealedSenderFullFlow() throws {
        let crypto = CryptoManager()
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let recipient = Curve25519.KeyAgreement.PrivateKey()

        let payload = WirePayloadV2(
            eventType: .directText,
            logicalMessageID: UUID(),
            senderPublicKey: sender.publicKey.rawRepresentation,
            directText: DirectTextPayload(text: "hello sealed", reply: nil)
        )
        let payloadData = try Self.wireEncoder.encode(payload)

        let envelope = try crypto.encryptSealed(
            plaintext: payloadData,
            recipientPublicKeyData: recipient.publicKey.rawRepresentation
        )

        // The envelope header does NOT reveal the real sender
        #expect(envelope.senderPublicKey != sender.publicKey.rawRepresentation)
        // The envelope header DOES show the recipient (needed for routing)
        #expect(envelope.recipientPublicKey == recipient.publicKey.rawRepresentation)

        // Recipient decrypts — the ephemeral key in the header is used for ECDH
        let decrypted = try crypto.decrypt(envelope: envelope, recipientPrivateKey: recipient)
        let decoded = try Self.wireDecoder.decode(WirePayloadV2.self, from: decrypted)

        // Real sender identity is inside the decrypted payload
        #expect(decoded.senderPublicKey == sender.publicKey.rawRepresentation)
        #expect(decoded.directText?.text == "hello sealed")
    }

    @Test("Delivery ack survives encryption round-trip")
    func deliveryAckEncryptionRoundTrip() throws {
        let crypto = CryptoManager()
        let acker = Curve25519.KeyAgreement.PrivateKey()
        let originalSender = Curve25519.KeyAgreement.PrivateKey()
        let ackedMessageID = UUID()

        let payload = WirePayloadV2(
            eventType: .deliveryAck,
            logicalMessageID: UUID(),
            senderPublicKey: acker.publicKey.rawRepresentation,
            deliveryAck: DeliveryAckPayload(ackedMessageID: ackedMessageID)
        )
        let payloadData = try Self.wireEncoder.encode(payload)

        let envelope = try crypto.encryptSealed(
            plaintext: payloadData,
            recipientPublicKeyData: originalSender.publicKey.rawRepresentation
        )

        let decrypted = try crypto.decrypt(envelope: envelope, recipientPrivateKey: originalSender)
        let decoded = try Self.wireDecoder.decode(WirePayloadV2.self, from: decrypted)

        #expect(decoded.eventType == .deliveryAck)
        #expect(decoded.deliveryAck?.ackedMessageID == ackedMessageID)
        #expect(decoded.senderPublicKey == acker.publicKey.rawRepresentation)
    }

    @Test("Legacy non-sealed envelope still decrypts correctly")
    func legacyEnvelopeBackwardCompatibility() throws {
        let crypto = CryptoManager()
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let recipient = Curve25519.KeyAgreement.PrivateKey()

        let payload = WirePayloadV2(
            eventType: .directText,
            logicalMessageID: UUID(),
            senderPublicKey: sender.publicKey.rawRepresentation,
            directText: DirectTextPayload(text: "legacy message", reply: nil)
        )
        let payloadData = try Self.wireEncoder.encode(payload)

        // Old-style envelope: real sender key in header (not sealed)
        let envelope = try crypto.encrypt(
            plaintext: payloadData,
            senderPrivateKey: sender,
            recipientPublicKeyData: recipient.publicKey.rawRepresentation
        )

        // Envelope header matches real sender (old behavior)
        #expect(envelope.senderPublicKey == sender.publicKey.rawRepresentation)

        // Recipient can still decrypt
        let decrypted = try crypto.decrypt(envelope: envelope, recipientPrivateKey: recipient)
        let decoded = try Self.wireDecoder.decode(WirePayloadV2.self, from: decrypted)

        // Sender identity from both envelope and payload match (old-style)
        #expect(decoded.senderPublicKey == sender.publicKey.rawRepresentation)
        #expect(decoded.directText?.text == "legacy message")
    }

    @Test("Signed sealed sender message verifies after decryption")
    func signedSealedSenderMessageVerifies() throws {
        let crypto = CryptoManager()
        let senderAgreement = Curve25519.KeyAgreement.PrivateKey()
        let senderSigning = Curve25519.Signing.PrivateKey()
        let recipient = Curve25519.KeyAgreement.PrivateKey()

        let payload = WirePayloadV2(
            eventType: .directText,
            logicalMessageID: UUID(),
            senderPublicKey: senderAgreement.publicKey.rawRepresentation,
            directText: DirectTextPayload(text: "signed hello", reply: nil)
        )
        let payloadData = try crypto.encodeSignedPayload(
            payload,
            senderSigningPrivateKey: senderSigning
        )

        let envelope = try crypto.encryptSealed(
            plaintext: payloadData,
            recipientPublicKeyData: recipient.publicKey.rawRepresentation
        )

        let decrypted = try crypto.decrypt(envelope: envelope, recipientPrivateKey: recipient)
        let decoded = try Self.wireDecoder.decode(WirePayloadV2.self, from: decrypted)

        #expect(decoded.senderSigningPublicKey == senderSigning.publicKey.rawRepresentation)
        #expect(decoded.signature?.count == 64)
        #expect(crypto.verifyPayloadSignature(decoded) == .verified)
    }

    @Test("Tampered message signature is rejected")
    func tamperedMessageSignatureIsRejected() throws {
        let crypto = CryptoManager()
        let senderAgreement = Curve25519.KeyAgreement.PrivateKey()
        let senderSigning = Curve25519.Signing.PrivateKey()

        let payload = WirePayloadV2(
            eventType: .directText,
            logicalMessageID: UUID(),
            senderPublicKey: senderAgreement.publicKey.rawRepresentation,
            directText: DirectTextPayload(text: "tamper me", reply: nil)
        )
        let payloadData = try crypto.encodeSignedPayload(
            payload,
            senderSigningPrivateKey: senderSigning
        )
        let signedPayload = try Self.wireDecoder.decode(WirePayloadV2.self, from: payloadData)

        var signature = try #require(signedPayload.signature)
        signature[signature.startIndex] ^= 0x01

        let tamperedPayload = signedPayload.withSenderAuthentication(
            senderSigningPublicKey: try #require(signedPayload.senderSigningPublicKey),
            signature: signature
        )

        #expect(crypto.verifyPayloadSignature(tamperedPayload) == .invalid)
    }

    @Test("Unsigned payload is rejected")
    func unsignedPayloadIsRejected() {
        let crypto = CryptoManager()
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let payload = WirePayloadV2(
            eventType: .directText,
            logicalMessageID: UUID(),
            senderPublicKey: sender.publicKey.rawRepresentation,
            directText: DirectTextPayload(text: "legacy unsigned", reply: nil)
        )

        #expect(crypto.verifyPayloadSignature(payload) == .missingSignature)
    }

    @Test("Bridged send session uses anonymous msg_send tunnel")
    func bridgedSendSessionUsesAnonymousMsgSendTunnel() async throws {
        let recorder = BridgeFrameRecorder()
        let bridgePublicKey = Data(repeating: 0x42, count: 32)
        let candidate = BridgeCandidate(
            publicKey: bridgePublicKey,
            pigeonID: "bridge",
            rssi: -42,
            relayReachable: true,
            bridgeEnabled: true,
            capacityRemaining: 2,
            lastStatusAt: Date()
        )
        let session = RelaySendSession(
            relayURL: URL(string: "wss://relay.example/v1/ws")!,
            sendBridgeFrame: { peerPublicKey, frame in
                await recorder.append(peerPublicKey: peerPublicKey, frame: frame)
            }
        )
        await session.updateTransportPath(.bridged(candidate))

        let envelope = MessageEnvelope(
            id: UUID(),
            senderPublicKey: Data(repeating: 0xAA, count: 32),
            recipientPublicKey: Data(repeating: 0xBB, count: 32),
            timestamp: Date(),
            nonce: Data(repeating: 0x01, count: 12),
            ciphertext: Data("sealed".utf8),
            tag: Data(repeating: 0x02, count: 16)
        )

        let sendTask = Task {
            try await session.sendEnvelope(envelope)
        }

        try await waitForFrameCount(recorder, atLeast: 1)
        let firstFrame = try #require(await recorder.frame(at: 0))
        #expect(firstFrame.peerPublicKey == bridgePublicKey)

        guard case .tunnelOpen(let tunnelOpen) = firstFrame.frame.payload else {
            Issue.record("Expected first bridge frame to open a send tunnel")
            return
        }

        await session.handleBridgeControlFrame(
            BridgeProtocol.tunnelOpened(tunnelOpen.tunnelID),
            from: bridgePublicKey
        )

        try await waitForFrameCount(recorder, atLeast: 2)
        let secondFrame = try #require(await recorder.frame(at: 1))

        guard case .tunnelData(let tunnelData) = secondFrame.frame.payload else {
            Issue.record("Expected tunneled relay data after tunnel open")
            return
        }

        let tunneledJSON = try decodeTunneledJSON(from: tunnelData)
        #expect(tunneledJSON["type"] as? String == "msg_send")
        #expect(tunneledJSON["payload"] != nil)

        let requestID = try #require(tunneledJSON["req_id"] as? String)
        await session.handleBridgeControlFrame(
            BridgeProtocol.tunnelData(
                tunnelOpen.tunnelID,
                text: """
                {"type":"msg_accepted","req_id":"\(requestID)","payload":{"message_id":"\(envelope.id.uuidString)","queued":true,"queue_depth":1}}
                """
            ),
            from: bridgePublicKey
        )

        try await sendTask.value
    }
}

private actor BridgeFrameRecorder {
    struct RecordedFrame: Sendable {
        let peerPublicKey: Data
        let frame: BridgeControlFrame
    }

    private var frames: [RecordedFrame] = []

    func append(peerPublicKey: Data, frame: BridgeControlFrame) {
        frames.append(RecordedFrame(peerPublicKey: peerPublicKey, frame: frame))
    }

    func count() -> Int {
        frames.count
    }

    func frame(at index: Int) -> RecordedFrame? {
        guard frames.indices.contains(index) else { return nil }
        return frames[index]
    }
}

private enum BridgeTestError: Error {
    case timedOut
    case invalidTunneledPayload
}

private func waitForFrameCount(
    _ recorder: BridgeFrameRecorder,
    atLeast expectedCount: Int
) async throws {
    for _ in 0..<50 {
        if await recorder.count() >= expectedCount {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    throw BridgeTestError.timedOut
}

private func decodeTunneledJSON(from payload: TunnelDataPayload) throws -> [String: Any] {
    guard let payloadData = Data(base64Encoded: payload.payloadB64) else {
        throw BridgeTestError.invalidTunneledPayload
    }

    let jsonObject = try JSONSerialization.jsonObject(with: payloadData)
    guard let dictionary = jsonObject as? [String: Any] else {
        throw BridgeTestError.invalidTunneledPayload
    }

    return dictionary
}

@Suite("Group Invite")
struct GroupInviteTests {
    @Test("Group invite Ed25519 signature verifies")
    func ed25519InviteSignatureVerifies() throws {
        let ownerAgreement = Curve25519.KeyAgreement.PrivateKey()
        let ownerSigning = Curve25519.Signing.PrivateKey()
        let inviter = Curve25519.KeyAgreement.PrivateKey()
        let groupID = UUID()
        let expiresAtMS = Int64((Date().addingTimeInterval(600)).timeIntervalSince1970 * 1000)
        let nonce = UUID()

        let signature = try GroupInviteToken.sign(
            groupID: groupID,
            groupName: "Pigeon",
            ownerPublicKey: ownerAgreement.publicKey.rawRepresentation,
            inviterPublicKey: inviter.publicKey.rawRepresentation,
            expiresAtMS: expiresAtMS,
            nonce: nonce,
            ownerSigningPrivateKey: ownerSigning
        )

        let token = GroupInviteToken(
            groupID: groupID,
            groupName: "Pigeon",
            ownerPublicKey: ownerAgreement.publicKey.rawRepresentation,
            ownerSigningPublicKey: ownerSigning.publicKey.rawRepresentation,
            inviterPublicKey: inviter.publicKey.rawRepresentation,
            expiresAtMS: expiresAtMS,
            nonce: nonce,
            signatureHex: signature
        )

        #expect(
            token.isValidSignature(ownerSigningPublicKey: ownerSigning.publicKey.rawRepresentation)
        )
    }

    @Test("Token with signing key but legacy signature is rejected")
    func tokenWithSigningKeyButLegacySignatureIsRejected() {
        let ownerAgreement = Curve25519.KeyAgreement.PrivateKey()
        let attackerSigning = Curve25519.Signing.PrivateKey()
        let inviter = Curve25519.KeyAgreement.PrivateKey()
        let groupID = UUID()
        let expiresAtMS = Int64((Date().addingTimeInterval(600)).timeIntervalSince1970 * 1000)
        let nonce = UUID()

        // Craft a token with attacker's signing key but a legacy SHA-256 "signature"
        // (which anyone can compute from public fields)
        var legacyPayload = Data(groupID.uuidString.utf8)
        legacyPayload.append(Data("TestGroup".utf8))
        legacyPayload.append(ownerAgreement.publicKey.rawRepresentation)
        legacyPayload.append(inviter.publicKey.rawRepresentation)
        var expires = expiresAtMS.bigEndian
        withUnsafeBytes(of: &expires) { legacyPayload.append(contentsOf: $0) }
        legacyPayload.append(Data(nonce.uuidString.utf8))
        legacyPayload.append(ownerAgreement.publicKey.rawRepresentation)
        let digest = SHA256.hash(data: legacyPayload)
        let legacyHex = digest.map { String(format: "%02x", $0) }.joined()

        let token = GroupInviteToken(
            groupID: groupID,
            groupName: "TestGroup",
            ownerPublicKey: ownerAgreement.publicKey.rawRepresentation,
            ownerSigningPublicKey: attackerSigning.publicKey.rawRepresentation,
            inviterPublicKey: inviter.publicKey.rawRepresentation,
            expiresAtMS: expiresAtMS,
            nonce: nonce,
            signatureHex: legacyHex
        )

        // Token claims a signing key but uses legacy signature — must be rejected
        #expect(
            !token.isValidSignature(ownerSigningPublicKey: attackerSigning.publicKey.rawRepresentation)
        )
    }
}
