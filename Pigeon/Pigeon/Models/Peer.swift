import Foundation

nonisolated struct Peer: Identifiable, Hashable, Sendable {
    var id: String { publicKey.hexEncodedString }

    let publicKey: Data
    var pigeonID: String {
        PigeonIdentity.makePigeonID(fromPublicKeyData: publicKey)
    }
    var displayName: String?
    var rssi: Int?
    var firstSeen: Date
    var lastSeen: Date
    var isSaved: Bool
}
