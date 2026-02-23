import Foundation
import SwiftData

@Model
final class StoredPeer {
    @Attribute(.unique) var pigeonID: String
    var publicKey: Data
    var displayName: String?
    var isSaved: Bool
    var firstSeen: Date
    var lastSeen: Date

    init(
        pigeonID: String,
        publicKey: Data,
        displayName: String?,
        isSaved: Bool,
        firstSeen: Date,
        lastSeen: Date
    ) {
        self.pigeonID = pigeonID
        self.publicKey = publicKey
        self.displayName = displayName
        self.isSaved = isSaved
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    convenience init(from peer: Peer) {
        self.init(
            pigeonID: peer.pigeonID,
            publicKey: peer.publicKey,
            displayName: peer.displayName,
            isSaved: peer.isSaved,
            firstSeen: peer.firstSeen,
            lastSeen: peer.lastSeen
        )
    }

    func toDTO(rssi: Int? = nil) -> Peer {
        Peer(
            publicKey: publicKey,
            pigeonID: pigeonID,
            displayName: displayName,
            rssi: rssi,
            firstSeen: firstSeen,
            lastSeen: lastSeen,
            isSaved: isSaved
        )
    }
}
