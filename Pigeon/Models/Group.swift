import Foundation

nonisolated enum GroupMemberRole: String, Codable, Hashable, Sendable {
    case owner
    case member
}

nonisolated struct Group: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    let ownerPublicKey: Data
    var activeEpoch: Int
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        ownerPublicKey: Data,
        activeEpoch: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.ownerPublicKey = ownerPublicKey
        self.activeEpoch = activeEpoch
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

nonisolated struct GroupMember: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(groupID.uuidString):\(publicKey.base64EncodedString())" }

    let groupID: UUID
    let publicKey: Data
    var displayName: String?
    var pigeonID: String
    var role: GroupMemberRole
    var isActive: Bool
    let joinedAt: Date
    var updatedAt: Date

    init(
        groupID: UUID,
        publicKey: Data,
        displayName: String?,
        pigeonID: String,
        role: GroupMemberRole,
        isActive: Bool = true,
        joinedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.groupID = groupID
        self.publicKey = publicKey
        self.displayName = displayName
        self.pigeonID = pigeonID
        self.role = role
        self.isActive = isActive
        self.joinedAt = joinedAt
        self.updatedAt = updatedAt
    }

    func deactivated(at date: Date = Date()) -> GroupMember {
        var copy = self
        copy.isActive = false
        copy.updatedAt = date
        return copy
    }
}
