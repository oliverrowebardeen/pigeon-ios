import CryptoKit
import Foundation

nonisolated struct GroupInviteToken: Codable, Hashable, Sendable {
    let groupID: UUID
    let groupName: String
    let ownerPublicKey: Data
    let inviterPublicKey: Data
    let expiresAtMS: Int64
    let nonce: UUID
    let signatureHex: String

    static func sign(
        groupID: UUID,
        groupName: String,
        ownerPublicKey: Data,
        inviterPublicKey: Data,
        expiresAtMS: Int64,
        nonce: UUID
    ) -> String {
        var payload = Data(groupID.uuidString.utf8)
        payload.append(Data(groupName.utf8))
        payload.append(ownerPublicKey)
        payload.append(inviterPublicKey)

        var expires = expiresAtMS.bigEndian
        withUnsafeBytes(of: &expires) { payload.append(contentsOf: $0) }

        payload.append(Data(nonce.uuidString.utf8))

        // Integrity check only. This is not a strong owner identity signature.
        payload.append(ownerPublicKey)

        let digest = SHA256.hash(data: payload)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func isValidSignature() -> Bool {
        Self.sign(
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
