import CryptoKit
import Foundation
import Observation
import UIKit

nonisolated enum AppCoordinatorError: Error {
    case untrustedPeerKey
}

nonisolated struct PeerKeyChangeWarning: Identifiable, Sendable {
    let id: String
    let peerPublicKey: Data
    let displayName: String
    let previousPigeonID: String
    let currentPigeonID: String
    let trustAlias: String
}

@Observable
@MainActor
final class AppCoordinator {
    var identity: PigeonIdentity
    let store: PigeonStore
    let bleManager: BLEManager
    let crypto: CryptoManager
    let router: MeshRouter
    private let keyStore: KeyStore
    let relayClient: InternetRelayClient?
    let relayURL: URL?

    var conversations: [Conversation] = []
    var nearbyPeers: [Peer] = []
    var bleState: BLEManager.State = .idle
    var transportState: TransportState = .bleOnly
    var relayPushTokenRegistered = false
    private(set) var messageChangeToken = 0
    private let deliveryQueueTimeoutNanoseconds: UInt64 = 20_000_000_000
    private var deliveryTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var didStartBLE = false
    private var didStartRelay = false
    private var didRestoreOutboundQueue = false
    private var didRunInitialStartup = false
    private var peerKeyChangeWarnings: [Data: PeerKeyChangeWarning] = [:]

    init(store: PigeonStore) throws {
        let identity = try PigeonIdentity.loadOrCreate()
        self.identity = identity
        self.store = store
        self.crypto = CryptoManager()
        self.router = MeshRouter()
        self.keyStore = .shared
        self.bleManager = BLEManager(
            identity: identity,
            crypto: crypto,
            router: router,
            store: store
        )
        relayURL = Self.relayWebSocketURL()
        if let relayURL {
            relayClient = InternetRelayClient(identity: identity, relayURL: relayURL)
            transportState = .internetDisconnected
        } else {
            relayClient = nil
            transportState = .bleOnly
        }
    }

    func bootstrap() {
        activateBLEIfNeeded()
        activateRelayIfNeeded()
        restoreOutboundQueueIfNeeded()
    }

    func start() async {
        bootstrap()
        guard !didRunInitialStartup else { return }
        didRunInitialStartup = true
        let notificationGranted = await NotificationManager.shared.requestPermission()
        if notificationGranted {
            UIApplication.shared.registerForRemoteNotifications()
        }
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
        guard peerKeyChangeWarnings[conversation.peerPublicKey] == nil else {
            throw AppCoordinatorError.untrustedPeerKey
        }

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

            let usedInternetRelay = await sendViaInternetRelayOrFallbackToBLE(
                envelope,
                recipientPublicKey: conversation.peerPublicKey
            )

            let outboundStatus: MessageStatus = usedInternetRelay
                ? .sent
                : (isPeerNearby(publicKey: conversation.peerPublicKey) ? .sent : .queued)
            try store.updateMessageStatus(id: message.id, status: outboundStatus)
            try store.updateConversationPreview(id: conversation.id, preview: text, timestamp: message.timestamp)
            if outboundStatus == .sent {
                scheduleDeliveryTimeout(for: message.id)
            } else {
                cancelDeliveryTimeout(for: message.id)
            }
            markMessagesChanged()

            await loadConversations()

            return Message(
                id: message.id,
                conversationID: message.conversationID,
                senderPublicKey: message.senderPublicKey,
                recipientPublicKey: message.recipientPublicKey,
                plaintext: message.plaintext,
                timestamp: message.timestamp,
                status: outboundStatus,
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
        guard peerKeyChangeWarnings[peer.publicKey] == nil else {
            throw AppCoordinatorError.untrustedPeerKey
        }

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

    func didRegisterRemoteDeviceToken(_ token: Data) {
        relayPushTokenRegistered = true
        guard let relayClient else { return }

        Task {
            await relayClient.registerPushToken(token)
        }
    }

    func handleRemoteNotification(_: [AnyHashable: Any]) {
        guard let relayClient else { return }
        Task {
            await relayClient.reconnect()
        }
    }

    func isPeerNearby(publicKey: Data) -> Bool {
        nearbyPeers.contains(where: { $0.publicKey == publicKey })
    }

    func updateDisplayName(_ newValue: String?) {
        identity.setDisplayName(newValue)
        bleManager.updateDisplayName(identity.displayName)
    }

    func peerKeyChangeWarning(for peer: Peer) -> PeerKeyChangeWarning? {
        peerKeyChangeWarnings[peer.publicKey]
    }

    func peerKeyChangeWarning(for publicKey: Data) -> PeerKeyChangeWarning? {
        peerKeyChangeWarnings[publicKey]
    }

    func confirmPeerKeyChange(for publicKey: Data) {
        guard let warning = peerKeyChangeWarnings[publicKey] else { return }

        do {
            try keyStore.saveKnownPeerPublicKey(publicKey, pigeonID: warning.trustAlias)
            peerKeyChangeWarnings = peerKeyChangeWarnings.filter { $0.value.trustAlias != warning.trustAlias }
        } catch {
            // Keep warning active if trust update cannot be persisted.
        }
    }

    func applicationDidBecomeActive() {
        bootstrap()
        bleManager.refreshRadioActivity(forceRestart: true)
        if let relayClient {
            Task {
                await relayClient.reconnect()
            }
        }
    }

    func applicationDidEnterBackground() {
        bootstrap()
        bleManager.refreshRadioActivity()
    }

    private func sendViaInternetRelayOrFallbackToBLE(
        _ envelope: MessageEnvelope,
        recipientPublicKey: Data
    ) async -> Bool {
        if let relayClient {
            do {
                try await relayClient.sendEnvelope(envelope)
                return true
            } catch {
                // Fall back to BLE if internet relay is unavailable.
            }
        }

        bleManager.sendMessage(envelope, to: recipientPublicKey)
        return false
    }

    private func handleRelayDeliveredEnvelope(_ envelope: MessageEnvelope) async {
        guard envelope.recipientPublicKey == identity.publicKey.rawRepresentation else {
            return
        }

        guard peerKeyChangeWarnings[envelope.senderPublicKey] == nil else {
            return
        }

        if let existing = try? store.fetchMessage(id: envelope.id), existing != nil {
            await acknowledgeRelayMessage(envelope.id)
            return
        }

        do {
            let plaintext = try crypto.decryptToString(
                envelope: envelope,
                recipientPrivateKey: identity.privateKey
            )

            let peer = Peer(
                publicKey: envelope.senderPublicKey,
                displayName: nearbyPeers.first(where: { $0.publicKey == envelope.senderPublicKey })?.displayName,
                firstSeen: Date(),
                lastSeen: Date(),
                isSaved: false
            )

            let conversation = try store.getOrCreateConversation(for: peer)

            let message = Message(
                id: envelope.id,
                conversationID: conversation.id,
                senderPublicKey: envelope.senderPublicKey,
                recipientPublicKey: envelope.recipientPublicKey,
                plaintext: plaintext,
                timestamp: envelope.timestamp,
                status: .delivered,
                isIncoming: true
            )

            try store.saveMessage(message)
            try store.updateConversationPreview(
                id: conversation.id,
                preview: message.plaintext,
                timestamp: message.timestamp
            )
            try store.incrementUnreadCount(conversationID: conversation.id)
            markMessagesChanged()
            await loadConversations()

            let senderName = nearbyPeers.first(where: { $0.publicKey == message.senderPublicKey })?.displayName
                ?? PigeonIdentity.makePigeonID(fromPublicKeyData: message.senderPublicKey)

            NotificationManager.shared.showMessageNotification(
                from: senderName,
                preview: message.plaintext,
                conversationID: conversation.id
            )
        } catch {
            // Drop malformed/un-decryptable relay message.
        }

        await acknowledgeRelayMessage(envelope.id)
    }

    private func acknowledgeRelayMessage(_ messageID: UUID) async {
        guard let relayClient else { return }
        try? await relayClient.sendDeliveryACK(messageID: messageID)
    }

    private func scheduleDeliveryTimeout(for messageID: UUID) {
        cancelDeliveryTimeout(for: messageID)

        deliveryTimeoutTasks[messageID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.deliveryQueueTimeoutNanoseconds ?? 20_000_000_000)
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

        try? store.updateMessageStatus(id: messageID, status: .queued)
        markMessagesChanged()
        await loadConversations()
    }

    private func markMessagesChanged() {
        messageChangeToken &+= 1
    }

    private func updateTrustState(for peer: Peer) {
        if peerKeyChangeWarnings[peer.publicKey] != nil {
            return
        }

        guard let trustAlias = makeTrustAlias(for: peer.displayName) else { return }

        do {
            if let pinnedKey = try keyStore.loadKnownPeerPublicKey(pigeonID: trustAlias) {
                if pinnedKey == peer.publicKey {
                    peerKeyChangeWarnings.removeValue(forKey: peer.publicKey)
                    return
                }

                let warning = PeerKeyChangeWarning(
                    id: peer.publicKey.hexEncodedString,
                    peerPublicKey: peer.publicKey,
                    displayName: peer.displayName ?? peer.pigeonID,
                    previousPigeonID: PigeonIdentity.makePigeonID(fromPublicKeyData: pinnedKey),
                    currentPigeonID: peer.pigeonID,
                    trustAlias: trustAlias
                )
                peerKeyChangeWarnings[peer.publicKey] = warning
                return
            }

            try keyStore.saveKnownPeerPublicKey(peer.publicKey, pigeonID: trustAlias)
            peerKeyChangeWarnings.removeValue(forKey: peer.publicKey)
        } catch {
            let warning = PeerKeyChangeWarning(
                id: peer.publicKey.hexEncodedString,
                peerPublicKey: peer.publicKey,
                displayName: peer.displayName ?? peer.pigeonID,
                previousPigeonID: "unknown",
                currentPigeonID: peer.pigeonID,
                trustAlias: trustAlias
            )
            peerKeyChangeWarnings[peer.publicKey] = warning
        }
    }

    private func makeTrustAlias(for displayName: String?) -> String? {
        guard let displayName else { return nil }
        let normalized = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return nil }

        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return "name.\(hash)"
    }

    private func activateBLEIfNeeded() {
        guard !didStartBLE else { return }
        didStartBLE = true
        bleManager.delegate = self
        bleManager.start()
    }

    private func activateRelayIfNeeded() {
        guard !didStartRelay else { return }
        guard let relayClient else {
            transportState = .bleOnly
            return
        }

        didStartRelay = true
        transportState = .internetDisconnected

        Task {
            await relayClient.setDelegate(self)
            await relayClient.start()
        }
    }

    private func restoreOutboundQueueIfNeeded() {
        guard !didRestoreOutboundQueue else { return }
        didRestoreOutboundQueue = true

        Task {
            await restorePendingOutboundMessages()
        }
    }

    private func restorePendingOutboundMessages() async {
        let pendingMessages = (try? store.fetchPendingOutgoingMessages()) ?? []
        guard !pendingMessages.isEmpty else { return }

        for message in pendingMessages {
            if peerKeyChangeWarnings[message.recipientPublicKey] != nil {
                continue
            }

            do {
                let envelope = try crypto.encrypt(
                    plaintext: message.plaintext,
                    senderPrivateKey: identity.privateKey,
                    recipientPublicKeyData: message.recipientPublicKey,
                    messageID: message.id,
                    timestamp: message.timestamp
                )
                let usedInternetRelay = await sendViaInternetRelayOrFallbackToBLE(
                    envelope,
                    recipientPublicKey: message.recipientPublicKey
                )

                if message.status == .sending || message.status == .sent || message.status == .queued {
                    let updatedStatus: MessageStatus = usedInternetRelay
                        ? .sent
                        : (isPeerNearby(publicKey: message.recipientPublicKey) ? .sent : .queued)
                    try? store.updateMessageStatus(id: message.id, status: updatedStatus)
                }
            } catch {
                try? store.updateMessageStatus(id: message.id, status: .failed)
            }
        }

        markMessagesChanged()
        Task {
            await loadConversations()
        }
    }

    private static func relayWebSocketURL(bundle: Bundle = .main) -> URL? {
        let enabled = (bundle.object(forInfoDictionaryKey: "PigeonRelayEnabled") as? Bool) ?? false
        guard enabled else { return nil }
        guard let relayURLString = bundle.object(forInfoDictionaryKey: "PigeonRelayWebSocketURL") as? String else {
            return nil
        }
        return URL(string: relayURLString)
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
            if peerKeyChangeWarnings[message.senderPublicKey] != nil {
                return
            }

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
            updateTrustState(for: peer)
            if !nearbyPeers.contains(where: { $0.publicKey == peer.publicKey }) {
                nearbyPeers.append(peer)
            }
        }
    }

    nonisolated func bleManager(_ manager: BLEManager, didUpdatePeer peer: Peer) {
        Task { @MainActor in
            updateTrustState(for: peer)
            if let index = nearbyPeers.firstIndex(where: { $0.publicKey == peer.publicKey }) {
                nearbyPeers[index] = peer
            } else {
                nearbyPeers.append(peer)
            }
        }
    }

    nonisolated func bleManager(_ manager: BLEManager, didLosePeer publicKey: Data) {
        Task { @MainActor in
            nearbyPeers.removeAll(where: { $0.publicKey == publicKey })
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

// MARK: - InternetRelayClientDelegate

extension AppCoordinator: InternetRelayClientDelegate {
    nonisolated func relayClientDidConnect() {
        Task { @MainActor in
            transportState = .internetConnected
        }
    }

    nonisolated func relayClientDidDisconnect() {
        Task { @MainActor in
            transportState = relayClient == nil ? .bleOnly : .internetDisconnected
        }
    }

    nonisolated func relayClient(didReceiveEnvelope envelope: MessageEnvelope) {
        Task { @MainActor in
            await handleRelayDeliveredEnvelope(envelope)
        }
    }

    nonisolated func relayClient(didReceiveDeliveryAck messageID: UUID) {
        Task { @MainActor in
            cancelDeliveryTimeout(for: messageID)
            try? store.updateMessageStatus(id: messageID, status: .delivered)
            markMessagesChanged()
            await loadConversations()
        }
    }
}
