import CryptoKit
import Foundation

nonisolated enum RelaySessionActorError: Error {
    case notConnected
    case invalidFrame
    case invalidPayload
    case authFailed
    case authTimedOut
    case sendTimedOut
    case sendRejected(code: String)
}

nonisolated protocol RelaySessionActorDelegate: AnyObject {
    func relaySession(_ session: RelaySessionActor, didConnect path: RelayTransportPath) async
    func relaySession(_ session: RelaySessionActor, didDisconnect path: RelayTransportPath) async
    func relaySession(_ session: RelaySessionActor, didReceiveEnvelope envelope: MessageEnvelope) async
    func relaySession(_ session: RelaySessionActor, didReceiveDeliveryAck messageID: UUID) async
}

actor RelaySessionActor {
    private let identity: PigeonIdentity
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let authTimeoutNanoseconds: UInt64 = 5_000_000_000
    private let messageAcceptanceTimeoutNanoseconds: UInt64 = 5_000_000_000

    private weak var delegate: (any RelaySessionActorDelegate)?
    private var transport: (any RelaySessionTransport)?
    private var receiveTask: Task<Void, Never>?
    private var authContinuation: CheckedContinuation<Void, Error>?
    private var pendingMessageAcceptanceContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var pendingMessageAcceptanceTimeouts: [String: Task<Void, Never>] = [:]
    private var currentPath: RelayTransportPath?
    private var shouldRegisterPushToken = false
    private var pendingPushTokenHex: String?
    private var isAuthenticated = false
    private var isStopping = false

    init(identity: PigeonIdentity) {
        self.identity = identity
    }

    func setDelegate(_ delegate: any RelaySessionActorDelegate) {
        self.delegate = delegate
    }

    func updatePushTokenHex(_ tokenHex: String?) async {
        pendingPushTokenHex = tokenHex
        if shouldRegisterPushToken, isAuthenticated {
            await sendPendingPushRegistrationIfPossible()
        }
    }

    func connect(
        using transport: any RelaySessionTransport,
        path: RelayTransportPath,
        shouldRegisterPushToken: Bool
    ) async throws {
        await disconnect(notify: false)

        self.transport = transport
        self.currentPath = path
        self.shouldRegisterPushToken = shouldRegisterPushToken
        self.isAuthenticated = false
        self.isStopping = false

        try await transport.start()

        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }

        let hello = RelayAuthHelloPayload(
            clientPubkeyB64: identity.publicKey.rawRepresentation.base64EncodedString()
        )
        try await sendFrame(type: "auth_hello", payload: hello)
        try await waitForAuthentication()
    }

    func disconnect(notify: Bool = true) async {
        isStopping = true
        if let authContinuation {
            self.authContinuation = nil
            authContinuation.resume(throwing: RelaySessionActorError.notConnected)
        }
        failAllPendingMessageAcceptances(with: RelaySessionActorError.notConnected)
        receiveTask?.cancel()
        receiveTask = nil
        let path = currentPath
        currentPath = nil
        isAuthenticated = false
        if let transport {
            await transport.stop()
            self.transport = nil
        }
        if notify, let path {
            await delegate?.relaySession(self, didDisconnect: path)
        }
    }

    func sendEnvelope(_ envelope: MessageEnvelope) async throws {
        guard isAuthenticated else {
            throw RelaySessionActorError.notConnected
        }

        let envelopeData = try MessageProtocol.encodeEnvelope(envelope)
        let messageID = envelope.id.uuidString
        let payload = RelayMessageSendPayload(
            messageID: messageID,
            recipientHashHex: Self.publicKeyHashHex(envelope.recipientPublicKey),
            envelopeB64: envelopeData.base64EncodedString()
        )

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                beginWaitingForMessageAcceptance(messageID: messageID, continuation: continuation)

                Task { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: RelaySessionActorError.notConnected)
                        return
                    }

                    do {
                        try await self.sendFrame(type: "msg_send", reqID: messageID, payload: payload)
                    } catch {
                        await self.failPendingMessageAcceptanceAndHandleOutboundFailure(
                            messageID: messageID,
                            error: error
                        )
                    }
                }
            }
        } catch {
            await handleOutboundFailure(error)
            throw error
        }
    }

    func sendDeliveryACK(messageID: UUID) async throws {
        guard isAuthenticated else {
            throw RelaySessionActorError.notConnected
        }

        do {
            try await sendFrame(
                type: "msg_ack",
                payload: RelayMessageAckPayload(messageID: messageID.uuidString)
            )
        } catch {
            await handleOutboundFailure(error)
            throw error
        }
    }

    private func waitForAuthentication() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            authContinuation = continuation

            Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: self?.authTimeoutNanoseconds ?? 5_000_000_000)
                } catch {
                    return
                }
                await self?.handleAuthTimeout()
            }
        }
    }

    private func handleAuthTimeout() async {
        guard let authContinuation else { return }
        self.authContinuation = nil
        authContinuation.resume(throwing: RelaySessionActorError.authTimedOut)
        await disconnect(notify: false)
    }

    private func runReceiveLoop() async {
        guard let transport else { return }

        for await text in transport.inboundFrames {
            do {
                try await handleIncomingText(text)
            } catch {
                if let authContinuation {
                    self.authContinuation = nil
                    authContinuation.resume(throwing: error)
                }
                let notify = !isStopping
                await disconnect(notify: notify)
                return
            }
        }

        if let authContinuation {
            self.authContinuation = nil
            authContinuation.resume(throwing: RelaySessionActorError.notConnected)
        }

        let notify = !isStopping && currentPath != nil
        await disconnect(notify: notify)
    }

    private func handleIncomingText(_ text: String) async throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let frameType = root["type"] as? String
        else {
            throw RelaySessionActorError.invalidFrame
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
            let authContinuation = self.authContinuation
            self.authContinuation = nil
            authContinuation?.resume()
            if let currentPath {
                await delegate?.relaySession(self, didConnect: currentPath)
            }
            await sendPendingPushRegistrationIfPossible()

        case "msg_deliver":
            let payload: RelayMessageDeliverPayload = try decodePayload(payloadAny)
            guard let envelopeData = Data(base64Encoded: payload.envelopeB64) else {
                throw RelaySessionActorError.invalidPayload
            }
            let envelope = try MessageProtocol.decodeEnvelope(envelopeData)
            await delegate?.relaySession(self, didReceiveEnvelope: envelope)

        case "msg_acked":
            let payload: RelayMessageAckedPayload = try decodePayload(payloadAny)
            guard let messageID = UUID(uuidString: payload.messageID) else {
                throw RelaySessionActorError.invalidPayload
            }
            await delegate?.relaySession(self, didReceiveDeliveryAck: messageID)

        case "msg_accepted":
            let payload: RelayMessageAcceptedPayload = try decodePayload(payloadAny)
            completePendingMessageAcceptance(messageID: reqID ?? payload.messageID)

        case "error":
            let payload: RelayErrorPayload = try decodePayload(payloadAny)
            if payload.code == "auth_failed" {
                throw RelaySessionActorError.authFailed
            }
            if let reqID {
                failPendingMessageAcceptance(
                    messageID: reqID,
                    error: RelaySessionActorError.sendRejected(code: payload.code)
                )
            }

        case "ping":
            try await sendFrame(type: "pong", reqID: reqID, payload: RelayEmptyPayload())

        case "pong":
            break

        default:
            break
        }
    }

    private func sendPendingPushRegistrationIfPossible() async {
        guard shouldRegisterPushToken, isAuthenticated else { return }
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

        try? await sendFrame(type: "push_register", payload: payload)
    }

    private func beginWaitingForMessageAcceptance(
        messageID: String,
        continuation: CheckedContinuation<Void, Error>
    ) {
        pendingMessageAcceptanceContinuations[messageID] = continuation
        pendingMessageAcceptanceTimeouts[messageID]?.cancel()
        pendingMessageAcceptanceTimeouts[messageID] = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: self?.messageAcceptanceTimeoutNanoseconds
                        ?? 5_000_000_000
                )
            } catch {
                return
            }
            await self?.failPendingMessageAcceptanceAndHandleOutboundFailure(
                messageID: messageID,
                error: RelaySessionActorError.sendTimedOut
            )
        }
    }

    private func completePendingMessageAcceptance(messageID: String) {
        pendingMessageAcceptanceTimeouts[messageID]?.cancel()
        pendingMessageAcceptanceTimeouts.removeValue(forKey: messageID)
        guard let continuation = pendingMessageAcceptanceContinuations.removeValue(forKey: messageID) else {
            return
        }
        continuation.resume()
    }

    private func failPendingMessageAcceptance(messageID: String, error: Error) {
        pendingMessageAcceptanceTimeouts[messageID]?.cancel()
        pendingMessageAcceptanceTimeouts.removeValue(forKey: messageID)
        guard let continuation = pendingMessageAcceptanceContinuations.removeValue(forKey: messageID) else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func failAllPendingMessageAcceptances(with error: Error) {
        let continuations = pendingMessageAcceptanceContinuations
        pendingMessageAcceptanceContinuations.removeAll()
        for task in pendingMessageAcceptanceTimeouts.values {
            task.cancel()
        }
        pendingMessageAcceptanceTimeouts.removeAll()
        for continuation in continuations.values {
            continuation.resume(throwing: error)
        }
    }

    private func handleOutboundFailure(_ error: Error) async {
        if case .sendRejected = error as? RelaySessionActorError {
            return
        }
        await disconnect(notify: true)
    }

    private func failPendingMessageAcceptanceAndHandleOutboundFailure(
        messageID: String,
        error: Error
    ) async {
        failPendingMessageAcceptance(messageID: messageID, error: error)
        await handleOutboundFailure(error)
    }

    private func sendFrame<Payload: Encodable>(
        type: String,
        reqID: String? = nil,
        payload: Payload
    ) async throws {
        guard let transport else {
            throw RelaySessionActorError.notConnected
        }
        let frame = RelayOutgoingFrame(type: type, reqID: reqID, payload: payload)
        let data = try encoder.encode(frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RelaySessionActorError.invalidFrame
        }
        try await transport.send(text: text)
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
            throw RelaySessionActorError.invalidPayload
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

private struct RelayMessageAckPayload: Codable {
    let messageID: String

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
    }
}

private struct RelayMessageAcceptedPayload: Codable {
    let messageID: String
    let queued: Bool
    let queueDepth: Int

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case queued
        case queueDepth = "queue_depth"
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
