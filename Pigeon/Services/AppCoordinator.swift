import CryptoKit
import Foundation
import Network
import Observation
import UIKit

nonisolated enum AppCoordinatorError: Error {
    case untrustedPeerKey
    case invalidConversation
    case invalidDirectConversation
    case groupNotFound
    case groupMembershipLimitExceeded
    case notGroupOwner
    case missingGroupKey
    case invalidWirePayload
}

nonisolated struct PeerKeyChangeWarning: Identifiable, Sendable {
    let id: String
    let peerPublicKey: Data
    let displayName: String
    let previousPigeonID: String
    let currentPigeonID: String
    let trustAlias: String
}

nonisolated enum InboundSource: Sendable {
    case ble
    case relay
}

nonisolated enum DirectConversationReachability: Sendable {
    case inRange
    case connectedToInternet
    case outOfRange
}

@Observable
@MainActor
final class AppCoordinator {
    private static let dataModelVersionDefaultsKey = "pigeon.dataModelVersion"
    private static let currentDataModelVersion = 2
    private static let internetBridgeEnabledDefaultsKey = "pigeon.settings.internetBridgeEnabled"
    private static let legacyMeshRelayDefaultsKey = "pigeon.settings.meshRelay"

    private static let wireEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let wireDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    var identity: PigeonIdentity
    let store: PigeonStore
    let bleManager: BLEManager
    let crypto: CryptoManager
    let groupCrypto: GroupCryptoManager
    let router: MeshRouter
    private let keyStore: KeyStore
    let relayClient: InternetRelayClient?
    let bridgeTunnelBroker: BridgeTunnelBroker?
    let relayURL: URL?

    var conversations: [Conversation] = []
    var nearbyPeers: [Peer] = []
    var bleState: BLEManager.State = .idle
    var transportState: TransportState = .bleOnly
    var activeBridge: BridgeCandidate?
    var presentedContactProfile: Peer?
    var relayPushTokenRegistered = false
    var relayPushTokenRegistrationError: String?
    var internetBridgeEnabled: Bool
    private(set) var messageChangeToken = 0

    private let deliveryQueueTimeoutNanoseconds: UInt64 = 20_000_000_000
    private let outboundRetryDebounceNanoseconds: UInt64 = 750_000_000
    private let bridgeDirectUpgradeDelayNanoseconds: UInt64 = 2_000_000_000
    private let bridgeDirectUpgradeRetryBackoffSeconds: TimeInterval = 60
    private let maxGroupMembers = 16
    private let networkPathMonitor = NWPathMonitor()
    private let networkPathMonitorQueue = DispatchQueue(label: "Pigeon.NetworkPathMonitor")
    private var deliveryTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var outboundRetryTask: Task<Void, Never>?
    private var bridgeDirectUpgradeTask: Task<Void, Never>?
    private var bridgeDirectUpgradeNotBefore: Date?
    private var bridgeBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var activeConversationID: UUID?
    private var hasUsableInternetPath = false

    private var didStartBLE = false
    private var didStartRelay = false
    private var didRestoreOutboundQueue = false
    private var didRunInitialStartup = false
    private var isRestoringOutboundMessages = false

    private var peerKeyChangeWarnings: [Data: PeerKeyChangeWarning] = [:]

    init(store: PigeonStore) throws {
        let identity = try PigeonIdentity.loadOrCreate()
        let initialInternetBridgeEnabled = Self.loadInternetBridgeEnabled()
        self.identity = identity
        self.store = store
        internetBridgeEnabled = initialInternetBridgeEnabled
        crypto = CryptoManager()
        groupCrypto = GroupCryptoManager()
        router = MeshRouter()
        keyStore = .shared
        bleManager = BLEManager(
            identity: identity,
            crypto: crypto,
            router: router,
            store: store
        )

        relayURL = Self.relayWebSocketURL()
        if let relayURL {
            relayClient = InternetRelayClient(
                identity: identity,
                relayURL: relayURL,
                bridgeFallbackEnabled: initialInternetBridgeEnabled,
                sendBridgeFrame: { [bleManager] peerPublicKey, frame in
                    try await MainActor.run {
                        try bleManager.sendBridgeFrame(frame, to: peerPublicKey)
                    }
                }
            )
            bridgeTunnelBroker = BridgeTunnelBroker(
                relayURL: relayURL,
                sendBridgeFrame: { [bleManager] peerPublicKey, frame in
                    try await MainActor.run {
                        try bleManager.sendBridgeFrame(frame, to: peerPublicKey)
                    }
                }
            )
            transportState = .internetDisconnected
        } else {
            relayClient = nil
            bridgeTunnelBroker = nil
            transportState = .bleOnly
        }

        bleManager.updateBridgeAvailability(
            enabled: initialInternetBridgeEnabled,
            relayReachable: false,
            capacityRemaining: nil
        )

        try performOneTimeDataResetIfNeeded()
        startNetworkPathMonitoring()
    }

    func bootstrap() {
        activateBLEIfNeeded()
        activateRelayIfNeeded()
        restoreOutboundQueueIfNeeded()
    }

    func start() async {
        guard !didRunInitialStartup else { return }
        didRunInitialStartup = true
        let notificationGranted = await NotificationManager.shared.requestPermissionIfNeeded()
        if notificationGranted {
            UIApplication.shared.registerForRemoteNotifications()
        }
        bootstrap()
        await loadConversations()
    }

    func loadConversations() async {
        do {
            conversations = try store.fetchAllConversations()
        } catch {
            conversations = []
        }
    }

    func sendMessage(text: String, in conversation: Conversation, replyTo replyTarget: Message? = nil) async throws -> Message {
        switch conversation.kind {
        case .direct:
            return try await sendDirectMessage(text: text, in: conversation, replyTo: replyTarget)
        case .group:
            return try await sendGroupMessage(text: text, in: conversation, replyTo: replyTarget)
        }
    }

    func sendReaction(_ tapback: TapbackType, to target: Message, in conversation: Conversation) async throws {
        switch conversation.kind {
        case .direct:
            try await sendDirectReaction(tapback, to: target, in: conversation)
        case .group:
            try await sendGroupReaction(tapback, to: target, in: conversation)
        }
    }

    func createGroup(name: String, memberPublicKeys: [Data]) async throws -> Conversation {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw AppCoordinatorError.invalidConversation
        }

        let ownerKey = identity.publicKey.rawRepresentation
        let uniqueMemberKeys = Array(Set(memberPublicKeys))
            .filter { $0 != ownerKey }

        let totalMembers = uniqueMemberKeys.count + 1
        guard totalMembers <= maxGroupMembers else {
            throw AppCoordinatorError.groupMembershipLimitExceeded
        }

        let groupID = UUID()
        let now = Date()
        let group = Group(
            id: groupID,
            name: trimmedName,
            ownerPublicKey: ownerKey,
            activeEpoch: 1,
            createdAt: now,
            updatedAt: now
        )

        let groupKeyData = groupCrypto.generateGroupKey()
        try keyStore.saveGroupSymmetricKey(groupKeyData, groupID: groupID, epoch: 1)
        try store.saveGroup(group)

        let ownerMember = GroupMember(
            groupID: groupID,
            publicKey: ownerKey,
            displayName: identity.displayName,
            pigeonID: identity.pigeonID,
            role: .owner,
            isActive: true,
            joinedAt: now,
            updatedAt: now
        )
        try store.saveGroupMember(ownerMember)

        for memberKey in uniqueMemberKeys {
            let peer = nearbyPeers.first(where: { $0.publicKey == memberKey })
            let member = GroupMember(
                groupID: groupID,
                publicKey: memberKey,
                displayName: peer?.displayName,
                pigeonID: peer?.pigeonID ?? PigeonIdentity.makePigeonID(fromPublicKeyData: memberKey),
                role: .member,
                isActive: true,
                joinedAt: now,
                updatedAt: now
            )
            try store.saveGroupMember(member)
        }

        let conversation = try store.getOrCreateGroupConversation(for: group, memberCount: totalMembers)
        let memberPayloadKeys = [ownerKey] + uniqueMemberKeys

        for recipientKey in uniqueMemberKeys {
            let keyShare = GroupKeySharePayload(
                groupID: groupID,
                groupName: trimmedName,
                ownerPublicKey: ownerKey,
                epoch: 1,
                keyB64: groupKeyData.base64EncodedString(),
                members: memberPayloadKeys
            )

            let payload = WirePayloadV2(
                eventType: .groupKeyShare,
                logicalMessageID: UUID(),
                conversationID: conversation.id,
                groupID: groupID,
                senderPublicKey: ownerKey,
                groupKeyShare: keyShare
            )

            try await sendWirePayload(payload, to: recipientKey)
        }

        await loadConversations()
        return conversation
    }

    func updateGroupMembers(groupID: UUID, add memberKeysToAdd: [Data], remove memberKeysToRemove: [Data]) async throws {
        guard var group = try store.fetchGroup(id: groupID) else {
            throw AppCoordinatorError.groupNotFound
        }

        let myKey = identity.publicKey.rawRepresentation
        guard group.ownerPublicKey == myKey else {
            throw AppCoordinatorError.notGroupOwner
        }

        let activeMembers = try store.fetchGroupMembers(groupID: groupID, activeOnly: true)
        let activeSet = Set(activeMembers.map { $0.publicKey })
        let currentCount = activeSet.count

        let sanitizedAdds = Array(Set(memberKeysToAdd))
            .filter { !activeSet.contains($0) }
            .filter { $0 != myKey }
        let sanitizedRemoves = Array(Set(memberKeysToRemove))
            .filter { activeSet.contains($0) }
            .filter { $0 != myKey }

        let projectedCount = currentCount + sanitizedAdds.count - sanitizedRemoves.count
        guard projectedCount <= maxGroupMembers else {
            throw AppCoordinatorError.groupMembershipLimitExceeded
        }

        let allMembers = try store.fetchGroupMembers(groupID: groupID, activeOnly: false)
        let allByKey = Dictionary(uniqueKeysWithValues: allMembers.map { ($0.publicKey, $0) })

        let now = Date()

        for key in sanitizedAdds {
            let peer = nearbyPeers.first(where: { $0.publicKey == key })
            let existing = allByKey[key]
            let member = GroupMember(
                groupID: groupID,
                publicKey: key,
                displayName: peer?.displayName ?? existing?.displayName,
                pigeonID: existing?.pigeonID ?? peer?.pigeonID ?? PigeonIdentity.makePigeonID(fromPublicKeyData: key),
                role: .member,
                isActive: true,
                joinedAt: existing?.joinedAt ?? now,
                updatedAt: now
            )
            try store.saveGroupMember(member)
        }

        for key in sanitizedRemoves {
            guard let existing = allByKey[key] else { continue }
            try store.saveGroupMember(existing.deactivated(at: now))
        }

        var keyEpoch = group.activeEpoch
        var keyData = try keyStore.loadGroupSymmetricKey(groupID: groupID, epoch: keyEpoch)

        if !sanitizedRemoves.isEmpty {
            keyEpoch += 1
            keyData = groupCrypto.generateGroupKey()
            try keyStore.saveGroupSymmetricKey(keyData!, groupID: groupID, epoch: keyEpoch)
            group.activeEpoch = keyEpoch
            group.updatedAt = now
            try store.saveGroup(group)
        }

        let refreshedActiveMembers = try store.fetchGroupMembers(groupID: groupID, activeOnly: true)

        if let keyData {
            for member in refreshedActiveMembers where member.publicKey != myKey {
                let share = GroupKeySharePayload(
                    groupID: groupID,
                    groupName: group.name,
                    ownerPublicKey: group.ownerPublicKey,
                    epoch: keyEpoch,
                    keyB64: keyData.base64EncodedString(),
                    members: refreshedActiveMembers.map(\.publicKey)
                )

                let keySharePayload = WirePayloadV2(
                    eventType: .groupKeyShare,
                    logicalMessageID: UUID(),
                    conversationID: groupID,
                    groupID: groupID,
                    senderPublicKey: myKey,
                    groupKeyShare: share
                )

                try await sendWirePayload(keySharePayload, to: member.publicKey)
            }
        }

        let control = GroupControlPayload(
            groupID: groupID,
            action: .membershipUpdate,
            groupName: group.name,
            epoch: keyEpoch,
            addedMemberKeys: sanitizedAdds,
            removedMemberKeys: sanitizedRemoves
        )

        let controlPayload = WirePayloadV2(
            eventType: .groupControl,
            logicalMessageID: UUID(),
            conversationID: groupID,
            groupID: groupID,
            senderPublicKey: myKey,
            groupControl: control
        )

        for member in refreshedActiveMembers where member.publicKey != myKey {
            try await sendWirePayload(controlPayload, to: member.publicKey)
        }

        try store.updateGroupConversationMetadata(
            groupID: groupID,
            groupName: group.name,
            memberCount: refreshedActiveMembers.count
        )

        markMessagesChanged()
        await loadConversations()
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

    func reactionsForConversation(_ conversationID: UUID) throws -> [MessageReaction] {
        try store.fetchReactions(forConversation: conversationID)
    }

    func groupMembers(groupID: UUID) throws -> [GroupMember] {
        try store.fetchGroupMembers(groupID: groupID, activeOnly: false)
    }

    func clearUnread(conversationID: UUID) throws {
        try store.clearUnreadCount(conversationID: conversationID)
        Task { await loadConversations() }
    }

    func setActiveConversation(_ conversationID: UUID?) {
        activeConversationID = conversationID
        guard let conversationID else { return }

        try? store.clearUnreadCount(conversationID: conversationID)
        Task {
            await loadConversations()
            await sendReadReceiptIfNeeded(for: conversationID)
        }
    }

    func presentContactProfile(_ peer: Peer) {
        presentedContactProfile = resolvedPeer(for: peer.publicKey) ?? peer
    }

    func dismissPresentedContactProfile() {
        presentedContactProfile = nil
    }

    func didRegisterRemoteDeviceToken(_ token: Data) {
        relayPushTokenRegistered = true
        relayPushTokenRegistrationError = nil
        guard let relayClient else { return }

        Task {
            await relayClient.registerPushToken(token)
        }
    }

    func didFailRemoteNotificationRegistration(_ error: Error) {
        relayPushTokenRegistered = false
        relayPushTokenRegistrationError = error.localizedDescription
    }

    func setInternetBridgeEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        guard internetBridgeEnabled != enabled else { return }
        internetBridgeEnabled = enabled
        userDefaults.set(enabled, forKey: Self.internetBridgeEnabledDefaultsKey)
        Task {
            await relayClient?.setBridgeFallbackEnabled(enabled)
            await refreshBridgeHostAvailability()
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

    private func canAttemptBLEMeshDelivery(to recipientPublicKey: Data) -> Bool {
        return isPeerNearby(publicKey: recipientPublicKey) || !nearbyPeers.isEmpty
    }

    private func hasAnyRealtimeDeliveryPath(to recipientPublicKey: Data) -> Bool {
        canAttemptBLEMeshDelivery(to: recipientPublicKey) ||
            transportState == .internetDirectConnected ||
            transportState == .internetBridgedConnected
    }

    private func outboundStatusAfterSend(to recipientPublicKey: Data, usedRelay: Bool) -> MessageStatus {
        if usedRelay || canAttemptBLEMeshDelivery(to: recipientPublicKey) {
            return .sent
        }
        return .queued
    }

    private func markOutgoingMessageAsSent(_ messageID: UUID) async {
        cancelDeliveryTimeout(for: messageID)

        guard let message = try? store.fetchMessage(id: messageID),
              message.groupID == nil,
              !message.isIncoming,
              message.status != .failed,
              message.status != .delivered
        else {
            return
        }

        try? store.updateMessageStatus(id: messageID, status: .sent)
        markMessagesChanged()
        await loadConversations()
    }

    private func sendReadReceiptIfNeeded(for conversationID: UUID) async {
        guard let conversation = (try? store.fetchConversation(id: conversationID)) ?? nil,
              conversation.kind == .direct,
              let peerPublicKey = conversation.peerPublicKey
        else {
            return
        }

        let messages = (try? store.fetchMessages(forConversation: conversationID)) ?? []
        guard let latestIncoming = messages.last(where: {
            $0.isIncoming && $0.senderPublicKey == peerPublicKey
        }) else {
            return
        }

        try? await sendDirectReadReceipt(for: latestIncoming, in: conversation)
    }

    func resolvedPeer(for publicKey: Data) -> Peer? {
        let savedPeer = savedPeer(for: publicKey)
        if var nearbyPeer = nearbyPeers.first(where: { $0.publicKey == publicKey }) {
            if let savedPeer {
                nearbyPeer.displayName = savedPeer.displayName ?? nearbyPeer.displayName
                nearbyPeer.firstSeen = savedPeer.firstSeen
                nearbyPeer.lastSeen = max(savedPeer.lastSeen, nearbyPeer.lastSeen)
                nearbyPeer.isSaved = savedPeer.isSaved
            }
            return nearbyPeer
        }

        if let savedPeer {
            return savedPeer
        }

        if let directConversation = conversations.first(where: { $0.kind == .direct && $0.peerPublicKey == publicKey }) {
            return Peer(
                publicKey: publicKey,
                displayName: directConversation.peerDisplayName,
                rssi: nil,
                firstSeen: directConversation.lastMessageTimestamp ?? Date(),
                lastSeen: directConversation.lastMessageTimestamp ?? Date(),
                isSaved: true
            )
        }

        return nil
    }

    func renameContact(publicKey: Data, displayName: String?) throws {
        let trimmedDisplayName: String? = {
            guard let displayName else { return nil }
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        let existingPeer = resolvedPeer(for: publicKey) ?? Peer(
            publicKey: publicKey,
            displayName: trimmedDisplayName,
            rssi: nil,
            firstSeen: Date(),
            lastSeen: Date(),
            isSaved: true
        )

        let updatedPeer = Peer(
            publicKey: existingPeer.publicKey,
            displayName: trimmedDisplayName,
            rssi: existingPeer.rssi,
            firstSeen: existingPeer.firstSeen,
            lastSeen: Date(),
            isSaved: true,
            bridgeProtocolVersion: existingPeer.bridgeProtocolVersion,
            bridgeEnabled: existingPeer.bridgeEnabled,
            relayReachable: existingPeer.relayReachable,
            bridgeCapacityRemaining: existingPeer.bridgeCapacityRemaining
        )

        try store.savePeer(updatedPeer)
        try store.updateConversationPeerName(peerPublicKey: publicKey, displayName: trimmedDisplayName)

        if let peerIndex = nearbyPeers.firstIndex(where: { $0.publicKey == publicKey }) {
            nearbyPeers[peerIndex].displayName = trimmedDisplayName
            nearbyPeers[peerIndex].isSaved = true
            nearbyPeers[peerIndex].lastSeen = Date()
        }

        if let conversationIndex = conversations.firstIndex(where: {
            $0.kind == .direct && $0.peerPublicKey == publicKey
        }) {
            conversations[conversationIndex].peerDisplayName = trimmedDisplayName
        }

        markMessagesChanged()
        Task { await loadConversations() }
    }

    func contactPeers() -> [Peer] {
        var peersByKey: [Data: Peer] = [:]

        for peer in (try? store.fetchSavedPeers()) ?? [] {
            peersByKey[peer.publicKey] = peer
        }

        for conversation in conversations where conversation.kind == .direct {
            guard let key = conversation.peerPublicKey else { continue }
            if peersByKey[key] == nil {
                peersByKey[key] = Peer(
                    publicKey: key,
                    displayName: conversation.peerDisplayName,
                    rssi: nil,
                    firstSeen: conversation.lastMessageTimestamp ?? Date(),
                    lastSeen: conversation.lastMessageTimestamp ?? Date(),
                    isSaved: true
                )
            }
        }

        for peer in nearbyPeers where peer.isSaved || peersByKey[peer.publicKey] != nil {
            if let existing = peersByKey[peer.publicKey] {
                peersByKey[peer.publicKey] = mergedNearbyPeer(peer, into: existing)
            } else {
                peersByKey[peer.publicKey] = peer
            }
        }

        return peersByKey.values
            .filter { $0.publicKey != identity.publicKey.rawRepresentation }
            .sorted { lhs, rhs in
                (lhs.displayName ?? lhs.pigeonID).localizedCaseInsensitiveCompare(rhs.displayName ?? rhs.pigeonID) == .orderedAscending
            }
    }

    private func mergedNearbyPeer(_ nearbyPeer: Peer, into existingPeer: Peer) -> Peer {
        var merged = existingPeer
        merged.displayName = existingPeer.displayName ?? nearbyPeer.displayName
        merged.rssi = nearbyPeer.rssi ?? existingPeer.rssi
        merged.firstSeen = min(existingPeer.firstSeen, nearbyPeer.firstSeen)
        merged.lastSeen = max(existingPeer.lastSeen, nearbyPeer.lastSeen)
        merged.isSaved = existingPeer.isSaved || nearbyPeer.isSaved
        merged.bridgeProtocolVersion = nearbyPeer.bridgeProtocolVersion ?? existingPeer.bridgeProtocolVersion
        merged.bridgeEnabled = nearbyPeer.bridgeEnabled
        merged.relayReachable = nearbyPeer.relayReachable
        merged.bridgeCapacityRemaining = nearbyPeer.bridgeCapacityRemaining ?? existingPeer.bridgeCapacityRemaining
        return merged
    }

    func directConversationReachability(for publicKey: Data?) -> DirectConversationReachability {
        guard let publicKey else { return .outOfRange }

        if isPeerNearby(publicKey: publicKey) {
            return .inRange
        }

        switch transportState {
        case .internetDirectConnected, .internetBridgedConnected:
            return .connectedToInternet
        case .bleOnly, .internetDisconnected:
            return .outOfRange
        }
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
        guard didRunInitialStartup else { return }
        endBridgeBackgroundTaskIfNeeded()
        bootstrap()
        bleManager.refreshRadioActivity(forceRestart: true)
        if let relayClient {
            Task {
                await relayClient.reconnect()
            }
        }
    }

    func applicationDidEnterBackground() {
        guard didRunInitialStartup else { return }
        bootstrap()
        bleManager.refreshRadioActivity()
        updateBridgeBackgroundExecution()
    }

    func candidatePeersForNewGroup() -> [Peer] {
        var peersByKey: [Data: Peer] = [:]

        for peer in nearbyPeers {
            peersByKey[peer.publicKey] = peer
        }

        let savedPeers = (try? store.fetchSavedPeers()) ?? []
        for peer in savedPeers {
            if peersByKey[peer.publicKey] == nil {
                peersByKey[peer.publicKey] = peer
            }
        }

        for conversation in conversations where conversation.kind == .direct {
            guard let key = conversation.peerPublicKey else { continue }
            if peersByKey[key] == nil {
                peersByKey[key] = Peer(
                    publicKey: key,
                    displayName: conversation.peerDisplayName,
                    firstSeen: Date(),
                    lastSeen: Date(),
                    isSaved: true
                )
            }
        }

        return peersByKey.values
            .filter { $0.publicKey != identity.publicKey.rawRepresentation }
            .sorted { lhs, rhs in
                (lhs.displayName ?? lhs.pigeonID) < (rhs.displayName ?? rhs.pigeonID)
            }
    }

    func isCurrentUserGroupOwner(groupID: UUID) -> Bool {
        guard let group = try? store.fetchGroup(id: groupID) else {
            return false
        }
        return group.ownerPublicKey == identity.publicKey.rawRepresentation
    }

    func makeGroupInviteTokenString(groupID: UUID) throws -> String {
        guard let group = try store.fetchGroup(id: groupID) else {
            throw AppCoordinatorError.groupNotFound
        }

        let expiresAtMS = Int64((Date().addingTimeInterval(10 * 60)).timeIntervalSince1970 * 1000)
        let nonce = UUID()
        let signature = GroupInviteToken.sign(
            groupID: group.id,
            groupName: group.name,
            ownerPublicKey: group.ownerPublicKey,
            inviterPublicKey: identity.publicKey.rawRepresentation,
            expiresAtMS: expiresAtMS,
            nonce: nonce
        )

        let token = GroupInviteToken(
            groupID: group.id,
            groupName: group.name,
            ownerPublicKey: group.ownerPublicKey,
            inviterPublicKey: identity.publicKey.rawRepresentation,
            expiresAtMS: expiresAtMS,
            nonce: nonce,
            signatureHex: signature
        )

        let data = try Self.wireEncoder.encode(token)
        return data.base64EncodedString()
    }

    func makeGroupInviteURL(groupID: UUID) throws -> URL {
        let token = try makeGroupInviteTokenString(groupID: groupID)
        guard let tokenData = Data(base64Encoded: token) else {
            throw AppCoordinatorError.invalidWirePayload
        }

        var components = URLComponents()
        components.scheme = "pigeon"
        components.host = "group-invite"
        components.queryItems = [
            URLQueryItem(name: "token", value: tokenData.base64URLEncodedString)
        ]

        guard let url = components.url else {
            throw AppCoordinatorError.invalidWirePayload
        }

        return url
    }

    func makeProfileShareURL() -> URL? {
        let payload = ProfileShareLink(
            publicKeyHex: identity.publicKey.rawRepresentation.hexEncodedString,
            pigeonID: identity.pigeonID,
            displayName: identity.displayName
        )

        guard let data = try? Self.wireEncoder.encode(payload) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "pigeon"
        components.host = "profile"
        components.queryItems = [
            URLQueryItem(name: "token", value: data.base64URLEncodedString)
        ]

        return components.url
    }

    @discardableResult
    func consumeProfileShareString(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        guard let url = URL(string: trimmed) else {
            return false
        }
        return consumeProfileShareURL(url)
    }

    @discardableResult
    func consumeLegacyProfilePublicKeyHex(_ value: String) -> Bool {
        guard let publicKey = Data(hexString: value) else {
            return false
        }

        let myKey = identity.publicKey.rawRepresentation
        if publicKey == myKey {
            return true
        }

        let peer = Peer(
            publicKey: publicKey,
            displayName: nil,
            rssi: nil,
            firstSeen: Date(),
            lastSeen: Date(),
            isSaved: true
        )

        do {
            try store.savePeer(peer)
            _ = try store.getOrCreateConversation(for: peer)
            presentContactProfile(peer)
            markMessagesChanged()
            Task {
                await loadConversations()
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func consumeProfileShareURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "pigeon" else {
            return false
        }
        let host = url.host?.lowercased()
        let path = url.path.lowercased()
        guard host == "profile" || path == "/profile" else {
            return false
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        guard let token = components.queryItems?.first(where: { $0.name == "token" })?.value else {
            return false
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64URLEncoded: trimmedToken) ?? Data(base64Encoded: trimmedToken) else {
            return false
        }
        guard let payload = try? Self.wireDecoder.decode(ProfileShareLink.self, from: data) else {
            return false
        }
        guard payload.version == ProfileShareLink.version else {
            return false
        }
        guard let publicKey = Data(hexString: payload.publicKeyHex) else {
            return false
        }

        let myKey = identity.publicKey.rawRepresentation
        if publicKey == myKey {
            return true
        }

        let normalizedDisplayName: String? = {
            guard let payloadName = payload.displayName else { return nil }
            let trimmed = payloadName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        let peer = Peer(
            publicKey: publicKey,
            displayName: normalizedDisplayName,
            rssi: nil,
            firstSeen: Date(),
            lastSeen: Date(),
            isSaved: true
        )

        do {
            try store.savePeer(peer)
            _ = try store.getOrCreateConversation(for: peer)
            presentContactProfile(peer)
            markMessagesChanged()
            Task {
                await loadConversations()
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func consumeGroupInviteURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "pigeon" else {
            return false
        }

        let host = url.host?.lowercased()
        let path = url.path.lowercased()
        guard host == "group-invite" || path == "/group-invite" else {
            return false
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        else {
            return false
        }

        do {
            _ = try consumeGroupInviteTokenString(token)
            return true
        } catch {
            return false
        }
    }

    func consumeGroupInviteTokenString(_ tokenString: String) throws -> Conversation {
        let trimmed = tokenString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64URLEncoded: trimmed) ?? Data(base64Encoded: trimmed) else {
            throw AppCoordinatorError.invalidWirePayload
        }

        let token = try Self.wireDecoder.decode(GroupInviteToken.self, from: data)
        guard token.isValidSignature(), !token.isExpired() else {
            throw AppCoordinatorError.invalidWirePayload
        }

        let now = Date()
        let existingGroup = try store.fetchGroup(id: token.groupID)
        let group = Group(
            id: token.groupID,
            name: token.groupName,
            ownerPublicKey: token.ownerPublicKey,
            activeEpoch: existingGroup?.activeEpoch ?? 1,
            createdAt: existingGroup?.createdAt ?? now,
            updatedAt: now
        )
        try store.saveGroup(group)

        let ownerMember = GroupMember(
            groupID: token.groupID,
            publicKey: token.ownerPublicKey,
            displayName: nearbyPeers.first(where: { $0.publicKey == token.ownerPublicKey })?.displayName,
            pigeonID: PigeonIdentity.makePigeonID(fromPublicKeyData: token.ownerPublicKey),
            role: .owner,
            isActive: true,
            joinedAt: now,
            updatedAt: now
        )
        try store.saveGroupMember(ownerMember)

        let myMember = GroupMember(
            groupID: token.groupID,
            publicKey: identity.publicKey.rawRepresentation,
            displayName: identity.displayName,
            pigeonID: identity.pigeonID,
            role: .member,
            isActive: true,
            joinedAt: now,
            updatedAt: now
        )
        try store.saveGroupMember(myMember)

        let memberCount = try store.fetchGroupMembers(groupID: token.groupID, activeOnly: true).count
        let conversation = try store.getOrCreateGroupConversation(for: group, memberCount: memberCount)
        try store.updateGroupConversationMetadata(groupID: token.groupID, groupName: token.groupName, memberCount: memberCount)

        markMessagesChanged()
        Task { await loadConversations() }
        return conversation
    }

    func displayName(for publicKey: Data) -> String {
        if publicKey == identity.publicKey.rawRepresentation {
            return identity.displayName ?? identity.pigeonID
        }

        if let peer = resolvedPeer(for: publicKey) {
            return peer.displayName ?? peer.pigeonID
        }

        if let directConversation = conversations.first(where: { $0.kind == .direct && $0.peerPublicKey == publicKey }) {
            return directConversation.peerDisplayName ?? (directConversation.peerPigeonID ?? directConversation.derivedPeerPigeonID)
        }

        return PigeonIdentity.makePigeonID(fromPublicKeyData: publicKey)
    }

    private func savedPeer(for publicKey: Data) -> Peer? {
        (try? store.fetchSavedPeers())?.first(where: { $0.publicKey == publicKey })
    }

    private func sendDirectMessage(text: String, in conversation: Conversation, replyTo replyTarget: Message?) async throws -> Message {
        guard let recipientKey = conversation.peerPublicKey else {
            throw AppCoordinatorError.invalidDirectConversation
        }

        guard peerKeyChangeWarnings[recipientKey] == nil else {
            throw AppCoordinatorError.untrustedPeerKey
        }

        let replyMetadata = makeReplyMetadata(from: replyTarget)

        let message = Message(
            conversationID: conversation.id,
            groupID: nil,
            senderPublicKey: identity.publicKey.rawRepresentation,
            recipientPublicKey: recipientKey,
            plaintext: text,
            status: .sending,
            isIncoming: false,
            replyToMessageID: replyMetadata?.replyToMessageID,
            replyPreview: replyMetadata?.replyPreview,
            replySenderPublicKey: replyMetadata?.replySenderPublicKey
        )

        try store.saveMessage(message)
        markMessagesChanged()

        do {
            let payload = WirePayloadV2(
                eventType: .directText,
                logicalMessageID: message.id,
                conversationID: conversation.id,
                senderPublicKey: identity.publicKey.rawRepresentation,
                directText: DirectTextPayload(text: text, reply: replyMetadata)
            )
            let payloadData = try Self.wireEncoder.encode(payload)

            let envelope = try crypto.encrypt(
                plaintext: payloadData,
                senderPrivateKey: identity.privateKey,
                recipientPublicKeyData: recipientKey,
                messageID: message.id,
                timestamp: message.timestamp
            )

            let usedInternetRelay = await sendViaAvailableTransports(
                envelope,
                recipientPublicKey: recipientKey
            )

            let outboundStatus = outboundStatusAfterSend(
                to: recipientKey,
                usedRelay: usedInternetRelay
            )

            try store.updateMessageStatus(id: message.id, status: outboundStatus)
            try store.updateConversationPreview(id: conversation.id, preview: text, timestamp: message.timestamp)

            if outboundStatus == .sent {
                scheduleDeliveryTimeout(for: message.id)
            } else {
                cancelDeliveryTimeout(for: message.id)
            }

            markMessagesChanged()
            await loadConversations()

            return message.withStatus(outboundStatus)
        } catch {
            try? store.updateMessageStatus(id: message.id, status: .failed)
            cancelDeliveryTimeout(for: message.id)
            markMessagesChanged()
            await loadConversations()
            throw error
        }
    }

    private func sendGroupMessage(text: String, in conversation: Conversation, replyTo replyTarget: Message?) async throws -> Message {
        guard conversation.kind == .group, let groupID = conversation.groupID else {
            throw AppCoordinatorError.invalidConversation
        }

        guard let group = try store.fetchGroup(id: groupID) else {
            throw AppCoordinatorError.groupNotFound
        }

        guard let groupKey = try keyStore.loadGroupSymmetricKey(groupID: groupID, epoch: group.activeEpoch) else {
            throw AppCoordinatorError.missingGroupKey
        }

        let replyMetadata = makeReplyMetadata(from: replyTarget)

        let message = Message(
            conversationID: conversation.id,
            groupID: groupID,
            senderPublicKey: identity.publicKey.rawRepresentation,
            recipientPublicKey: nil,
            plaintext: text,
            status: .sending,
            isIncoming: false,
            replyToMessageID: replyMetadata?.replyToMessageID,
            replyPreview: replyMetadata?.replyPreview,
            replySenderPublicKey: replyMetadata?.replySenderPublicKey
        )

        try store.saveMessage(message)
        markMessagesChanged()

        do {
            let innerPayload = GroupInnerPayload(text: GroupTextPayload(text: text, reply: replyMetadata))
            let innerData = try Self.wireEncoder.encode(innerPayload)

            let encrypted = try GroupEncryptedPayload.encrypting(
                innerData, groupID: groupID, epoch: group.activeEpoch,
                using: groupCrypto, keyData: groupKey
            )

            let payload = WirePayloadV2(
                eventType: .groupMessage,
                logicalMessageID: message.id,
                conversationID: conversation.id,
                groupID: groupID,
                senderPublicKey: identity.publicKey.rawRepresentation,
                groupEncrypted: encrypted
            )

            let didSend = try await sendGroupPayload(payload, groupID: groupID)
            let status: MessageStatus = didSend ? .sent : .queued

            try store.updateMessageStatus(id: message.id, status: status)
            try store.updateConversationPreview(id: conversation.id, preview: text, timestamp: message.timestamp)

            markMessagesChanged()
            await loadConversations()

            return message.withStatus(status)
        } catch {
            try? store.updateMessageStatus(id: message.id, status: .failed)
            markMessagesChanged()
            await loadConversations()
            throw error
        }
    }

    private func sendDirectReaction(_ tapback: TapbackType, to target: Message, in conversation: Conversation) async throws {
        guard let recipientKey = conversation.peerPublicKey else {
            throw AppCoordinatorError.invalidDirectConversation
        }

        let myKey = identity.publicKey.rawRepresentation
        let isRemoval = try toggleLocalReaction(tapback, targetMessageID: target.id, conversationID: conversation.id, groupID: nil)

        let payload = WirePayloadV2(
            eventType: .directReaction,
            logicalMessageID: UUID(),
            conversationID: conversation.id,
            senderPublicKey: myKey,
            directReaction: DirectReactionPayload(
                targetMessageID: target.id,
                tapback: tapback,
                isRemoval: isRemoval
            )
        )

        try await sendWirePayload(payload, to: recipientKey)
    }

    private func sendDirectReadReceipt(for target: Message, in conversation: Conversation) async throws {
        guard let recipientKey = conversation.peerPublicKey else {
            throw AppCoordinatorError.invalidDirectConversation
        }

        let payload = WirePayloadV2(
            eventType: .directReadReceipt,
            logicalMessageID: UUID(),
            conversationID: conversation.id,
            senderPublicKey: identity.publicKey.rawRepresentation,
            directReadReceipt: DirectReadReceiptPayload(targetMessageID: target.id)
        )

        try await sendWirePayload(payload, to: recipientKey)
    }

    private func sendGroupReaction(_ tapback: TapbackType, to target: Message, in conversation: Conversation) async throws {
        guard let groupID = conversation.groupID else {
            throw AppCoordinatorError.invalidConversation
        }

        guard let group = try store.fetchGroup(id: groupID) else {
            throw AppCoordinatorError.groupNotFound
        }

        guard let keyData = try keyStore.loadGroupSymmetricKey(groupID: groupID, epoch: group.activeEpoch) else {
            throw AppCoordinatorError.missingGroupKey
        }

        let myKey = identity.publicKey.rawRepresentation
        let isRemoval = try toggleLocalReaction(tapback, targetMessageID: target.id, conversationID: conversation.id, groupID: groupID)

        let inner = GroupInnerPayload(
            reaction: GroupReactionPayload(
                targetMessageID: target.id,
                tapback: tapback,
                isRemoval: isRemoval
            )
        )
        let innerData = try Self.wireEncoder.encode(inner)

        let encrypted = try GroupEncryptedPayload.encrypting(
            innerData, groupID: groupID, epoch: group.activeEpoch,
            using: groupCrypto, keyData: keyData
        )

        let payload = WirePayloadV2(
            eventType: .groupReaction,
            logicalMessageID: UUID(),
            conversationID: conversation.id,
            groupID: groupID,
            senderPublicKey: myKey,
            groupEncrypted: encrypted
        )

        _ = try await sendGroupPayload(payload, groupID: groupID)
    }

    private func toggleLocalReaction(
        _ tapback: TapbackType,
        targetMessageID: UUID,
        conversationID: UUID,
        groupID: UUID?
    ) throws -> Bool {
        let myKey = identity.publicKey.rawRepresentation
        let existing = try store.fetchReaction(messageID: targetMessageID, reactorPublicKey: myKey)
        let isRemoval = existing?.tapback == tapback

        if isRemoval {
            try store.removeReaction(messageID: targetMessageID, reactorPublicKey: myKey)
        } else {
            let reaction = MessageReaction(
                messageID: targetMessageID,
                conversationID: conversationID,
                groupID: groupID,
                reactorPublicKey: myKey,
                tapback: tapback
            )
            try store.saveOrReplaceReaction(reaction)
        }
        markMessagesChanged()
        return isRemoval
    }

    func processIncomingEnvelope(_ envelope: MessageEnvelope, source: InboundSource) async {
        guard envelope.recipientPublicKey == identity.publicKey.rawRepresentation else {
            return
        }

        guard peerKeyChangeWarnings[envelope.senderPublicKey] == nil else {
            return
        }

        do {
            let decrypted = try crypto.decrypt(envelope: envelope, recipientPrivateKey: identity.privateKey)
            let payload = try Self.wireDecoder.decode(WirePayloadV2.self, from: decrypted)

            try await applyIncomingPayload(payload, source: source)

            // ACK only after successful decryption and processing
            if source == .ble {
                bleManager.sendACK(for: envelope)
            }
        } catch {
            // Drop malformed or undecryptable envelope payload — no ACK sent.
        }

        if source == .relay {
            await acknowledgeRelayMessage(envelope.id)
        }
    }

    private func applyIncomingPayload(_ payload: WirePayloadV2, source: InboundSource) async throws {
        switch payload.eventType {
        case .directText:
            try handleIncomingDirectText(payload, source: source)
        case .directReadReceipt:
            try handleIncomingDirectReadReceipt(payload)
        case .directReaction:
            try handleIncomingDirectReaction(payload)
        case .groupKeyShare:
            try handleIncomingGroupKeyShare(payload)
        case .groupControl:
            try handleIncomingGroupControl(payload)
        case .groupMessage:
            try handleIncomingGroupMessage(payload, source: source)
        case .groupReaction:
            try handleIncomingGroupReaction(payload)
        }

        markMessagesChanged()
        await loadConversations()
    }

    private func handleIncomingDirectText(_ payload: WirePayloadV2, source: InboundSource) throws {
        guard let directText = payload.directText else {
            throw AppCoordinatorError.invalidWirePayload
        }

        if (try store.fetchMessage(id: payload.logicalMessageID)) != nil {
            return
        }

        let senderPeer = Peer(
            publicKey: payload.senderPublicKey,
            displayName: nearbyPeers.first(where: { $0.publicKey == payload.senderPublicKey })?.displayName,
            firstSeen: Date(),
            lastSeen: Date(),
            isSaved: false
        )

        let conversation = try store.getOrCreateConversation(for: senderPeer)

        let message = Message(
            id: payload.logicalMessageID,
            conversationID: conversation.id,
            groupID: nil,
            senderPublicKey: payload.senderPublicKey,
            recipientPublicKey: identity.publicKey.rawRepresentation,
            plaintext: directText.text,
            timestamp: payload.timestamp,
            status: .delivered,
            isIncoming: true,
            replyToMessageID: directText.reply?.replyToMessageID,
            replyPreview: directText.reply?.replyPreview,
            replySenderPublicKey: directText.reply?.replySenderPublicKey
        )

        try store.saveMessage(message)
        try store.updateConversationPreview(id: conversation.id, preview: message.plaintext, timestamp: message.timestamp)
        if shouldIncrementUnread(for: conversation.id) {
            try store.incrementUnreadCount(conversationID: conversation.id)
        }

        if shouldShowLocalNotification(for: conversation.id, source: source) {
            let senderName = displayName(for: message.senderPublicKey)
            NotificationManager.shared.showMessageNotification(
                from: senderName,
                preview: message.plaintext,
                conversationID: conversation.id
            )
        }

        if isConversationActivelyVisible(conversation.id) {
            Task {
                await sendReadReceiptIfNeeded(for: conversation.id)
            }
        }
    }

    private func handleIncomingDirectReadReceipt(_ payload: WirePayloadV2) throws {
        guard let readReceipt = payload.directReadReceipt else {
            throw AppCoordinatorError.invalidWirePayload
        }

        guard let targetMessage = try store.fetchMessage(id: readReceipt.targetMessageID),
              !targetMessage.isIncoming,
              targetMessage.recipientPublicKey == payload.senderPublicKey
        else {
            return
        }

        try store.markOutgoingMessagesDelivered(
            conversationID: targetMessage.conversationID,
            through: targetMessage.timestamp
        )
    }

    private func handleIncomingDirectReaction(_ payload: WirePayloadV2) throws {
        guard let reactionPayload = payload.directReaction else {
            throw AppCoordinatorError.invalidWirePayload
        }

        let conversationID: UUID
        if let targetMessage = try store.fetchMessage(id: reactionPayload.targetMessageID) {
            conversationID = targetMessage.conversationID
        } else {
            let senderPeer = Peer(
                publicKey: payload.senderPublicKey,
                displayName: nearbyPeers.first(where: { $0.publicKey == payload.senderPublicKey })?.displayName,
                firstSeen: Date(),
                lastSeen: Date(),
                isSaved: false
            )

            let conversation = try store.getOrCreateConversation(for: senderPeer)
            conversationID = conversation.id
        }

        if reactionPayload.isRemoval {
            try store.removeReaction(messageID: reactionPayload.targetMessageID, reactorPublicKey: payload.senderPublicKey)
        } else {
            let reaction = MessageReaction(
                messageID: reactionPayload.targetMessageID,
                conversationID: conversationID,
                groupID: nil,
                reactorPublicKey: payload.senderPublicKey,
                tapback: reactionPayload.tapback,
                timestamp: payload.timestamp
            )
            try store.saveOrReplaceReaction(reaction)
        }
    }

    private func handleIncomingGroupKeyShare(_ payload: WirePayloadV2) throws {
        guard let keyShare = payload.groupKeyShare,
              let keyData = Data(base64Encoded: keyShare.keyB64)
        else {
            throw AppCoordinatorError.invalidWirePayload
        }

        let existing = try store.fetchGroup(id: keyShare.groupID)
        let group = Group(
            id: keyShare.groupID,
            name: keyShare.groupName,
            ownerPublicKey: keyShare.ownerPublicKey,
            activeEpoch: keyShare.epoch,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date()
        )

        try store.saveGroup(group)
        try keyStore.saveGroupSymmetricKey(keyData, groupID: keyShare.groupID, epoch: keyShare.epoch)

        for memberKey in Set(keyShare.members + [keyShare.ownerPublicKey]) {
            let peer = nearbyPeers.first(where: { $0.publicKey == memberKey })
            let member = GroupMember(
                groupID: keyShare.groupID,
                publicKey: memberKey,
                displayName: peer?.displayName,
                pigeonID: peer?.pigeonID ?? PigeonIdentity.makePigeonID(fromPublicKeyData: memberKey),
                role: memberKey == keyShare.ownerPublicKey ? .owner : .member,
                isActive: true,
                joinedAt: Date(),
                updatedAt: Date()
            )
            try store.saveGroupMember(member)
        }

        let memberCount = try store.fetchGroupMembers(groupID: keyShare.groupID, activeOnly: true).count
        _ = try store.getOrCreateGroupConversation(for: group, memberCount: memberCount)
        try store.updateGroupConversationMetadata(groupID: keyShare.groupID, groupName: keyShare.groupName, memberCount: memberCount)
    }

    private func handleIncomingGroupControl(_ payload: WirePayloadV2) throws {
        guard let control = payload.groupControl else {
            throw AppCoordinatorError.invalidWirePayload
        }

        guard var group = try store.fetchGroup(id: control.groupID) else {
            return
        }

        guard payload.senderPublicKey == group.ownerPublicKey else {
            return
        }

        if let groupName = control.groupName, !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            group.name = groupName
        }
        if control.epoch > group.activeEpoch {
            group.activeEpoch = control.epoch
        }
        group.updatedAt = Date()
        try store.saveGroup(group)

        let allMembers = try store.fetchGroupMembers(groupID: control.groupID, activeOnly: false)
        let byKey = Dictionary(uniqueKeysWithValues: allMembers.map { ($0.publicKey, $0) })

        for key in control.addedMemberKeys {
            let existing = byKey[key]
            let peer = nearbyPeers.first(where: { $0.publicKey == key })
            let member = GroupMember(
                groupID: control.groupID,
                publicKey: key,
                displayName: peer?.displayName ?? existing?.displayName,
                pigeonID: existing?.pigeonID ?? peer?.pigeonID ?? PigeonIdentity.makePigeonID(fromPublicKeyData: key),
                role: existing?.role ?? .member,
                isActive: true,
                joinedAt: existing?.joinedAt ?? Date(),
                updatedAt: Date()
            )
            try store.saveGroupMember(member)
        }

        for key in control.removedMemberKeys {
            guard let existing = byKey[key] else { continue }
            try store.saveGroupMember(existing.deactivated())
        }

        let count = try store.fetchGroupMembers(groupID: control.groupID, activeOnly: true).count
        try store.updateGroupConversationMetadata(groupID: control.groupID, groupName: group.name, memberCount: count)
    }

    private func handleIncomingGroupMessage(_ payload: WirePayloadV2, source: InboundSource) throws {
        guard let groupEncrypted = payload.groupEncrypted else {
            throw AppCoordinatorError.invalidWirePayload
        }

        if (try store.fetchMessage(id: payload.logicalMessageID)) != nil {
            return
        }

        let groupID = groupEncrypted.groupID
        guard let group = try store.fetchGroup(id: groupID) else {
            return
        }

        guard let keyData = try keyStore.loadGroupSymmetricKey(groupID: groupID, epoch: groupEncrypted.epoch) else {
            return
        }

        let inner = try decryptGroupInner(groupEncrypted, keyData: keyData)
        guard inner.payloadType == .text, let text = inner.text else {
            throw AppCoordinatorError.invalidWirePayload
        }

        let conversation = try store.getOrCreateGroupConversation(
            for: group,
            memberCount: try store.fetchGroupMembers(groupID: groupID, activeOnly: true).count
        )

        let message = Message(
            id: payload.logicalMessageID,
            conversationID: conversation.id,
            groupID: groupID,
            senderPublicKey: payload.senderPublicKey,
            recipientPublicKey: nil,
            plaintext: text.text,
            timestamp: payload.timestamp,
            status: .delivered,
            isIncoming: true,
            replyToMessageID: text.reply?.replyToMessageID,
            replyPreview: text.reply?.replyPreview,
            replySenderPublicKey: text.reply?.replySenderPublicKey
        )

        try store.saveMessage(message)
        try store.updateConversationPreview(id: conversation.id, preview: text.text, timestamp: payload.timestamp)
        if shouldIncrementUnread(for: conversation.id) {
            try store.incrementUnreadCount(conversationID: conversation.id)
        }

        if shouldShowLocalNotification(for: conversation.id, source: source) {
            NotificationManager.shared.showMessageNotification(
                from: displayName(for: payload.senderPublicKey),
                preview: text.text,
                conversationID: conversation.id
            )
        }
    }

    private func isConversationActivelyVisible(_ conversationID: UUID) -> Bool {
        UIApplication.shared.applicationState == .active && activeConversationID == conversationID
    }

    func shouldPresentForegroundNotification(userInfo: [AnyHashable: Any]) -> Bool {
        guard UIApplication.shared.applicationState == .active else {
            return true
        }

        guard let rawConversationID = userInfo["conversationID"] as? String,
              let conversationID = UUID(uuidString: rawConversationID)
        else {
            return true
        }

        return !isConversationActivelyVisible(conversationID)
    }

    private func shouldIncrementUnread(for conversationID: UUID) -> Bool {
        !isConversationActivelyVisible(conversationID)
    }

    private func shouldShowLocalNotification(
        for conversationID: UUID,
        source: InboundSource
    ) -> Bool {
        guard !isConversationActivelyVisible(conversationID) else {
            return false
        }
        return true
    }

    private func startNetworkPathMonitoring() {
        networkPathMonitor.pathUpdateHandler = { [weak self] path in
            guard let coordinator = self else { return }
            let isSatisfied = path.status == .satisfied
            Task { @MainActor [weak coordinator] in
                coordinator?.handleNetworkPathUpdate(isSatisfied: isSatisfied)
            }
        }
        networkPathMonitor.start(queue: networkPathMonitorQueue)
    }

    private func handleNetworkPathUpdate(isSatisfied: Bool) {
        let previous = hasUsableInternetPath
        hasUsableInternetPath = isSatisfied

        if !isSatisfied {
            bridgeDirectUpgradeTask?.cancel()
            bridgeDirectUpgradeTask = nil
            bridgeDirectUpgradeNotBefore = nil
            return
        }

        if !previous, transportState != .internetDirectConnected {
            bridgeDirectUpgradeNotBefore = nil
            scheduleDirectUpgradeFromBridge(delayNanoseconds: 0)
        }
    }

    private func scheduleDirectUpgradeFromBridge(delayNanoseconds: UInt64) {
        guard hasUsableInternetPath else { return }
        guard transportState == .internetBridgedConnected || transportState == .internetDisconnected else {
            return
        }
        guard let relayClient else { return }

        let now = Date()
        var scheduledDelayNanoseconds = delayNanoseconds
        if let notBefore = bridgeDirectUpgradeNotBefore,
           notBefore > now {
            let backoffNanoseconds = UInt64(
                (notBefore.timeIntervalSince(now) * 1_000_000_000).rounded(.up)
            )
            scheduledDelayNanoseconds = max(scheduledDelayNanoseconds, backoffNanoseconds)
        }

        bridgeDirectUpgradeTask?.cancel()
        bridgeDirectUpgradeTask = Task { [weak self] in
            if scheduledDelayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: scheduledDelayNanoseconds)
                } catch {
                    return
                }
            }

            guard let self else { return }
            guard self.hasUsableInternetPath else { return }
            guard self.transportState == .internetBridgedConnected || self.transportState == .internetDisconnected else {
                return
            }

            self.bridgeDirectUpgradeNotBefore = Date().addingTimeInterval(
                self.bridgeDirectUpgradeRetryBackoffSeconds
            )
            await relayClient.reconnect()
        }
    }

    private func updateBridgeBackgroundExecution() {
        if UIApplication.shared.applicationState != .active,
           transportState == .internetBridgedConnected {
            refreshBridgeBackgroundTaskLease()
        } else {
            endBridgeBackgroundTaskIfNeeded()
        }
    }

    private func refreshBridgeBackgroundTaskLease() {
        guard UIApplication.shared.applicationState != .active else {
            endBridgeBackgroundTaskIfNeeded()
            return
        }

        guard transportState == .internetBridgedConnected else {
            endBridgeBackgroundTaskIfNeeded()
            return
        }

        endBridgeBackgroundTaskIfNeeded()
        bridgeBackgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "PigeonBridgeRelay"
        ) { [weak self] in
            Task { @MainActor in
                self?.endBridgeBackgroundTaskIfNeeded()
            }
        }
    }

    private func endBridgeBackgroundTaskIfNeeded() {
        guard bridgeBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bridgeBackgroundTaskID)
        bridgeBackgroundTaskID = .invalid
    }

    private func handleIncomingGroupReaction(_ payload: WirePayloadV2) throws {
        guard let groupEncrypted = payload.groupEncrypted,
              let conversationID = payload.conversationID ?? payload.groupID
        else {
            throw AppCoordinatorError.invalidWirePayload
        }

        guard let keyData = try keyStore.loadGroupSymmetricKey(groupID: groupEncrypted.groupID, epoch: groupEncrypted.epoch) else {
            return
        }

        let inner = try decryptGroupInner(groupEncrypted, keyData: keyData)

        guard inner.payloadType == .reaction, let reaction = inner.reaction else {
            throw AppCoordinatorError.invalidWirePayload
        }

        if reaction.isRemoval {
            try store.removeReaction(messageID: reaction.targetMessageID, reactorPublicKey: payload.senderPublicKey)
        } else {
            let model = MessageReaction(
                messageID: reaction.targetMessageID,
                conversationID: conversationID,
                groupID: groupEncrypted.groupID,
                reactorPublicKey: payload.senderPublicKey,
                tapback: reaction.tapback,
                timestamp: payload.timestamp
            )
            try store.saveOrReplaceReaction(model)
        }
    }

    private func sendGroupPayload(_ payload: WirePayloadV2, groupID: UUID) async throws -> Bool {
        let myKey = identity.publicKey.rawRepresentation
        let memberKeys = try store.fetchGroupMembers(groupID: groupID, activeOnly: true)
            .map(\.publicKey)
            .filter { $0 != myKey }

        guard !memberKeys.isEmpty else {
            return true
        }

        let payloadData = try Self.wireEncoder.encode(payload)

        // Pre-encrypt envelopes for each member (sync, fast)
        var envelopes: [(key: Data, envelope: MessageEnvelope)] = []
        for memberKey in memberKeys {
            let envelope = try crypto.encrypt(
                plaintext: payloadData,
                senderPrivateKey: identity.privateKey,
                recipientPublicKeyData: memberKey,
                messageID: UUID(),
                timestamp: payload.timestamp
            )
            envelopes.append((memberKey, envelope))
        }

        // Capture nearby status before entering TaskGroup (MainActor context)
        let nearbyKeys = Set(nearbyPeers.map(\.publicKey))

        // Send in parallel — each relay send is independent
        let results = await withTaskGroup(of: Bool.self) { group in
            for (memberKey, envelope) in envelopes {
                let isNearby = nearbyKeys.contains(memberKey)
                group.addTask {
                    let usedRelay = await self.sendViaAvailableTransports(
                        envelope, recipientPublicKey: memberKey
                    )
                    return usedRelay || isNearby
                }
            }

            var delivered = false
            for await result in group {
                if result { delivered = true }
            }
            return delivered
        }

        return results
    }

    private func sendWirePayload(_ payload: WirePayloadV2, to recipientPublicKey: Data) async throws {
        let payloadData = try Self.wireEncoder.encode(payload)
        let envelope = try crypto.encrypt(
            plaintext: payloadData,
            senderPrivateKey: identity.privateKey,
            recipientPublicKeyData: recipientPublicKey,
            messageID: UUID(),
            timestamp: payload.timestamp
        )
        _ = await sendViaAvailableTransports(envelope, recipientPublicKey: recipientPublicKey)
    }

    private func sendViaAvailableTransports(
        _ envelope: MessageEnvelope,
        recipientPublicKey: Data
    ) async -> Bool {
        if isPeerNearby(publicKey: recipientPublicKey) {
            bleManager.sendMessage(envelope, to: recipientPublicKey)
            return false
        }

        let canUseBLEMesh = canAttemptBLEMeshDelivery(to: recipientPublicKey)
        let relayPathActive = transportState == .internetDirectConnected ||
            transportState == .internetBridgedConnected

        if canUseBLEMesh {
            bleManager.sendMessage(envelope, to: recipientPublicKey)
        }

        guard let relayClient else {
            if !canUseBLEMesh {
                bleManager.sendMessage(envelope, to: recipientPublicKey)
            }
            return false
        }

        if canUseBLEMesh {
            Task {
                try? await relayClient.sendEnvelope(envelope)
            }
            return relayPathActive
        }

        do {
            try await relayClient.sendEnvelope(envelope)
            return true
        } catch {
            bleManager.sendMessage(envelope, to: recipientPublicKey)
            return false
        }
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

        guard message.groupID == nil else {
            return
        }

        guard message.status == .sending || message.status == .sent else {
            return
        }

        if let recipientKey = message.recipientPublicKey,
           hasAnyRealtimeDeliveryPath(to: recipientKey) {
            return
        }

        try? store.updateMessageStatus(id: messageID, status: .queued)
        markMessagesChanged()
        await loadConversations()
    }

    private func decryptGroupInner(_ encrypted: GroupEncryptedPayload, keyData: Data) throws -> GroupInnerPayload {
        let plaintext = try encrypted.decrypt(using: groupCrypto, keyData: keyData)
        return try Self.wireDecoder.decode(GroupInnerPayload.self, from: plaintext)
    }

    private func makeReplyMetadata(from message: Message?) -> ReplyMetadataPayload? {
        guard let message else { return nil }
        return ReplyMetadataPayload(
            replyToMessageID: message.id,
            replyPreview: String(message.plaintext.prefix(80)),
            replySenderPublicKey: message.senderPublicKey
        )
    }

    private func markMessagesChanged() {
        messageChangeToken &+= 1
    }

    private func performOneTimeDataResetIfNeeded(userDefaults: UserDefaults = .standard) throws {
        let storedVersion = userDefaults.integer(forKey: Self.dataModelVersionDefaultsKey)
        guard storedVersion < Self.currentDataModelVersion else {
            return
        }

        try store.deleteAllData()
        try keyStore.deleteAllGroupSymmetricKeys()
        userDefaults.set(Self.currentDataModelVersion, forKey: Self.dataModelVersionDefaultsKey)
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

    private func refreshBridgeCandidates() {
        guard let relayClient else { return }

        let candidates = nearbyPeers
            .filter { $0.publicKey != identity.publicKey.rawRepresentation }
            .map { peer in
                BridgeCandidate(
                    publicKey: peer.publicKey,
                    pigeonID: peer.pigeonID,
                    rssi: peer.rssi,
                    relayReachable: peer.relayReachable,
                    bridgeEnabled: peer.bridgeEnabled,
                    capacityRemaining: peer.bridgeCapacityRemaining,
                    lastStatusAt: peer.lastSeen
                )
            }

        Task {
            await relayClient.updateBridgeCandidates(candidates)
        }
    }

    private func updateNearbyPeerBridgeStatus(_ payload: BridgeStatusPayload, from peerPublicKey: Data) {
        guard let index = nearbyPeers.firstIndex(where: { $0.publicKey == peerPublicKey }) else {
            return
        }

        nearbyPeers[index].bridgeProtocolVersion = payload.bridgeProtocolVersion
        nearbyPeers[index].bridgeEnabled = payload.bridgeEnabled
        nearbyPeers[index].relayReachable = payload.relayReachable
        nearbyPeers[index].bridgeCapacityRemaining = payload.capacityRemaining
        nearbyPeers[index].lastSeen = Date()
        refreshBridgeCandidates()
    }

    private func refreshBridgeHostAvailability() async {
        let relayReachable = transportState == .internetDirectConnected

        if let bridgeTunnelBroker {
            await bridgeTunnelBroker.setAcceptingConnections(internetBridgeEnabled && relayReachable)
        }

        let capacityRemaining = await bridgeTunnelBroker?.capacityRemaining
        bleManager.updateBridgeAvailability(
            enabled: internetBridgeEnabled,
            relayReachable: relayReachable,
            capacityRemaining: capacityRemaining
        )
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
            await refreshBridgeHostAvailability()
        }
    }

    private func restoreOutboundQueueIfNeeded() {
        guard !didRestoreOutboundQueue else { return }
        didRestoreOutboundQueue = true

        Task {
            await restorePendingOutboundMessages(retryQueuedOnly: false)
        }
    }

    private func scheduleQueuedOutboundRetry() {
        guard didRunInitialStartup else { return }

        outboundRetryTask?.cancel()
        outboundRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: self?.outboundRetryDebounceNanoseconds ?? 750_000_000
                )
            } catch {
                return
            }

            guard let self else { return }
            await self.restorePendingOutboundMessages(retryQueuedOnly: true)
        }
    }

    private func restorePendingOutboundMessages(retryQueuedOnly: Bool) async {
        guard !isRestoringOutboundMessages else { return }
        isRestoringOutboundMessages = true
        defer { isRestoringOutboundMessages = false }

        let pendingMessages = retryQueuedOnly
            ? ((try? store.fetchQueuedOutgoingMessages()) ?? [])
            : ((try? store.fetchPendingOutgoingMessages()) ?? [])
        guard !pendingMessages.isEmpty else { return }

        for message in pendingMessages {
            if let groupID = message.groupID {
                await retryPendingGroupMessage(message, groupID: groupID)
            } else {
                await retryPendingDirectMessage(message)
            }
        }

        markMessagesChanged()
        await loadConversations()
    }

    private func retryPendingDirectMessage(_ message: Message) async {
        guard let recipientKey = message.recipientPublicKey else { return }
        guard peerKeyChangeWarnings[recipientKey] == nil else { return }

        do {
            let payload = WirePayloadV2(
                eventType: .directText,
                logicalMessageID: message.id,
                conversationID: message.conversationID,
                senderPublicKey: identity.publicKey.rawRepresentation,
                timestamp: message.timestamp,
                directText: DirectTextPayload(text: message.plaintext, reply: message.replyMetadata)
            )
            let payloadData = try Self.wireEncoder.encode(payload)

            let envelope = try crypto.encrypt(
                plaintext: payloadData,
                senderPrivateKey: identity.privateKey,
                recipientPublicKeyData: recipientKey,
                messageID: message.id,
                timestamp: message.timestamp
            )

            let usedRelay = await sendViaAvailableTransports(envelope, recipientPublicKey: recipientKey)
            let updatedStatus = outboundStatusAfterSend(
                to: recipientKey,
                usedRelay: usedRelay
            )
            try store.updateMessageStatus(id: message.id, status: updatedStatus)

            if updatedStatus == .sent {
                scheduleDeliveryTimeout(for: message.id)
            }
        } catch {
            try? store.updateMessageStatus(id: message.id, status: .failed)
        }
    }

    private func retryPendingGroupMessage(_ message: Message, groupID: UUID) async {
        do {
            guard let group = try store.fetchGroup(id: groupID) else {
                throw AppCoordinatorError.groupNotFound
            }

            guard let groupKey = try keyStore.loadGroupSymmetricKey(groupID: groupID, epoch: group.activeEpoch) else {
                throw AppCoordinatorError.missingGroupKey
            }

            let innerPayload = GroupInnerPayload(
                text: GroupTextPayload(text: message.plaintext, reply: message.replyMetadata)
            )
            let innerData = try Self.wireEncoder.encode(innerPayload)
            let encrypted = try GroupEncryptedPayload.encrypting(
                innerData,
                groupID: groupID,
                epoch: group.activeEpoch,
                using: groupCrypto,
                keyData: groupKey
            )

            let payload = WirePayloadV2(
                eventType: .groupMessage,
                logicalMessageID: message.id,
                conversationID: message.conversationID,
                groupID: groupID,
                senderPublicKey: identity.publicKey.rawRepresentation,
                timestamp: message.timestamp,
                groupEncrypted: encrypted
            )

            let didSend = try await sendGroupPayload(payload, groupID: groupID)
            try store.updateMessageStatus(id: message.id, status: didSend ? .sent : .queued)
        } catch {
            try? store.updateMessageStatus(id: message.id, status: .failed)
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

    private static func loadInternetBridgeEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        if userDefaults.object(forKey: internetBridgeEnabledDefaultsKey) == nil,
           let legacyValue = userDefaults.object(forKey: legacyMeshRelayDefaultsKey) as? Bool {
            userDefaults.set(legacyValue, forKey: internetBridgeEnabledDefaultsKey)
        }

        if userDefaults.object(forKey: internetBridgeEnabledDefaultsKey) == nil {
            userDefaults.set(true, forKey: internetBridgeEnabledDefaultsKey)
        }

        return userDefaults.bool(forKey: internetBridgeEnabledDefaultsKey)
    }
}

// MARK: - BLEManagerDelegate

extension AppCoordinator: BLEManagerDelegate {
    nonisolated func bleManager(_ manager: BLEManager, didReceiveEnvelope envelope: MessageEnvelope) {
        Task { @MainActor in
            await processIncomingEnvelope(envelope, source: .ble)
        }
    }

    nonisolated func bleManager(_ manager: BLEManager, didReceiveBridgeFrame frame: BridgeControlFrame, from peerPublicKey: Data) {
        Task { @MainActor in
            refreshBridgeBackgroundTaskLease()
            await relayClient?.handleBridgeControlFrame(frame, from: peerPublicKey)
            let didChangeBridgeAvailability = await bridgeTunnelBroker?.handle(frame, from: peerPublicKey) ?? false

            if case .bridgeStatus(let payload) = frame.payload {
                updateNearbyPeerBridgeStatus(payload, from: peerPublicKey)
            }

            if didChangeBridgeAvailability {
                await refreshBridgeHostAvailability()
            }
        }
    }

    nonisolated func bleManager(_ manager: BLEManager, didDiscoverPeer peer: Peer) {
        Task { @MainActor in
            updateTrustState(for: peer)
            if !nearbyPeers.contains(where: { $0.publicKey == peer.publicKey }) {
                nearbyPeers.append(peer)
            }
            refreshBridgeCandidates()
            scheduleQueuedOutboundRetry()
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
            refreshBridgeCandidates()
            scheduleQueuedOutboundRetry()
        }
    }

    nonisolated func bleManager(_ manager: BLEManager, didLosePeer publicKey: Data) {
        Task { @MainActor in
            nearbyPeers.removeAll(where: { $0.publicKey == publicKey })
            refreshBridgeCandidates()
            await relayClient?.handleBridgePeerLoss(publicKey)
            await bridgeTunnelBroker?.handlePeerLoss(publicKey)
            await refreshBridgeHostAvailability()
        }
    }

    nonisolated func bleManager(_ manager: BLEManager, didDeliverMessage messageID: UUID) {
        Task { @MainActor in
            await markOutgoingMessageAsSent(messageID)
        }
    }

    nonisolated func bleManager(_ manager: BLEManager, didFailMessage messageID: UUID) {
        Task { @MainActor in
            cancelDeliveryTimeout(for: messageID)
            if let message = try? store.fetchMessage(id: messageID), message.groupID == nil {
                try? store.updateMessageStatus(id: messageID, status: .failed)
                markMessagesChanged()
            }
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
    nonisolated func relayClientDidUpdateState(_ state: TransportState, activeBridge: BridgeCandidate?) {
        Task { @MainActor in
            let previousState = transportState
            transportState = state
            self.activeBridge = activeBridge
            await refreshBridgeHostAvailability()
            updateBridgeBackgroundExecution()

            switch state {
            case .internetDirectConnected:
                bridgeDirectUpgradeTask?.cancel()
                bridgeDirectUpgradeTask = nil
                bridgeDirectUpgradeNotBefore = nil
            case .internetBridgedConnected:
                if hasUsableInternetPath {
                    scheduleDirectUpgradeFromBridge(
                        delayNanoseconds: bridgeDirectUpgradeDelayNanoseconds
                    )
                }
            case .internetDisconnected:
                if hasUsableInternetPath {
                    scheduleDirectUpgradeFromBridge(delayNanoseconds: 0)
                }
            case .bleOnly:
                bridgeDirectUpgradeTask?.cancel()
                bridgeDirectUpgradeTask = nil
                bridgeDirectUpgradeNotBefore = nil
            }

            let routeRecovered =
                (state == .internetDirectConnected || state == .internetBridgedConnected) &&
                state != previousState
            if routeRecovered {
                scheduleQueuedOutboundRetry()
            }
        }
    }

    nonisolated func relayClient(didReceiveEnvelope envelope: MessageEnvelope) {
        Task { @MainActor in
            refreshBridgeBackgroundTaskLease()
            await processIncomingEnvelope(envelope, source: .relay)
        }
    }

    nonisolated func relayClient(didReceiveDeliveryAck messageID: UUID) {
        Task { @MainActor in
            await router.acknowledgeDelivery(messageID)
            await markOutgoingMessageAsSent(messageID)
        }
    }
}
