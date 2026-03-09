import Foundation
import SwiftData

@MainActor
final class PigeonStore {
    let modelContainer: ModelContainer
    private var modelContext: ModelContext { modelContainer.mainContext }

    static let schema = Schema([
        StoredMessage.self,
        StoredConversation.self,
        StoredPeer.self,
        StoredReaction.self,
        StoredGroup.self,
        StoredGroupMember.self
    ])

    init(inMemory: Bool = false) throws {
        if inMemory {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            modelContainer = try ModelContainer(for: Self.schema, configurations: [config])
            return
        }

        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let storeDir = appSupport.appendingPathComponent("Pigeon", isDirectory: true)
        try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let storeURL = storeDir.appendingPathComponent("pigeon.store")
        let config = ModelConfiguration(url: storeURL)

        do {
            modelContainer = try ModelContainer(for: Self.schema, configurations: [config])
        } catch {
            // Schema updates can make old local stores unreadable; wipe and recreate once.
            try? fm.removeItem(at: storeURL)
            try? fm.removeItem(at: URL(fileURLWithPath: storeURL.path + "-shm"))
            try? fm.removeItem(at: URL(fileURLWithPath: storeURL.path + "-wal"))
            modelContainer = try ModelContainer(for: Self.schema, configurations: [config])
        }
    }

    // MARK: - Messages

    func saveMessage(_ message: Message) throws {
        if let existing = try fetchStoredMessage(id: message.id) {
            existing.conversationID = message.conversationID
            existing.groupID = message.groupID
            existing.senderPublicKey = message.senderPublicKey
            existing.recipientPublicKey = message.recipientPublicKey
            existing.plaintext = message.plaintext
            existing.timestamp = message.timestamp
            existing.status = message.status
            existing.isIncoming = message.isIncoming
            existing.replyToMessageID = message.replyToMessageID
            existing.replyPreview = message.replyPreview
            existing.replySenderPublicKey = message.replySenderPublicKey
        } else {
            modelContext.insert(StoredMessage(from: message))
        }
        try modelContext.save()
    }

    func fetchMessages(forConversation conversationID: UUID) throws -> [Message] {
        let predicate = #Predicate<StoredMessage> { $0.conversationID == conversationID }
        let sort = SortDescriptor(\StoredMessage.timestamp, order: .forward)
        let descriptor = FetchDescriptor<StoredMessage>(predicate: predicate, sortBy: [sort])
        return try modelContext.fetch(descriptor).map { $0.toDTO() }
    }

    func updateMessageStatus(id: UUID, status: MessageStatus) throws {
        guard let stored = try fetchStoredMessage(id: id) else { return }
        stored.status = status
        try modelContext.save()
    }

    func fetchMessage(id: UUID) throws -> Message? {
        try fetchStoredMessage(id: id)?.toDTO()
    }

    func fetchPendingOutgoingMessages() throws -> [Message] {
        let sending = MessageStatus.sending.rawValue
        let sent = MessageStatus.sent.rawValue
        let queued = MessageStatus.queued.rawValue
        let predicate = #Predicate<StoredMessage> {
            $0.isIncoming == false &&
            ($0.statusRaw == sending || $0.statusRaw == sent || $0.statusRaw == queued)
        }
        let sort = SortDescriptor(\StoredMessage.timestamp, order: .forward)
        let descriptor = FetchDescriptor<StoredMessage>(predicate: predicate, sortBy: [sort])
        return try modelContext.fetch(descriptor).map { $0.toDTO() }
    }

    func fetchQueuedOutgoingMessages() throws -> [Message] {
        let queued = MessageStatus.queued.rawValue
        let predicate = #Predicate<StoredMessage> {
            $0.isIncoming == false && $0.statusRaw == queued
        }
        let sort = SortDescriptor(\StoredMessage.timestamp, order: .forward)
        let descriptor = FetchDescriptor<StoredMessage>(predicate: predicate, sortBy: [sort])
        return try modelContext.fetch(descriptor).map { $0.toDTO() }
    }

    func markOutgoingMessagesDelivered(
        conversationID: UUID,
        through timestamp: Date
    ) throws {
        let sending = MessageStatus.sending.rawValue
        let sent = MessageStatus.sent.rawValue
        let delivered = MessageStatus.delivered.rawValue
        let predicate = #Predicate<StoredMessage> {
            $0.conversationID == conversationID &&
            $0.isIncoming == false &&
            ($0.statusRaw == sending || $0.statusRaw == sent || $0.statusRaw == delivered) &&
            $0.timestamp <= timestamp
        }
        let descriptor = FetchDescriptor<StoredMessage>(predicate: predicate)
        let messages = try modelContext.fetch(descriptor)
        guard !messages.isEmpty else { return }

        for message in messages where message.status != .failed {
            message.status = .delivered
        }

        try modelContext.save()
    }

    // MARK: - Reactions

    func saveOrReplaceReaction(_ reaction: MessageReaction) throws {
        let predicate = #Predicate<StoredReaction> {
            $0.messageID == reaction.messageID && $0.reactorPublicKey == reaction.reactorPublicKey
        }
        let descriptor = FetchDescriptor<StoredReaction>(predicate: predicate)

        if let existing = try modelContext.fetch(descriptor).first {
            existing.conversationID = reaction.conversationID
            existing.groupID = reaction.groupID
            existing.tapback = reaction.tapback
            existing.timestamp = reaction.timestamp
        } else {
            modelContext.insert(StoredReaction(from: reaction))
        }

        try modelContext.save()
    }

    func removeReaction(messageID: UUID, reactorPublicKey: Data) throws {
        let predicate = #Predicate<StoredReaction> {
            $0.messageID == messageID && $0.reactorPublicKey == reactorPublicKey
        }
        let descriptor = FetchDescriptor<StoredReaction>(predicate: predicate)
        for reaction in try modelContext.fetch(descriptor) {
            modelContext.delete(reaction)
        }
        try modelContext.save()
    }

    func fetchReactions(forConversation conversationID: UUID) throws -> [MessageReaction] {
        let predicate = #Predicate<StoredReaction> { $0.conversationID == conversationID }
        let sort = SortDescriptor(\StoredReaction.timestamp, order: .forward)
        let descriptor = FetchDescriptor<StoredReaction>(predicate: predicate, sortBy: [sort])
        return try modelContext.fetch(descriptor).map { $0.toDTO() }
    }

    func fetchReaction(messageID: UUID, reactorPublicKey: Data) throws -> MessageReaction? {
        let predicate = #Predicate<StoredReaction> {
            $0.messageID == messageID && $0.reactorPublicKey == reactorPublicKey
        }
        let descriptor = FetchDescriptor<StoredReaction>(predicate: predicate)
        return try modelContext.fetch(descriptor).first?.toDTO()
    }

    // MARK: - Conversations

    func saveConversation(_ conversation: Conversation) throws {
        if let existing = try fetchStoredConversation(id: conversation.id) {
            existing.kind = conversation.kind
            existing.peerPublicKey = conversation.peerPublicKey
            existing.peerDisplayName = conversation.peerDisplayName
            existing.peerPigeonID = conversation.peerPigeonID
            existing.groupID = conversation.groupID
            existing.groupName = conversation.groupName
            existing.groupOwnerPublicKey = conversation.groupOwnerPublicKey
            existing.memberCount = conversation.memberCount
            existing.lastMessageTimestamp = conversation.lastMessageTimestamp
            existing.lastMessagePreview = conversation.lastMessagePreview
            existing.unreadCount = conversation.unreadCount
        } else {
            modelContext.insert(StoredConversation(from: conversation))
        }
        try modelContext.save()
    }

    func fetchAllConversations() throws -> [Conversation] {
        let sort = SortDescriptor(\StoredConversation.lastMessageTimestamp, order: .reverse)
        let descriptor = FetchDescriptor<StoredConversation>(sortBy: [sort])
        return try modelContext.fetch(descriptor).map { $0.toDTO() }
    }

    func findConversation(byPeerPublicKey peerPublicKey: Data) throws -> Conversation? {
        let predicate = #Predicate<StoredConversation> { $0.peerPublicKey == peerPublicKey }
        let descriptor = FetchDescriptor<StoredConversation>(predicate: predicate)
        return try modelContext.fetch(descriptor).first?.toDTO()
    }

    func fetchConversation(id: UUID) throws -> Conversation? {
        try fetchStoredConversation(id: id)?.toDTO()
    }

    func findConversation(byGroupID groupID: UUID) throws -> Conversation? {
        let predicate = #Predicate<StoredConversation> { $0.groupID == groupID }
        let descriptor = FetchDescriptor<StoredConversation>(predicate: predicate)
        return try modelContext.fetch(descriptor).first?.toDTO()
    }

    func getOrCreateConversation(for peer: Peer) throws -> Conversation {
        if let existing = try findConversation(byPeerPublicKey: peer.publicKey) {
            return existing
        }

        let conversation = Conversation.direct(
            peerPublicKey: peer.publicKey,
            peerDisplayName: peer.displayName,
            peerPigeonID: peer.pigeonID
        )
        modelContext.insert(StoredConversation(from: conversation))
        try modelContext.save()
        return conversation
    }

    func getOrCreateGroupConversation(for group: Group, memberCount: Int) throws -> Conversation {
        if let existing = try findConversation(byGroupID: group.id) {
            return existing
        }

        let conversation = Conversation.group(
            id: group.id,
            groupName: group.name,
            groupOwnerPublicKey: group.ownerPublicKey,
            memberCount: memberCount
        )
        modelContext.insert(StoredConversation(from: conversation))
        try modelContext.save()
        return conversation
    }

    func updateConversationPreview(id: UUID, preview: String, timestamp: Date) throws {
        guard let stored = try fetchStoredConversation(id: id) else { return }
        stored.lastMessagePreview = String(preview.prefix(100))
        stored.lastMessageTimestamp = timestamp
        try modelContext.save()
    }

    func incrementUnreadCount(conversationID: UUID) throws {
        guard let stored = try fetchStoredConversation(id: conversationID) else { return }
        stored.unreadCount += 1
        try modelContext.save()
    }

    func clearUnreadCount(conversationID: UUID) throws {
        guard let stored = try fetchStoredConversation(id: conversationID) else { return }
        stored.unreadCount = 0
        try modelContext.save()
    }

    func updateConversationPeerName(peerPublicKey: Data, displayName: String?) throws {
        let predicate = #Predicate<StoredConversation> { $0.peerPublicKey == peerPublicKey }
        let descriptor = FetchDescriptor<StoredConversation>(predicate: predicate)
        guard let stored = try modelContext.fetch(descriptor).first else { return }
        stored.peerDisplayName = displayName
        try modelContext.save()
    }

    func updateGroupConversationMetadata(groupID: UUID, groupName: String, memberCount: Int) throws {
        let predicate = #Predicate<StoredConversation> { $0.groupID == groupID }
        let descriptor = FetchDescriptor<StoredConversation>(predicate: predicate)
        guard let stored = try modelContext.fetch(descriptor).first else { return }
        stored.groupName = groupName
        stored.memberCount = memberCount
        try modelContext.save()
    }

    func deleteConversation(id: UUID) throws {
        let conversationPredicate = #Predicate<StoredConversation> { $0.id == id }
        let conversationDescriptor = FetchDescriptor<StoredConversation>(predicate: conversationPredicate)
        guard let storedConversation = try modelContext.fetch(conversationDescriptor).first else { return }
        modelContext.delete(storedConversation)

        let messagePredicate = #Predicate<StoredMessage> { $0.conversationID == id }
        let messageDescriptor = FetchDescriptor<StoredMessage>(predicate: messagePredicate)
        for message in try modelContext.fetch(messageDescriptor) {
            modelContext.delete(message)
        }

        let reactionPredicate = #Predicate<StoredReaction> { $0.conversationID == id }
        let reactionDescriptor = FetchDescriptor<StoredReaction>(predicate: reactionPredicate)
        for reaction in try modelContext.fetch(reactionDescriptor) {
            modelContext.delete(reaction)
        }

        try modelContext.save()
    }

    // MARK: - Groups

    func saveGroup(_ group: Group) throws {
        if let existing = try fetchStoredGroup(id: group.id) {
            existing.name = group.name
            existing.ownerPublicKey = group.ownerPublicKey
            existing.activeEpoch = group.activeEpoch
            existing.updatedAt = group.updatedAt
        } else {
            modelContext.insert(StoredGroup(from: group))
        }
        try modelContext.save()
    }

    func fetchGroup(id: UUID) throws -> Group? {
        try fetchStoredGroup(id: id)?.toDTO()
    }

    func fetchAllGroups() throws -> [Group] {
        let sort = SortDescriptor(\StoredGroup.updatedAt, order: .reverse)
        return try modelContext.fetch(FetchDescriptor<StoredGroup>(sortBy: [sort])).map { $0.toDTO() }
    }

    func saveGroupMember(_ member: GroupMember) throws {
        upsertGroupMember(member)
        try modelContext.save()
    }

    func saveGroupMembers(_ members: [GroupMember]) throws {
        for member in members {
            upsertGroupMember(member)
        }
        try modelContext.save()
    }

    private func upsertGroupMember(_ member: GroupMember) {
        let predicate = #Predicate<StoredGroupMember> {
            $0.groupID == member.groupID && $0.publicKey == member.publicKey
        }
        let descriptor = FetchDescriptor<StoredGroupMember>(predicate: predicate)

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.displayName = member.displayName
            existing.pigeonID = member.pigeonID
            existing.role = member.role
            existing.isActive = member.isActive
            existing.updatedAt = member.updatedAt
        } else {
            modelContext.insert(StoredGroupMember(from: member))
        }
    }

    func fetchGroupMembers(groupID: UUID, activeOnly: Bool = true) throws -> [GroupMember] {
        if activeOnly {
            let predicate = #Predicate<StoredGroupMember> {
                $0.groupID == groupID && $0.isActive == true
            }
            let descriptor = FetchDescriptor<StoredGroupMember>(predicate: predicate)
            return try modelContext.fetch(descriptor).map { $0.toDTO() }
        }

        let predicate = #Predicate<StoredGroupMember> { $0.groupID == groupID }
        let descriptor = FetchDescriptor<StoredGroupMember>(predicate: predicate)
        return try modelContext.fetch(descriptor).map { $0.toDTO() }
    }

    // MARK: - Peers

    func savePeer(_ peer: Peer) throws {
        let peerPublicKey = peer.publicKey
        let predicate = #Predicate<StoredPeer> { $0.publicKey == peerPublicKey }
        let descriptor = FetchDescriptor<StoredPeer>(predicate: predicate)

        if let existing = try modelContext.fetch(descriptor).first {
            existing.displayName = peer.displayName
            existing.isSaved = peer.isSaved
            existing.lastSeen = peer.lastSeen
        } else {
            modelContext.insert(StoredPeer(from: peer))
        }

        try modelContext.save()
    }

    func fetchSavedPeers() throws -> [Peer] {
        let predicate = #Predicate<StoredPeer> { $0.isSaved == true }
        let sort = SortDescriptor(\StoredPeer.lastSeen, order: .reverse)
        let descriptor = FetchDescriptor<StoredPeer>(predicate: predicate, sortBy: [sort])
        return try modelContext.fetch(descriptor).map { $0.toDTO() }
    }

    // MARK: - Destructive

    func deleteAllData() throws {
        try modelContext.delete(model: StoredMessage.self)
        try modelContext.delete(model: StoredConversation.self)
        try modelContext.delete(model: StoredPeer.self)
        try modelContext.delete(model: StoredReaction.self)
        try modelContext.delete(model: StoredGroup.self)
        try modelContext.delete(model: StoredGroupMember.self)
        try modelContext.save()
    }

    // MARK: - Private

    private func fetchStoredMessage(id: UUID) throws -> StoredMessage? {
        let predicate = #Predicate<StoredMessage> { $0.id == id }
        let descriptor = FetchDescriptor<StoredMessage>(predicate: predicate)
        return try modelContext.fetch(descriptor).first
    }

    private func fetchStoredConversation(id: UUID) throws -> StoredConversation? {
        let predicate = #Predicate<StoredConversation> { $0.id == id }
        let descriptor = FetchDescriptor<StoredConversation>(predicate: predicate)
        return try modelContext.fetch(descriptor).first
    }

    private func fetchStoredGroup(id: UUID) throws -> StoredGroup? {
        let predicate = #Predicate<StoredGroup> { $0.id == id }
        let descriptor = FetchDescriptor<StoredGroup>(predicate: predicate)
        return try modelContext.fetch(descriptor).first
    }
}
