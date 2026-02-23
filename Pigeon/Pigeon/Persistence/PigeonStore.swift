import Foundation
import SwiftData

@MainActor
final class PigeonStore {
    let modelContainer: ModelContainer
    private var modelContext: ModelContext { modelContainer.mainContext }

    static let schema = Schema([
        StoredMessage.self,
        StoredConversation.self,
        StoredPeer.self
    ])

    init(inMemory: Bool = false) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        modelContainer = try ModelContainer(for: Self.schema, configurations: [config])
    }

    // MARK: - Messages

    func saveMessage(_ message: Message) throws {
        let stored = StoredMessage(from: message)
        modelContext.insert(stored)
        try modelContext.save()
    }

    func fetchMessages(forConversation conversationID: UUID) throws -> [Message] {
        let predicate = #Predicate<StoredMessage> { $0.conversationID == conversationID }
        let sort = SortDescriptor(\StoredMessage.timestamp, order: .forward)
        let descriptor = FetchDescriptor<StoredMessage>(predicate: predicate, sortBy: [sort])
        return try modelContext.fetch(descriptor).map { $0.toDTO() }
    }

    func updateMessageStatus(id: UUID, status: MessageStatus) throws {
        let predicate = #Predicate<StoredMessage> { $0.id == id }
        let descriptor = FetchDescriptor<StoredMessage>(predicate: predicate)
        guard let stored = try modelContext.fetch(descriptor).first else { return }
        stored.status = status
        try modelContext.save()
    }

    // MARK: - Conversations

    func saveConversation(_ conversation: Conversation) throws {
        let stored = StoredConversation(from: conversation)
        modelContext.insert(stored)
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

    func getOrCreateConversation(for peer: Peer) throws -> Conversation {
        if let existing = try findConversation(byPeerPublicKey: peer.publicKey) {
            return existing
        }

        let conversation = Conversation(
            peerPublicKey: peer.publicKey,
            peerDisplayName: peer.displayName,
            peerPigeonID: peer.pigeonID
        )
        let stored = StoredConversation(from: conversation)
        modelContext.insert(stored)
        try modelContext.save()
        return conversation
    }

    func updateConversationPreview(id: UUID, preview: String, timestamp: Date) throws {
        let predicate = #Predicate<StoredConversation> { $0.id == id }
        let descriptor = FetchDescriptor<StoredConversation>(predicate: predicate)
        guard let stored = try modelContext.fetch(descriptor).first else { return }
        stored.lastMessagePreview = String(preview.prefix(100))
        stored.lastMessageTimestamp = timestamp
        try modelContext.save()
    }

    func incrementUnreadCount(conversationID: UUID) throws {
        let predicate = #Predicate<StoredConversation> { $0.id == conversationID }
        let descriptor = FetchDescriptor<StoredConversation>(predicate: predicate)
        guard let stored = try modelContext.fetch(descriptor).first else { return }
        stored.unreadCount += 1
        try modelContext.save()
    }

    func clearUnreadCount(conversationID: UUID) throws {
        let predicate = #Predicate<StoredConversation> { $0.id == conversationID }
        let descriptor = FetchDescriptor<StoredConversation>(predicate: predicate)
        guard let stored = try modelContext.fetch(descriptor).first else { return }
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

        try modelContext.save()
    }

    // MARK: - Peers

    func savePeer(_ peer: Peer) throws {
        let peerID = peer.pigeonID
        let predicate = #Predicate<StoredPeer> { $0.pigeonID == peerID }
        let descriptor = FetchDescriptor<StoredPeer>(predicate: predicate)

        if let existing = try modelContext.fetch(descriptor).first {
            existing.displayName = peer.displayName
            existing.isSaved = peer.isSaved
            existing.lastSeen = peer.lastSeen
        } else {
            let stored = StoredPeer(from: peer)
            modelContext.insert(stored)
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
        try modelContext.save()
    }
}
