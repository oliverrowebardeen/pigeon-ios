import CryptoKit
import Foundation
import Observation

@Observable
@MainActor
final class AppCoordinator {
    let identity: PigeonIdentity
    let store: PigeonStore
    let bleManager: BLEManager
    let crypto: CryptoManager
    let router: MeshRouter

    var conversations: [Conversation] = []
    var nearbyPeers: [Peer] = []
    var bleState: BLEManager.State = .idle

    init(store: PigeonStore) throws {
        self.identity = try PigeonIdentity.loadOrCreate()
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

        let envelope = try crypto.encrypt(
            plaintext: text,
            senderPrivateKey: identity.privateKey,
            recipientPublicKeyData: conversation.peerPublicKey,
            messageID: message.id
        )

        await router.enqueueOutbound(envelope)
        bleManager.sendMessage(envelope, to: conversation.peerPublicKey)

        try store.updateMessageStatus(id: message.id, status: .sent)
        try store.updateConversationPreview(id: conversation.id, preview: text, timestamp: message.timestamp)

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
            try? store.updateMessageStatus(id: messageID, status: .delivered)
        }
    }

    nonisolated func bleManager(_ manager: BLEManager, didFailMessage messageID: UUID) {
        Task { @MainActor in
            try? store.updateMessageStatus(id: messageID, status: .failed)
        }
    }

    nonisolated func bleManagerDidUpdateState(_ manager: BLEManager) {
        Task { @MainActor in
            bleState = manager.state
        }
    }
}
