import CryptoKit
import Foundation

nonisolated struct GroupInviteToken: Codable, Hashable, Sendable {
    let groupID: UUID
    let groupName: String
    let ownerPublicKey: Data
    let ownerSigningPublicKey: Data?
    let inviterPublicKey: Data
    let expiresAtMS: Int64
    let nonce: UUID
    let signatureHex: String

    private static func basePayload(
        groupID: UUID,
        groupName: String,
        ownerPublicKey: Data,
        inviterPublicKey: Data,
        expiresAtMS: Int64,
        nonce: UUID
    ) -> Data {
        var payload = Data(groupID.uuidString.utf8)
        payload.append(Data(groupName.utf8))
        payload.append(ownerPublicKey)
        payload.append(inviterPublicKey)

        var expires = expiresAtMS.bigEndian
        withUnsafeBytes(of: &expires) { payload.append(contentsOf: $0) }

        payload.append(Data(nonce.uuidString.utf8))
        return payload
    }

    private static func payloadForSigning(
        groupID: UUID,
        groupName: String,
        ownerPublicKey: Data,
        ownerSigningPublicKey: Data,
        inviterPublicKey: Data,
        expiresAtMS: Int64,
        nonce: UUID
    ) -> Data {
        var payload = basePayload(
            groupID: groupID,
            groupName: groupName,
            ownerPublicKey: ownerPublicKey,
            inviterPublicKey: inviterPublicKey,
            expiresAtMS: expiresAtMS,
            nonce: nonce
        )
        payload.append(ownerSigningPublicKey)
        return payload
    }

    private static func legacySignature(
        groupID: UUID,
        groupName: String,
        ownerPublicKey: Data,
        inviterPublicKey: Data,
        expiresAtMS: Int64,
        nonce: UUID
    ) -> String {
        var payload = basePayload(
            groupID: groupID,
            groupName: groupName,
            ownerPublicKey: ownerPublicKey,
            inviterPublicKey: inviterPublicKey,
            expiresAtMS: expiresAtMS,
            nonce: nonce
        )

        payload.append(ownerPublicKey)
        let digest = SHA256.hash(data: payload)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sign(
        groupID: UUID,
        groupName: String,
        ownerPublicKey: Data,
        inviterPublicKey: Data,
        expiresAtMS: Int64,
        nonce: UUID,
        ownerSigningPrivateKey: Curve25519.Signing.PrivateKey
    ) throws -> String {
        let ownerSigningPublicKey = ownerSigningPrivateKey.publicKey.rawRepresentation
        let payload = payloadForSigning(
            groupID: groupID,
            groupName: groupName,
            ownerPublicKey: ownerPublicKey,
            ownerSigningPublicKey: ownerSigningPublicKey,
            inviterPublicKey: inviterPublicKey,
            expiresAtMS: expiresAtMS,
            nonce: nonce
        )
        let signature = try ownerSigningPrivateKey.signature(for: payload)
        return signature.hexEncodedString
    }

    func isValidSignature(ownerSigningPublicKey: Data?) -> Bool {
        if let signature = Data(hexString: signatureHex), signature.count == 64 {
            guard let ownerSigningPublicKey else {
                return false
            }

            if let embeddedOwnerSigningPublicKey = self.ownerSigningPublicKey,
               embeddedOwnerSigningPublicKey != ownerSigningPublicKey {
                return false
            }

            do {
                let publicKey = try Curve25519.Signing.PublicKey(
                    rawRepresentation: ownerSigningPublicKey
                )
                return publicKey.isValidSignature(
                    signature,
                    for: Self.payloadForSigning(
                        groupID: groupID,
                        groupName: groupName,
                        ownerPublicKey: ownerPublicKey,
                        ownerSigningPublicKey: ownerSigningPublicKey,
                        inviterPublicKey: inviterPublicKey,
                        expiresAtMS: expiresAtMS,
                        nonce: nonce
                    )
                )
            } catch {
                return false
            }
        }

        return Self.legacySignature(
            groupID: groupID,
            groupName: groupName,
            ownerPublicKey: ownerPublicKey,
            inviterPublicKey: inviterPublicKey,
            expiresAtMS: expiresAtMS,
            nonce: nonce
        ) == signatureHex
    }

    func isExpired(now: Date = Date()) -> Bool {
        Int64(now.timeIntervalSince1970 * 1000) > expiresAtMS
    }
}
