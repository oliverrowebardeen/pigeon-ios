import CryptoKit
import Foundation
import Observation

@Observable
@MainActor
final class AppCoordinator {
    var identity: PigeonIdentity
    let store: PigeonStore
    let bleManager: BLEManager
    let crypto: CryptoManager
    let router: MeshRouter

    var conversations: [Conversation] = []
    var nearbyPeers: [Peer] = []
    var bleState: BLEManager.State = .idle
    private(set) var messageChangeToken = 0
    private let deliveryFailureTimeoutNanoseconds: UInt64 = 30_000_000_000
    private var deliveryTimeoutTasks: [UUID: Task<Void, Never>] = [:]

    init(store: PigeonStore) throws {
        let identity = try PigeonIdentity.loadOrCreate()
        self.identity = identity
        self.store = store
        self.crypto = CryptoManager()
        self.router = MeshRouter()
        self.bleManager = BLEManager(
            identity: identity,
            crypto: crypto,
            router: router,
            store: store
        )
    }

    func start() async {
        bleManager.delegate = self
        bleManager.start()
        _ = await NotificationManager.shared.requestPermission()
        await loadConversations()
    }

    func loadConversations() async {
        do {
            conversations = try store.fetchAllConversations()
        } catch {
            conversations = []
        }
    }

    func sendMessage(text: String, in conversation: Conversation) async throws -> Message {
        let message = Message(
            conversationID: conversation.id,
            senderPublicKey: identity.publicKey.rawRepresentation,
            recipientPublicKey: conversation.peerPublicKey,
            plaintext: text,
            status: .sending,
            isIncoming: false
        )

        try store.saveMessage(message)
        markMessagesChanged()

        do {
            let envelope = try crypto.encrypt(
                plaintext: text,
                senderPrivateKey: identity.privateKey,
                recipientPublicKeyData: conversation.peerPublicKey,
                messageID: message.id
            )

            bleManager.sendMessage(envelope, to: conversation.peerPublicKey)

            try store.updateMessageStatus(id: message.id, status: .sent)
            try store.updateConversationPreview(id: conversation.id, preview: text, timestamp: message.timestamp)
            scheduleDeliveryTimeout(for: message.id)
            markMessagesChanged()

            await loadConversations()

            return Message(
                id: message.id,
                conversationID: message.conversationID,
                senderPublicKey: message.senderPublicKey,
                recipientPublicKey: message.recipientPublicKey,
                plaintext: message.plaintext,
                timestamp: message.timestamp,
                status: .sent,
                isIncoming: false
            )
        } catch {
            try? store.updateMessageStatus(id: message.id, status: .failed)
            cancelDeliveryTimeout(for: message.id)
            markMessagesChanged()
            await loadConversations()
            throw error
        }
    }

    func startConversation(with peer: Peer) throws -> Conversation {
        let conversation = try store.getOrCreateConversation(for: peer)
        Task { await loadConversations() }
        return conversation
    }

    func deleteConversation(id: UUID) throws {
        try store.deleteConversation(id: id)
        Task { await loadConversations() }
    }

    func messagesForConversation(_ conversationID: UUID) throws -> [Message] {
        try store.fetchMessages(forConversation: conversationID)
    }

    func clearUnread(conversationID: UUID) throws {
        try store.clearUnreadCount(conversationID: conversationID)
        Task { await loadConversations() }
    }

    func isPeerNearby(publicKey: Data) -> Bool {
        nearbyPeers.contains(where: { $0.publicKey == publicKey })
    }

    func updateDisplayName(_ newValue: String?) {
        identity.setDisplayName(newValue)
        bleManager.updateDisplayName(identity.displayName)
    }

    private func scheduleDeliveryTimeout(for messageID: UUID) {
        cancelDeliveryTimeout(for: messageID)

        deliveryTimeoutTasks[messageID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.deliveryFailureTimeoutNanoseconds ?? 30_000_000_000)
            } catch {
                return
            }

            await self?.handleDeliveryTimeout(for: messageID)
        }
    }

    private func cancelDeliveryTimeout(for messageID: UUID) {
        deliveryTimeoutTasks[messageID]?.cancel()
        deliveryTimeoutTasks.removeValue(forKey: messageID)
    }

    private func handleDeliveryTimeout(for messageID: UUID) async {
        deliveryTimeoutTasks.removeValue(forKey: messageID)

        guard let message = (try? store.fetchMessage(id: messageID)) ?? nil else {
            return
        }

        guard message.status == .sending || message.status == .sent else {
            return
        }

        try? store.updateMessageStatus(id: messageID, status: .failed)
        markMessagesChanged()
        await loadConversations()
    }

    private func markMessagesChanged() {
        messageChangeToken &+= 1
    }
}

// MARK: - BLEManagerDelegate

extension AppCoordinator: BLEManagerDelegate {
    nonisolated func bleManager(
        _ manager: BLEManager,
        didReceiveMessage message: Message,
        inConversation conversationID: UUID
    ) {
        Task { @MainActor in
            do {
                try store.saveMessage(message)
                try store.updateConversationPreview(
                    id: conversationID,
                    preview: message.plaintext,
                    timestamp: message.timestamp
                )
                try store.incrementUnreadCount(conversationID: conversationID)
            } catch {
                // Persistence failed
            }

            markMessagesChanged()
            await loadConversations()

            let senderName = nearbyPeers.first(where: { $0.publicKey == message.senderPublicKey })?.displayName
                ?? PigeonIdentity.makePigeonID(fromPublicKeyData: message.senderPublicKey)

            NotificationManager.shared.showMessageNotification(
                from: senderName,
                preview: message.plaintext,
                conversationID: conversationID
            )
        }
    }

    nonisolated func bleManager(_ manager: BLEManager, didDiscoverPeer peer: Peer) {
        Task { @MainActor in
            if !nearbyPeers.contains(where: { $0.pigeonID == peer.pigeonID }) {
                nearbyPeers.append(peer)
            }
        }
    }

    nonisolated func bleManager(_ manager: BLEManager, didUpdatePeer peer: Peer) {
        Task { @MainActor in
            if let index = nearbyPeers.firstIndex(where: { $0.pigeonID == peer.pigeonID }) {
                nearbyPeers[index] = peer
            }
        }
    }

    nonisolated func bleManager(_ manager: BLEManager, didLosePeer pigeonID: String) {
        Task { @MainActor in
            nearbyPeers.removeAll(where: { $0.pigeonID == pigeonID })
        }
    }

    nonisolated func bleManager(_ manager: BLEManager, didDeliverMessage messageID: UUID) {
        Task { @MainActor in
            cancelDeliveryTimeout(for: messageID)
            try? store.updateMessageStatus(id: messageID, status: .delivered)
            markMessagesChanged()
        }
    }

    nonisolated func bleManager(_ manager: BLEManager, didFailMessage messageID: UUID) {
        Task { @MainActor in
            cancelDeliveryTimeout(for: messageID)
            try? store.updateMessageStatus(id: messageID, status: .failed)
            markMessagesChanged()
        }
    }

    nonisolated func bleManagerDidUpdateState(_ manager: BLEManager) {
        Task { @MainActor in
            bleState = manager.state
        }
    }
}
