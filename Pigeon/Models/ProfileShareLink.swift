import Foundation

nonisolated struct ProfileShareLink: Codable, Hashable, Sendable {
    static let version = 1

    let version: Int
    let publicKeyHex: String
    let pigeonID: String
    let displayName: String?

    init(publicKeyHex: String, pigeonID: String, displayName: String?) {
        version = Self.version
        self.publicKeyHex = publicKeyHex
        self.pigeonID = pigeonID
        self.displayName = displayName
    }
}
