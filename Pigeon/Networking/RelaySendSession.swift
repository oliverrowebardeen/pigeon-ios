import CryptoKit
import Foundation

nonisolated enum RelaySendSessionError: Error {
    case notConnected
    case invalidFrame
    case sendTimedOut
    case sendRejected(code: String)
}

/// Anonymous send-only session for sealed sender.
///
/// Opens a WebSocket to the relay and sends `msg_send` as its first frame,
/// which assigns the connection the Send role on the relay. No authentication
/// is performed, even when the transport itself is bridged over BLE.
actor RelaySendSession {
    private enum SendPath {
        case direct
        case bridged(BridgeCandidate)

        init(_ relayPath: RelayTransportPath) {
            switch relayPath {
            case .direct:
                self = .direct
            case .bridged(let bridge):
                self = .bridged(bridge)
            }
        }

        func matches(_ other: SendPath) -> Bool {
            switch (self, other) {
            case (.direct, .direct):
                return true
            case let (.bridged(lhs), .bridged(rhs)):
                return lhs.publicKey == rhs.publicKey
            default:
                return false
            }
        }
    }

    private let relayURL: URL
    private let encoder = JSONEncoder()
    private let messageAcceptanceTimeoutNanoseconds: UInt64 = 5_000_000_000
    private let sendBridgeFrame: @Sendable (Data, BridgeControlFrame) async throws -> Void

    private var transportPath: SendPath = .direct
    private var transport: (any RelaySessionTransport)?
    private var receiveTask: Task<Void, Never>?
    private var pendingAcceptanceContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var pendingAcceptanceTimeouts: [String: Task<Void, Never>] = [:]
    private var pendingBridgeTransport: BLEBridgeRelayTransport?
    private var pendingBridgeTunnelID: UUID?
    private var pendingBridgePublicKey: Data?
    private var activeBridgeTransport: BLEBridgeRelayTransport?
    private var isConnected = false
    private var isStopping = false

    init(
        relayURL: URL,
        sendBridgeFrame: @escaping @Sendable (Data, BridgeControlFrame) async throws -> Void
    ) {
        self.relayURL = relayURL
        self.sendBridgeFrame = sendBridgeFrame
    }

    func updateTransportPath(_ path: RelayTransportPath) async {
        let nextPath = SendPath(path)
        guard !transportPath.matches(nextPath) else { return }
        transportPath = nextPath
        await disconnectCurrentTransport(markStopping: false)
    }

    func handleBridgeControlFrame(_ frame: BridgeControlFrame, from peerPublicKey: Data) async {
        if let pendingBridgeTransport {
            await pendingBridgeTransport.receive(frame, from: peerPublicKey)
            return
        }

        await activeBridgeTransport?.receive(frame, from: peerPublicKey)
    }

    func handleBridgePeerLoss(_ publicKey: Data) async {
        if pendingBridgePublicKey == publicKey, pendingBridgeTransport != nil {
            await disconnectCurrentTransport(markStopping: false)
            return
        }

        guard case .bridged(let bridge) = transportPath, bridge.publicKey == publicKey else {
            return
        }

        await disconnectCurrentTransport(markStopping: false)
    }

    func sendEnvelope(_ envelope: MessageEnvelope) async throws {
        if !isConnected {
            try await connect()
        }

        let envelopeData = try MessageProtocol.encodeEnvelope(envelope)
        let messageID = envelope.id.uuidString
        let payload = RelaySendPayload(
            messageID: messageID,
            recipientHashHex: Self.publicKeyHashHex(envelope.recipientPublicKey),
            envelopeB64: envelopeData.base64EncodedString()
        )

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                beginWaitingForAcceptance(messageID: messageID, continuation: continuation)

                Task { [messageID, payload] in
                    do {
                        try await self.sendFrame(type: "msg_send", reqID: messageID, payload: payload)
                    } catch {
                        self.failPendingAcceptance(messageID: messageID, error: error)
                    }
                }
            }
        } catch {
            await handleOutboundFailure(error)
            throw error
        }
    }

    func disconnect() async {
        await disconnectCurrentTransport(markStopping: true)
    }

    // MARK: - Connection

    private func connect() async throws {
        await disconnectCurrentTransport(markStopping: true)
        isStopping = false

        switch transportPath {
        case .direct:
            let transport = DirectWebSocketRelayTransport(relayURL: relayURL)
            self.transport = transport
            try await transport.start()
            isConnected = true
            let expectedTransportID = Self.transportIdentifier(transport)
            receiveTask = Task { [weak self] in
                await self?.runReceiveLoop(expectedTransportID: expectedTransportID)
            }

        case .bridged(let bridge):
            let tunnelID = UUID()
            let transport = BLEBridgeRelayTransport(
                bridgePeer: bridge,
                tunnelID: tunnelID,
                sendBridgeFrame: sendBridgeFrame,
                onStop: { [weak self] stoppedTunnelID in
                    await self?.handleBridgeTransportStop(stoppedTunnelID)
                }
            )

            pendingBridgeTransport = transport
            pendingBridgeTunnelID = tunnelID
            pendingBridgePublicKey = bridge.publicKey
            self.transport = transport

            do {
                try await transport.start()
            } catch {
                if pendingBridgeTunnelID == tunnelID {
                    pendingBridgeTransport = nil
                    pendingBridgeTunnelID = nil
                    pendingBridgePublicKey = nil
                }
                self.transport = nil
                await transport.stop()
                throw error
            }

            guard pendingBridgeTunnelID == tunnelID else {
                self.transport = nil
                await transport.stop()
                throw RelaySendSessionError.notConnected
            }

            pendingBridgeTransport = nil
            pendingBridgeTunnelID = nil
            pendingBridgePublicKey = nil
            activeBridgeTransport = transport
            isConnected = true
            let expectedTransportID = Self.transportIdentifier(transport)
            receiveTask = Task { [weak self] in
                await self?.runReceiveLoop(expectedTransportID: expectedTransportID)
            }
        }
    }

    private func runReceiveLoop(expectedTransportID: ObjectIdentifier) async {
        guard let transport, Self.transportIdentifier(transport) == expectedTransportID else {
            return
        }

        for await text in transport.inboundFrames {
            handleIncomingText(text)
        }

        guard !isStopping else { return }
        await handleTransportTermination(expectedTransportID: expectedTransportID)
    }

    private func handleTransportTermination(expectedTransportID: ObjectIdentifier) async {
        guard let transport, Self.transportIdentifier(transport) == expectedTransportID else {
            return
        }

        await disconnectCurrentTransport(
            markStopping: false,
            skipReceiveTaskCancellation: true
        )
    }

    private func handleBridgeTransportStop(_ tunnelID: UUID) async {
        if pendingBridgeTunnelID == tunnelID {
            pendingBridgeTransport = nil
            pendingBridgeTunnelID = nil
            pendingBridgePublicKey = nil
        }

        if activeBridgeTransport?.tunnelID == tunnelID {
            activeBridgeTransport = nil
        }
    }

    private func disconnectCurrentTransport(
        markStopping: Bool,
        skipReceiveTaskCancellation: Bool = false
    ) async {
        if markStopping {
            isStopping = true
        }

        failAllPending(with: RelaySendSessionError.notConnected)
        if !skipReceiveTaskCancellation {
            receiveTask?.cancel()
        }
        receiveTask = nil
        isConnected = false
        pendingBridgeTransport = nil
        pendingBridgeTunnelID = nil
        pendingBridgePublicKey = nil
        activeBridgeTransport = nil

        if let transport {
            self.transport = nil
            await transport.stop()
        } else {
            self.transport = nil
        }
    }

    private func handleIncomingText(_ text: String) {
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let frameType = root["type"] as? String
        else { return }

        let reqID = root["req_id"] as? String

        switch frameType {
        case "msg_accepted":
            guard let payload = root["payload"] as? [String: Any],
                  let messageID = reqID ?? payload["message_id"] as? String
            else {
                return
            }
            completePendingAcceptance(messageID: messageID)

        case "error":
            guard let payload = root["payload"] as? [String: Any],
                  let code = payload["code"] as? String,
                  let reqID
            else {
                return
            }
            failPendingAcceptance(
                messageID: reqID,
                error: RelaySendSessionError.sendRejected(code: code)
            )

        case "ping":
            Task {
                try? await sendFrame(type: "pong", payload: RelaySendEmptyPayload())
            }

        default:
            break
        }
    }

    // MARK: - Pending acceptance tracking

    private func beginWaitingForAcceptance(
        messageID: String,
        continuation: CheckedContinuation<Void, Error>
    ) {
        pendingAcceptanceContinuations[messageID] = continuation
        pendingAcceptanceTimeouts[messageID]?.cancel()
        pendingAcceptanceTimeouts[messageID] = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: self?.messageAcceptanceTimeoutNanoseconds ?? 5_000_000_000
                )
            } catch {
                return
            }

            await self?.failPendingAcceptance(
                messageID: messageID,
                error: RelaySendSessionError.sendTimedOut
            )
        }
    }

    private func completePendingAcceptance(messageID: String) {
        pendingAcceptanceTimeouts[messageID]?.cancel()
        pendingAcceptanceTimeouts.removeValue(forKey: messageID)
        let continuation = pendingAcceptanceContinuations.removeValue(forKey: messageID)
        continuation?.resume()
    }

    private func failPendingAcceptance(messageID: String, error: Error) {
        pendingAcceptanceTimeouts[messageID]?.cancel()
        pendingAcceptanceTimeouts.removeValue(forKey: messageID)
        let continuation = pendingAcceptanceContinuations.removeValue(forKey: messageID)
        continuation?.resume(throwing: error)
    }

    private func failAllPending(with error: Error) {
        for task in pendingAcceptanceTimeouts.values {
            task.cancel()
        }
        pendingAcceptanceTimeouts.removeAll()

        let continuations = pendingAcceptanceContinuations
        pendingAcceptanceContinuations.removeAll()
        for continuation in continuations.values {
            continuation.resume(throwing: error)
        }
    }

    private func handleOutboundFailure(_ error: Error) async {
        if case .sendRejected = error as? RelaySendSessionError {
            return
        }

        await disconnectCurrentTransport(markStopping: false)
    }

    // MARK: - Frame encoding

    private func sendFrame<Payload: Encodable>(
        type: String,
        reqID: String? = nil,
        payload: Payload
    ) async throws {
        guard let transport else {
            throw RelaySendSessionError.notConnected
        }

        let frame = RelaySendOutgoingFrame(type: type, reqID: reqID, payload: payload)
        let data = try encoder.encode(frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RelaySendSessionError.invalidFrame
        }

        try await transport.send(text: text)
    }

    nonisolated private static func publicKeyHashHex(_ publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func transportIdentifier(
        _ transport: any RelaySessionTransport
    ) -> ObjectIdentifier {
        ObjectIdentifier(transport as AnyObject)
    }
}

// MARK: - Private Codable types

nonisolated private struct RelaySendOutgoingFrame<Payload: Encodable>: Encodable {
    let type: String
    let reqID: String?
    let payload: Payload

    enum CodingKeys: String, CodingKey {
        case type
        case reqID = "req_id"
        case payload
    }
}

nonisolated private struct RelaySendPayload: Codable {
    let messageID: String
    let recipientHashHex: String
    let envelopeB64: String

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case recipientHashHex = "recipient_hash_hex"
        case envelopeB64 = "envelope_b64"
    }
}

nonisolated private struct RelaySendEmptyPayload: Codable {}
