import Foundation
import SwiftData

@Model
final class StoredGroup {
    @Attribute(.unique) var id: UUID
    var name: String
    var ownerPublicKey: Data
    var activeEpoch: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        name: String,
        ownerPublicKey: Data,
        activeEpoch: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.ownerPublicKey = ownerPublicKey
        self.activeEpoch = activeEpoch
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    convenience init(from group: Group) {
        self.init(
            id: group.id,
            name: group.name,
            ownerPublicKey: group.ownerPublicKey,
            activeEpoch: group.activeEpoch,
            createdAt: group.createdAt,
            updatedAt: group.updatedAt
        )
    }

    func toDTO() -> Group {
        Group(
            id: id,
            name: name,
            ownerPublicKey: ownerPublicKey,
            activeEpoch: activeEpoch,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
