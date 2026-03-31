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
/// is performed — the relay cannot identify the sender.
///
/// Connects lazily on first send and stays connected for the app session.
actor RelaySendSession {
    private let relayURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let messageAcceptanceTimeoutNanoseconds: UInt64 = 5_000_000_000

    private var transport: DirectWebSocketRelayTransport?
    private var receiveTask: Task<Void, Never>?
    private var pendingAcceptanceContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var pendingAcceptanceTimeouts: [String: Task<Void, Never>] = [:]
    private var isConnected = false
    private var isStopping = false

    init(relayURL: URL) {
        self.relayURL = relayURL
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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            beginWaitingForAcceptance(messageID: messageID, continuation: continuation)

            Task { [weak self] in
                guard let self else {
                    continuation.resume(throwing: RelaySendSessionError.notConnected)
                    return
                }
                do {
                    try await self.sendFrame(type: "msg_send", reqID: messageID, payload: payload)
                } catch {
                    await self.failPendingAcceptance(messageID: messageID, error: error)
                }
            }
        }
    }

    func disconnect() async {
        isStopping = true
        failAllPending(with: RelaySendSessionError.notConnected)
        receiveTask?.cancel()
        receiveTask = nil
        isConnected = false
        if let transport {
            await transport.stop()
            self.transport = nil
        }
    }

    // MARK: - Connection

    private func connect() async throws {
        let transport = DirectWebSocketRelayTransport(relayURL: relayURL)
        self.transport = transport
        try await transport.start()
        isConnected = true
        isStopping = false
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    private func runReceiveLoop() async {
        guard let transport else { return }
        for await text in transport.inboundFrames {
            handleIncomingText(text)
        }
        if !isStopping {
            isConnected = false
        }
    }

    private func handleIncomingText(_ text: String) {
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let frameType = root["type"] as? String
        else { return }

        let reqID = root["req_id"] as? String

        switch frameType {
        case "msg_accepted":
            if let payload = root["payload"] as? [String: Any],
               let messageID = reqID ?? payload["message_id"] as? String {
                completePendingAcceptance(messageID: messageID)
            }
        case "error":
            if let payload = root["payload"] as? [String: Any],
               let code = payload["code"] as? String,
               let reqID {
                failPendingAcceptance(
                    messageID: reqID,
                    error: RelaySendSessionError.sendRejected(code: code)
                )
            }
        case "ping":
            Task {
                try? await sendFrame(
                    type: "pong",
                    payload: RelaySendEmptyPayload()
                )
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
            } catch { return }
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
        for task in pendingAcceptanceTimeouts.values { task.cancel() }
        pendingAcceptanceTimeouts.removeAll()
        let continuations = pendingAcceptanceContinuations
        pendingAcceptanceContinuations.removeAll()
        for continuation in continuations.values {
            continuation.resume(throwing: error)
        }
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
}

// MARK: - Private Codable types

private struct RelaySendOutgoingFrame<Payload: Encodable>: Encodable {
    let type: String
    let reqID: String?
    let payload: Payload

    enum CodingKeys: String, CodingKey {
        case type
        case reqID = "req_id"
        case payload
    }
}

private struct RelaySendPayload: Codable {
    let messageID: String
    let recipientHashHex: String
    let envelopeB64: String

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case recipientHashHex = "recipient_hash_hex"
        case envelopeB64 = "envelope_b64"
    }
}

private struct RelaySendEmptyPayload: Codable {}
