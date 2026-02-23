import CryptoKit
import Foundation

nonisolated enum CryptoManagerError: Error {
    case invalidPeerPublicKey
    case invalidSenderPublicKey
    case invalidRecipient
    case invalidNonce
    case invalidMessageEncoding
}

nonisolated struct CryptoManager: Sendable {
    private let hkdfSalt = Data("Pigeon-HKDF-Salt-v1".utf8)
    private let hkdfSharedInfo = Data("Pigeon-MVP-E2E".utf8)

    func deriveSharedKey(
        myPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKeyData: Data
    ) throws -> SymmetricKey {
        let peerPublicKey: Curve25519.KeyAgreement.PublicKey

        do {
            peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKeyData)
        } catch {
            throw CryptoManagerError.invalidPeerPublicKey
        }

        let sharedSecret = try myPrivateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)

        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: hkdfSalt,
            sharedInfo: hkdfSharedInfo,
            outputByteCount: 32
        )
    }

    func encrypt(
        plaintext: Data,
        senderPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        recipientPublicKeyData: Data,
        messageID: UUID = UUID(),
        timestamp: Date = Date(),
        hopCount: UInt8 = 0,
        ttl: UInt8 = BLEConstants.defaultTTL
    ) throws -> MessageEnvelope {
        let symmetricKey = try deriveSharedKey(
            myPrivateKey: senderPrivateKey,
            peerPublicKeyData: recipientPublicKeyData
        )

        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)

        return MessageEnvelope(
            id: messageID,
            senderPublicKey: senderPrivateKey.publicKey.rawRepresentation,
            recipientPublicKey: recipientPublicKeyData,
            timestamp: timestamp,
            nonce: Data(nonce),
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag,
            hopCount: hopCount,
            ttl: ttl
        )
    }

    func encrypt(
        plaintext: String,
        senderPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        recipientPublicKeyData: Data,
        messageID: UUID = UUID(),
        timestamp: Date = Date(),
        hopCount: UInt8 = 0,
        ttl: UInt8 = BLEConstants.defaultTTL
    ) throws -> MessageEnvelope {
        try encrypt(
            plaintext: Data(plaintext.utf8),
            senderPrivateKey: senderPrivateKey,
            recipientPublicKeyData: recipientPublicKeyData,
            messageID: messageID,
            timestamp: timestamp,
            hopCount: hopCount,
            ttl: ttl
        )
    }

    func decrypt(
        envelope: MessageEnvelope,
        recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> Data {
        guard envelope.recipientPublicKey == recipientPrivateKey.publicKey.rawRepresentation else {
            throw CryptoManagerError.invalidRecipient
        }

        let senderPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            senderPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: envelope.senderPublicKey)
        } catch {
            throw CryptoManagerError.invalidSenderPublicKey
        }

        let sharedSecret = try recipientPrivateKey.sharedSecretFromKeyAgreement(with: senderPublicKey)
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: hkdfSalt,
            sharedInfo: hkdfSharedInfo,
            outputByteCount: 32
        )

        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: envelope.nonce)
        } catch {
            throw CryptoManagerError.invalidNonce
        }

        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: envelope.ciphertext,
            tag: envelope.tag
        )

        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }

    func decryptToString(
        envelope: MessageEnvelope,
        recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> String {
        let plaintext = try decrypt(envelope: envelope, recipientPrivateKey: recipientPrivateKey)
        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw CryptoManagerError.invalidMessageEncoding
        }
        return text
    }
}
