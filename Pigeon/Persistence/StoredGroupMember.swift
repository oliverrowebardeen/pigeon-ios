import Foundation
import SwiftData

@Model
final class StoredGroupMember {
    @Attribute(.unique) var id: String
    var groupID: UUID
    var publicKey: Data
    var displayName: String?
    var pigeonID: String
    var roleRaw: String
    var isActive: Bool
    var joinedAt: Date
    var updatedAt: Date

    var role: GroupMemberRole {
        get { GroupMemberRole(rawValue: roleRaw) ?? .member }
        set { roleRaw = newValue.rawValue }
    }

    init(
        id: String,
        groupID: UUID,
        publicKey: Data,
        displayName: String?,
        pigeonID: String,
        roleRaw: String,
        isActive: Bool,
        joinedAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.groupID = groupID
        self.publicKey = publicKey
        self.displayName = displayName
        self.pigeonID = pigeonID
        self.roleRaw = roleRaw
        self.isActive = isActive
        self.joinedAt = joinedAt
        self.updatedAt = updatedAt
    }

    convenience init(from member: GroupMember) {
        self.init(
            id: member.id,
            groupID: member.groupID,
            publicKey: member.publicKey,
            displayName: member.displayName,
            pigeonID: member.pigeonID,
            roleRaw: member.role.rawValue,
            isActive: member.isActive,
            joinedAt: member.joinedAt,
            updatedAt: member.updatedAt
        )
    }

    func toDTO() -> GroupMember {
        GroupMember(
            groupID: groupID,
            publicKey: publicKey,
            displayName: displayName,
            pigeonID: pigeonID,
            role: role,
            isActive: isActive,
            joinedAt: joinedAt,
            updatedAt: updatedAt
        )
    }
}
