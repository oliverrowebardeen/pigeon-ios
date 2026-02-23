import Foundation

nonisolated struct Peer: Identifiable, Hashable, Sendable {
    var id: String { pigeonID }

    let publicKey: Data
    let pigeonID: String
    var displayName: String?
    var rssi: Int?
    var firstSeen: Date
    var lastSeen: Date
    var isSaved: Bool
}
