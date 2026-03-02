import CryptoKit
import Foundation

nonisolated enum TransportState: String, Sendable {
    case bleOnly
    case internetDisconnected
    case internetConnected
}

nonisolated protocol InternetRelayClientDelegate: AnyObject {
    func relayClientDidConnect()
    func relayClientDidDisconnect()
    func relayClient(didReceiveEnvelope envelope: MessageEnvelope)
    func relayClient(didReceiveDeliveryAck messageID: UUID)
}

nonisolated enum InternetRelayClientError: Error {
    case notConnected
    case invalidURL
    case invalidFrame
    case invalidPayload
    case authFailed
}

actor InternetRelayClient {
    private let identity: PigeonIdentity
    private let relayURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let reconnectDelayNanoseconds: UInt64 = 3_000_000_000

    private weak var delegate: (any InternetRelayClientDelegate)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var isRunning = false
    private var isAuthenticated = false
    private var pendingPushTokenHex: String?

    init(identity: PigeonIdentity, relayURL: URL) {
        self.identity = identity
        self.relayURL = relayURL
    }

    func setDelegate(_ delegate: any InternetRelayClientDelegate) {
        self.delegate = delegate
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        await connect()
    }

    func stop() {
        isRunning = false
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        isAuthenticated = false

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    func reconnect() async {
        guard isRunning else { return }
        await teardownConnection(notifyDisconnect: false)
        await connect()
    }

    func sendEnvelope(_ envelope: MessageEnvelope) async throws {
        guard isAuthenticated else {
            throw InternetRelayClientError.notConnected
        }

        let envelopeData = try MessageProtocol.encodeEnvelope(envelope)
        let payload = RelayMessageSendPayload(
            messageID: envelope.id.uuidString,
            recipientHashHex: Self.publicKeyHashHex(envelope.recipientPublicKey),
            envelopeB64: envelopeData.base64EncodedString()
        )

        try await sendFrame(type: "msg_send", payload: payload)
    }

    func sendDeliveryACK(messageID: UUID) async throws {
        guard isAuthenticated else {
            throw InternetRelayClientError.notConnected
        }

        let payload = RelayMessageAckPayload(messageID: messageID.uuidString)
        try await sendFrame(type: "msg_ack", payload: payload)
    }

    func registerPushToken(_ token: Data) async {
        let tokenHex = Self.hexString(from: token)
        pendingPushTokenHex = tokenHex

        guard isAuthenticated else {
            return
        }

        await sendPendingPushRegistrationIfPossible()
    }

    private func connect() async {
        guard isRunning else { return }
        guard webSocketTask == nil else { return }

        let task = URLSession.shared.webSocketTask(with: relayURL)
        webSocketTask = task
        task.resume()

        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }

        do {
            let hello = RelayAuthHelloPayload(
                clientPubkeyB64: identity.publicKey.rawRepresentation.base64EncodedString()
            )
            try await sendFrame(type: "auth_hello", payload: hello)
        } catch {
            await handleDisconnect(error: error)
        }
    }

    private func runReceiveLoop() async {
        while isRunning, let task = webSocketTask {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    try await handleIncomingText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        try await handleIncomingText(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                await handleDisconnect(error: error)
                return
            }
        }
    }

    private func handleIncomingText(_ text: String) async throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let frameType = root["type"] as? String
        else {
            throw InternetRelayClientError.invalidFrame
        }

        let reqID = root["req_id"] as? String
        let payloadAny = root["payload"] ?? [:]

        switch frameType {
        case "auth_challenge":
            let payload: RelayAuthChallengePayload = try decodePayload(payloadAny)
            let proof = try makeProof(challenge: payload)
            let provePayload = RelayAuthProvePayload(challengeID: payload.challengeID, proofB64: proof)
            try await sendFrame(type: "auth_prove", reqID: reqID, payload: provePayload)

        case "auth_ok":
            _ = try decodePayload(payloadAny) as RelayAuthOKPayload
            isAuthenticated = true
            notifyConnected()
            await sendPendingPushRegistrationIfPossible()

        case "msg_deliver":
            let payload: RelayMessageDeliverPayload = try decodePayload(payloadAny)
            guard let envelopeData = Data(base64Encoded: payload.envelopeB64) else {
                throw InternetRelayClientError.invalidPayload
            }
            let envelope = try MessageProtocol.decodeEnvelope(envelopeData)
            notifyReceivedEnvelope(envelope)

        case "msg_acked":
            let payload: RelayMessageAckedPayload = try decodePayload(payloadAny)
            guard let messageID = UUID(uuidString: payload.messageID) else {
                throw InternetRelayClientError.invalidPayload
            }
            notifyReceivedDeliveryAck(messageID)

        case "error":
            let payload: RelayErrorPayload = try decodePayload(payloadAny)
            if payload.code == "auth_failed" {
                throw InternetRelayClientError.authFailed
            }

        case "ping":
            try await sendFrame(type: "pong", reqID: reqID, payload: RelayEmptyPayload())

        case "pong", "msg_accepted":
            break

        default:
            break
        }
    }

    private func handleDisconnect(error _: Error?) async {
        await teardownConnection(notifyDisconnect: true)
        scheduleReconnectIfNeeded()
    }

    private func teardownConnection(notifyDisconnect: Bool) async {
        let wasConnected = isAuthenticated

        isAuthenticated = false
        receiveTask?.cancel()
        receiveTask = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        if notifyDisconnect, wasConnected || isRunning {
            notifyDisconnected()
        }
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
            await self?.clearReconnectAndReconnect()
        }
    }

    private func clearReconnectAndReconnect() async {
        reconnectTask = nil
        guard isRunning else { return }
        await connect()
    }

    private func sendPendingPushRegistrationIfPossible() async {
        guard isAuthenticated else { return }
        guard let tokenHex = pendingPushTokenHex else { return }

        #if DEBUG
        let apnsEnv = "sandbox"
        #else
        let apnsEnv = "production"
        #endif

        let payload = RelayPushRegisterPayload(
            deviceTokenHex: tokenHex,
            apnsEnv: apnsEnv,
            topic: Bundle.main.bundleIdentifier
        )

        do {
            try await sendFrame(type: "push_register", payload: payload)
        } catch {
            // Keep token cached for next reconnect.
        }
    }

    private func sendFrame<Payload: Encodable>(
        type: String,
        reqID: String? = nil,
        payload: Payload
    ) async throws {
        guard let task = webSocketTask else {
            throw InternetRelayClientError.notConnected
        }

        let frame = RelayOutgoingFrame(type: type, reqID: reqID, payload: payload)
        let data = try encoder.encode(frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw InternetRelayClientError.invalidFrame
        }

        try await task.send(.string(text))
    }

    private func decodePayload<T: Decodable>(_ payload: Any) throws -> T {
        let object: Any = payload is NSNull ? [:] : payload
        let data = try JSONSerialization.data(withJSONObject: object)
        return try decoder.decode(T.self, from: data)
    }

    private func makeProof(challenge: RelayAuthChallengePayload) throws -> String {
        guard let serverPublicKeyData = Data(base64Encoded: challenge.serverPubkeyB64),
              let nonceData = Data(base64Encoded: challenge.nonceB64)
        else {
            throw InternetRelayClientError.invalidPayload
        }

        let serverPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPublicKeyData)
        let sharedSecret = try identity.privateKey.sharedSecretFromKeyAgreement(with: serverPublicKey)

        var info = Data(challenge.challengeID.utf8)
        info.append(nonceData)
        info.append(identity.publicKey.rawRepresentation)

        let salt = Data("pigeon-relay-auth-v1".utf8)
        let authKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        )

        let message = Self.proofMessage(
            challengeID: challenge.challengeID,
            issuedAtMS: challenge.issuedAtMS
        )
        let signature = HMAC<SHA256>.authenticationCode(for: message, using: authKey)
        return Data(signature).base64EncodedString()
    }

    private func notifyConnected() {
        guard let delegate else { return }
        Task { @MainActor in
            delegate.relayClientDidConnect()
        }
    }

    private func notifyDisconnected() {
        guard let delegate else { return }
        Task { @MainActor in
            delegate.relayClientDidDisconnect()
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

    private static func proofMessage(challengeID: String, issuedAtMS: Int64) -> Data {
        var output = Data(challengeID.utf8)
        var timestamp = issuedAtMS.bigEndian
        withUnsafeBytes(of: &timestamp) { bytes in
            output.append(contentsOf: bytes)
        }
        return output
    }

    private static func publicKeyHashHex(_ publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private struct RelayOutgoingFrame<Payload: Encodable>: Encodable {
    let type: String
    let reqID: String?
    let payload: Payload

    enum CodingKeys: String, CodingKey {
        case type
        case reqID = "req_id"
        case payload
    }
}

private struct RelayAuthHelloPayload: Codable {
    let clientPubkeyB64: String

    enum CodingKeys: String, CodingKey {
        case clientPubkeyB64 = "client_pubkey_b64"
    }
}

private struct RelayAuthChallengePayload: Codable {
    let challengeID: String
    let serverPubkeyB64: String
    let nonceB64: String
    let issuedAtMS: Int64
    let expiresAtMS: Int64

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case serverPubkeyB64 = "server_pubkey_b64"
        case nonceB64 = "nonce_b64"
        case issuedAtMS = "issued_at_ms"
        case expiresAtMS = "expires_at_ms"
    }
}

private struct RelayAuthProvePayload: Codable {
    let challengeID: String
    let proofB64: String

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case proofB64 = "proof_b64"
    }
}

private struct RelayAuthOKPayload: Codable {
    let identityHashHex: String
    let sessionExpiresAtMS: Int64

    enum CodingKeys: String, CodingKey {
        case identityHashHex = "identity_hash_hex"
        case sessionExpiresAtMS = "session_expires_at_ms"
    }
}

private struct RelayMessageSendPayload: Codable {
    let messageID: String
    let recipientHashHex: String
    let envelopeB64: String

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case recipientHashHex = "recipient_hash_hex"
        case envelopeB64 = "envelope_b64"
    }
}

private struct RelayMessageDeliverPayload: Codable {
    let messageID: String
    let senderHashHex: String
    let envelopeB64: String
    let queuedAtMS: Int64

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case senderHashHex = "sender_hash_hex"
        case envelopeB64 = "envelope_b64"
        case queuedAtMS = "queued_at_ms"
    }
}

private struct RelayMessageAckPayload: Codable {
    let messageID: String

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
    }
}

private struct RelayMessageAckedPayload: Codable {
    let messageID: String
    let ackedAtMS: Int64

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case ackedAtMS = "acked_at_ms"
    }
}

private struct RelayPushRegisterPayload: Codable {
    let deviceTokenHex: String
    let apnsEnv: String
    let topic: String?

    enum CodingKeys: String, CodingKey {
        case deviceTokenHex = "device_token_hex"
        case apnsEnv = "apns_env"
        case topic
    }
}

private struct RelayErrorPayload: Codable {
    let code: String
    let message: String
}

private struct RelayEmptyPayload: Codable {}
