import CryptoKit
import Foundation

nonisolated struct PigeonIdentity: Sendable {
    private static let displayNameDefaultsKey = "pigeon.identity.display-name"

    let privateKey: Curve25519.KeyAgreement.PrivateKey
    var publicKey: Curve25519.KeyAgreement.PublicKey {
        privateKey.publicKey
    }

    var pigeonID: String {
        Self.makePigeonID(fromPublicKeyData: publicKey.rawRepresentation)
    }

    var displayName: String?

    init(privateKey: Curve25519.KeyAgreement.PrivateKey, displayName: String? = nil) {
        self.privateKey = privateKey
        self.displayName = Self.normalizedDisplayName(displayName)
    }

    static func loadOrCreate(
        keyStore: KeyStore = .shared,
        userDefaults: UserDefaults = .standard
    ) throws -> PigeonIdentity {
        let displayName = userDefaults.string(forKey: displayNameDefaultsKey)

        if let rawPrivateKey = try keyStore.loadIdentityPrivateKey() {
            let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
            return PigeonIdentity(privateKey: privateKey, displayName: displayName)
        }

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        try keyStore.saveIdentityPrivateKey(privateKey.rawRepresentation)
        return PigeonIdentity(privateKey: privateKey, displayName: displayName)
    }

    mutating func setDisplayName(_ newValue: String?, userDefaults: UserDefaults = .standard) {
        let normalized = Self.normalizedDisplayName(newValue)
        displayName = normalized
        userDefaults.set(normalized, forKey: Self.displayNameDefaultsKey)
    }

    static func makePigeonID(fromPublicKeyData publicKeyData: Data) -> String {
        let digest = SHA256.hash(data: publicKeyData)
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedDisplayName(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
