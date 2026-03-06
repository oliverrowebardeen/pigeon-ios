import Foundation

actor BridgeTunnelBroker {
    private struct TunnelKey: Hashable, Sendable {
        let peerPublicKey: Data
        let tunnelID: UUID
    }

    private struct TunnelHandle {
        let transport: DirectWebSocketRelayTransport
        let relayTask: Task<Void, Never>
    }

    private let relayURL: URL
    private let maxActiveTunnels: Int
    private let sendBridgeFrame: @Sendable (Data, BridgeControlFrame) async throws -> Void

    private var acceptingConnections = false
    private var activeTunnels: [TunnelKey: TunnelHandle] = [:]

    init(
        relayURL: URL,
        maxActiveTunnels: Int = 6,
        sendBridgeFrame: @escaping @Sendable (Data, BridgeControlFrame) async throws -> Void
    ) {
        self.relayURL = relayURL
        self.maxActiveTunnels = maxActiveTunnels
        self.sendBridgeFrame = sendBridgeFrame
    }

    var capacityRemaining: Int {
        max(0, maxActiveTunnels - activeTunnels.count)
    }

    func setAcceptingConnections(_ accepting: Bool) async {
        acceptingConnections = accepting
        if !accepting {
            await closeAll(reasonCode: "bridge_unavailable", reason: "bridge is unavailable")
        }
    }

    func handle(_ frame: BridgeControlFrame, from peerPublicKey: Data) async -> Bool {
        switch frame.payload {
        case .tunnelOpen(let payload):
            return await openTunnel(payload.tunnelID, for: peerPublicKey)

        case .tunnelData(let payload):
            return await forwardTunnelData(payload, from: peerPublicKey)

        case .tunnelClose(let payload):
            return await closeTunnel(
                tunnelID: payload.tunnelID,
                for: peerPublicKey,
                reasonCode: payload.code,
                reason: payload.reason
            )

        case .ping:
            try? await sendBridgeFrame(peerPublicKey, BridgeProtocol.pong)
            return false

        case .bridgeStatus, .tunnelOpened, .tunnelError, .pong:
            return false
        }
    }

    func handlePeerLoss(_ publicKey: Data) async {
        for key in activeTunnels.keys where key.peerPublicKey == publicKey {
            _ = await closeTunnel(
                tunnelID: key.tunnelID,
                for: publicKey,
                reasonCode: "peer_lost",
                reason: "peer disconnected"
            )
        }
    }

    private func openTunnel(_ tunnelID: UUID, for peerPublicKey: Data) async -> Bool {
        let key = TunnelKey(peerPublicKey: peerPublicKey, tunnelID: tunnelID)

        guard acceptingConnections else {
            try? await sendBridgeFrame(
                peerPublicKey,
                BridgeProtocol.tunnelError(tunnelID, code: "bridge_unavailable", message: "bridge unavailable")
            )
            return false
        }

        guard activeTunnels[key] == nil else { return false }

        guard activeTunnels.count < maxActiveTunnels else {
            try? await sendBridgeFrame(
                peerPublicKey,
                BridgeProtocol.tunnelError(tunnelID, code: "capacity_reached", message: "bridge capacity reached")
            )
            return false
        }

        let transport = DirectWebSocketRelayTransport(relayURL: relayURL)
        do {
            try await transport.start()
            let relayTask = Task { [weak self] in
                for await text in transport.inboundFrames {
                    try? await self?.sendBridgeFrame(peerPublicKey, BridgeProtocol.tunnelData(tunnelID, text: text))
                }

                _ = await self?.closeTunnel(
                    tunnelID: tunnelID,
                    for: peerPublicKey,
                    reasonCode: "relay_closed",
                    reason: "relay transport closed"
                )
            }

            activeTunnels[key] = TunnelHandle(transport: transport, relayTask: relayTask)
            try? await sendBridgeFrame(peerPublicKey, BridgeProtocol.tunnelOpened(tunnelID))
            return true
        } catch {
            try? await sendBridgeFrame(
                peerPublicKey,
                BridgeProtocol.tunnelError(tunnelID, code: "relay_connect_failed", message: "failed to open relay tunnel")
            )
            return false
        }
    }

    private func forwardTunnelData(_ payload: TunnelDataPayload, from peerPublicKey: Data) async -> Bool {
        let key = TunnelKey(peerPublicKey: peerPublicKey, tunnelID: payload.tunnelID)
        guard let handle = activeTunnels[key] else {
            try? await sendBridgeFrame(
                peerPublicKey,
                BridgeProtocol.tunnelError(payload.tunnelID, code: "unknown_tunnel", message: "unknown tunnel")
            )
            return false
        }

        guard let data = Data(base64Encoded: payload.payloadB64),
              let text = String(data: data, encoding: .utf8)
        else {
            try? await sendBridgeFrame(
                peerPublicKey,
                BridgeProtocol.tunnelError(payload.tunnelID, code: "bad_payload", message: "invalid tunnel data")
            )
            return false
        }

        do {
            try await handle.transport.send(text: text)
            return false
        } catch {
            return await closeTunnel(
                tunnelID: payload.tunnelID,
                for: peerPublicKey,
                reasonCode: "relay_write_failed",
                reason: "failed to write to relay"
            )
        }
    }

    private func closeAll(reasonCode: String, reason: String) async {
        let keys = Array(activeTunnels.keys)
        for key in keys {
            _ = await closeTunnel(
                tunnelID: key.tunnelID,
                for: key.peerPublicKey,
                reasonCode: reasonCode,
                reason: reason
            )
        }
    }

    private func closeTunnel(
        tunnelID: UUID,
        for peerPublicKey: Data,
        reasonCode: String,
        reason: String?
    ) async -> Bool {
        let key = TunnelKey(peerPublicKey: peerPublicKey, tunnelID: tunnelID)
        guard let handle = activeTunnels.removeValue(forKey: key) else { return false }
        handle.relayTask.cancel()
        await handle.transport.stop()
        try? await sendBridgeFrame(peerPublicKey, BridgeProtocol.tunnelClose(tunnelID, code: reasonCode, reason: reason))
        return true
    }
}
