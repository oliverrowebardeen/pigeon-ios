import Foundation

nonisolated enum TransportState: String, Sendable {
    case bleOnly
    case internetDisconnected
    case internetDirectConnected
    case internetBridgedConnected
}

nonisolated struct BridgeCandidate: Hashable, Sendable {
    let publicKey: Data
    let pigeonID: String
    let rssi: Int?
    let relayReachable: Bool
    let bridgeEnabled: Bool
    let capacityRemaining: Int?
    let lastStatusAt: Date
}

nonisolated protocol InternetRelayClientDelegate: AnyObject {
    func relayClientDidUpdateState(_ state: TransportState, activeBridge: BridgeCandidate?)
    func relayClient(didReceiveEnvelope envelope: MessageEnvelope)
    func relayClient(didReceiveDeliveryAck messageID: UUID)
}

actor InternetRelayClient {
    private let relayURL: URL
    private let session: RelaySessionActor
    private let reconnectDelayNanoseconds: UInt64 = 3_000_000_000
    private let bridgeSwitchHysteresisSeconds: TimeInterval = 10
    private let sendBridgeFrame: @Sendable (Data, BridgeControlFrame) async throws -> Void

    private weak var delegate: (any InternetRelayClientDelegate)?

    private var reconnectTask: Task<Void, Never>?
    private var bridgeCandidates: [BridgeCandidate] = []
    private var bridgeFallbackEnabled: Bool
    private var selectedBridge: BridgeCandidate?
    private var selectedBridgeAt: Date?
    private var activeBridgeTransport: BLEBridgeRelayTransport?
    private var pendingBridgeTransport: BLEBridgeRelayTransport?
    private var pendingBridgeTunnelID: UUID?
    private var pendingBridgePublicKey: Data?
    private var currentState: TransportState = .internetDisconnected
    private var activeBridge: BridgeCandidate?
    private var isRunning = false

    init(
        identity: PigeonIdentity,
        relayURL: URL,
        bridgeFallbackEnabled: Bool,
        sendBridgeFrame: @escaping @Sendable (Data, BridgeControlFrame) async throws -> Void
    ) {
        self.relayURL = relayURL
        self.session = RelaySessionActor(identity: identity)
        self.bridgeFallbackEnabled = bridgeFallbackEnabled
        self.sendBridgeFrame = sendBridgeFrame
    }

    func setDelegate(_ delegate: any InternetRelayClientDelegate) async {
        self.delegate = delegate
        await session.setDelegate(self)
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        await connectPreferredPath(forceDirectRetry: true)
    }

    func stop() async {
        isRunning = false
        reconnectTask?.cancel()
        reconnectTask = nil
        if let pendingBridgeTransport {
            let transport = pendingBridgeTransport
            self.pendingBridgeTransport = nil
            pendingBridgeTunnelID = nil
            pendingBridgePublicKey = nil
            await transport.stop()
        }
        if let activeBridgeTransport {
            let transport = activeBridgeTransport
            self.activeBridgeTransport = nil
            await transport.stop()
        }
        await session.disconnect(notify: false)
        activeBridge = nil
        selectedBridge = nil
        await updateState(.internetDisconnected, activeBridge: nil)
    }

    func reconnect() async {
        guard isRunning else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        await connectPreferredPath(forceDirectRetry: true)
    }

    func setBridgeFallbackEnabled(_ enabled: Bool) async {
        guard bridgeFallbackEnabled != enabled else { return }
        bridgeFallbackEnabled = enabled
        guard isRunning else { return }

        if !enabled, currentState == .internetBridgedConnected {
            await connectPreferredPath(forceDirectRetry: true)
            return
        }

        if enabled, currentState == .internetDisconnected {
            await connectPreferredPath(forceDirectRetry: false)
        }
    }

    func updateBridgeCandidates(_ candidates: [BridgeCandidate]) async {
        bridgeCandidates = candidates
        guard isRunning else { return }

        if let activeBridge,
           !candidates.contains(where: { $0.publicKey == activeBridge.publicKey }) {
            if let activeBridgeTransport {
                self.activeBridgeTransport = nil
                await activeBridgeTransport.stop()
            }
            await connectPreferredPath(forceDirectRetry: false)
            return
        }

        if currentState == .internetDisconnected {
            await connectPreferredPath(forceDirectRetry: false)
        }
    }

    func handleBridgeControlFrame(_ frame: BridgeControlFrame, from peerPublicKey: Data) async {
        if let pendingBridgeTransport {
            await pendingBridgeTransport.receive(frame, from: peerPublicKey)
            return
        }

        await activeBridgeTransport?.receive(frame, from: peerPublicKey)
    }

    func handleBridgePeerLoss(_ publicKey: Data) async {
        if pendingBridgePublicKey == publicKey, let pendingBridgeTransport {
            self.pendingBridgeTransport = nil
            pendingBridgeTunnelID = nil
            pendingBridgePublicKey = nil
            await pendingBridgeTransport.stop()
            await connectPreferredPath(forceDirectRetry: false)
            return
        }

        guard activeBridge?.publicKey == publicKey else { return }
        if let activeBridgeTransport {
            self.activeBridgeTransport = nil
            await activeBridgeTransport.stop()
        }
        await connectPreferredPath(forceDirectRetry: false)
    }

    func registerPushToken(_ token: Data) async {
        let tokenHex = token.map { String(format: "%02x", $0) }.joined()
        await session.updatePushTokenHex(tokenHex)
    }

    func sendEnvelope(_ envelope: MessageEnvelope) async throws {
        try await session.sendEnvelope(envelope)
    }

    func sendDeliveryACK(messageID: UUID) async throws {
        try await session.sendDeliveryACK(messageID: messageID)
    }

    private func connectPreferredPath(forceDirectRetry: Bool) async {
        guard isRunning else { return }

        reconnectTask?.cancel()
        reconnectTask = nil

        if let pendingBridgeTransport {
            let transport = pendingBridgeTransport
            self.pendingBridgeTransport = nil
            pendingBridgeTunnelID = nil
            pendingBridgePublicKey = nil
            await transport.stop()
        }
        if let activeBridgeTransport {
            self.activeBridgeTransport = nil
            await activeBridgeTransport.stop()
        }
        await session.disconnect(notify: false)
        await updateState(.internetDisconnected, activeBridge: nil)

        do {
            try await connectDirect()
            return
        } catch {
        }

        guard bridgeFallbackEnabled else {
            scheduleReconnectIfNeeded()
            return
        }

        do {
            try await connectBridge(forceSwitch: forceDirectRetry)
            return
        } catch {
        }

        scheduleReconnectIfNeeded()
    }

    private func connectDirect() async throws {
        let transport = DirectWebSocketRelayTransport(relayURL: relayURL)
        try await session.connect(
            using: transport,
            path: .direct,
            shouldRegisterPushToken: true
        )
    }

    private func connectBridge(forceSwitch: Bool) async throws {
        let candidate = try selectBridgeCandidate(forceSwitch: forceSwitch)
        let tunnelID = UUID()
        let transport = BLEBridgeRelayTransport(
            bridgePeer: candidate,
            tunnelID: tunnelID,
            sendBridgeFrame: sendBridgeFrame
        )
        pendingBridgeTransport = transport
        pendingBridgeTunnelID = tunnelID
        pendingBridgePublicKey = candidate.publicKey

        do {
            try await session.connect(
                using: transport,
                path: .bridged(candidate),
                shouldRegisterPushToken: false
            )
            guard pendingBridgeTunnelID == tunnelID else {
                await transport.stop()
                return
            }
            pendingBridgeTransport = nil
            pendingBridgeTunnelID = nil
            pendingBridgePublicKey = nil
            activeBridgeTransport = transport
            selectedBridge = candidate
            selectedBridgeAt = Date()
        } catch {
            if pendingBridgeTunnelID == tunnelID {
                pendingBridgeTransport = nil
                pendingBridgeTunnelID = nil
                pendingBridgePublicKey = nil
            }
            await transport.stop()
            throw error
        }
    }

    private func selectBridgeCandidate(forceSwitch: Bool) throws -> BridgeCandidate {
        let eligible = bridgeCandidates
            .filter { candidate in
                candidate.bridgeEnabled &&
                    candidate.relayReachable &&
                    (candidate.capacityRemaining ?? 1) > 0
            }
            .sorted { lhs, rhs in
                let lhsRSSI = lhs.rssi ?? Int.min
                let rhsRSSI = rhs.rssi ?? Int.min
                if lhsRSSI != rhsRSSI {
                    return lhsRSSI > rhsRSSI
                }
                return lhs.lastStatusAt > rhs.lastStatusAt
            }

        if let selectedBridge,
           !forceSwitch,
           let selectedBridgeAt,
           Date().timeIntervalSince(selectedBridgeAt) < bridgeSwitchHysteresisSeconds,
           let current = eligible.first(where: { $0.publicKey == selectedBridge.publicKey }) {
            return current
        }

        guard let best = eligible.first else {
            throw RelaySessionActorError.notConnected
        }

        return best
    }

    private func scheduleReconnectIfNeeded() {
        guard isRunning else { return }
        guard reconnectTask == nil else { return }

        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.reconnectDelayNanoseconds ?? 3_000_000_000)
            } catch {
                return
            }
            await self?.clearReconnectAndRetry()
        }
    }

    private func clearReconnectAndRetry() async {
        reconnectTask = nil
        guard isRunning else { return }
        await connectPreferredPath(forceDirectRetry: true)
    }

    private func updateState(_ state: TransportState, activeBridge: BridgeCandidate?) async {
        currentState = state
        self.activeBridge = activeBridge
        guard let delegate else { return }
        Task { @MainActor in
            delegate.relayClientDidUpdateState(state, activeBridge: activeBridge)
        }
    }

    private func notifyReceivedEnvelope(_ envelope: MessageEnvelope) {
        guard let delegate else { return }
        Task { @MainActor in
            delegate.relayClient(didReceiveEnvelope: envelope)
        }
    }

    private func notifyReceivedDeliveryAck(_ messageID: UUID) {
        guard let delegate else { return }
        Task { @MainActor in
            delegate.relayClient(didReceiveDeliveryAck: messageID)
        }
    }
}

extension InternetRelayClient: RelaySessionActorDelegate {
    func relaySession(_ session: RelaySessionActor, didConnect path: RelayTransportPath) async {
        switch path {
        case .direct:
            await updateState(.internetDirectConnected, activeBridge: nil)
        case .bridged(let bridge):
            await updateState(.internetBridgedConnected, activeBridge: bridge)
        }
    }

    func relaySession(_ session: RelaySessionActor, didDisconnect path: RelayTransportPath) async {
        if case .bridged = path {
            activeBridgeTransport = nil
        }
        await updateState(.internetDisconnected, activeBridge: nil)
        scheduleReconnectIfNeeded()
    }

    func relaySession(_ session: RelaySessionActor, didReceiveEnvelope envelope: MessageEnvelope) async {
        notifyReceivedEnvelope(envelope)
    }

    func relaySession(_ session: RelaySessionActor, didReceiveDeliveryAck messageID: UUID) async {
        notifyReceivedDeliveryAck(messageID)
    }
}
