import CryptoKit
import Foundation

nonisolated enum GroupCryptoError: Error {
    case invalidKey
    case invalidNonce
}

nonisolated struct GroupSealedPayload: Codable, Hashable, Sendable {
    let nonce: Data
    let ciphertext: Data
    let tag: Data
}

nonisolated struct GroupCryptoManager: Sendable {
    func generateGroupKey() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    func encrypt(_ plaintext: Data, keyData: Data) throws -> GroupSealedPayload {
        let key = try symmetricKey(from: keyData)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        return GroupSealedPayload(nonce: Data(nonce), ciphertext: sealed.ciphertext, tag: sealed.tag)
    }

    func decrypt(_ payload: GroupSealedPayload, keyData: Data) throws -> Data {
        let key = try symmetricKey(from: keyData)
        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: payload.nonce)
        } catch {
            throw GroupCryptoError.invalidNonce
        }

        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: payload.ciphertext, tag: payload.tag)
        return try AES.GCM.open(sealed, using: key)
    }

    private func symmetricKey(from keyData: Data) throws -> SymmetricKey {
        guard keyData.count == 32 else {
            throw GroupCryptoError.invalidKey
        }
        return SymmetricKey(data: keyData)
    }
}
