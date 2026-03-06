import Foundation

nonisolated enum BLEBridgeRelayTransportError: Error {
    case invalidPeer
    case tunnelRejected(String)
    case tunnelTimedOut
    case invalidPayload
    case notConnected
}

actor BLEBridgeRelayTransport: RelaySessionTransport {
    let inboundFrames: AsyncStream<String>

    let tunnelID: UUID
    let bridgePeer: BridgeCandidate

    private let openTimeoutNanoseconds: UInt64 = 5_000_000_000
    private let sendBridgeFrame: @Sendable (Data, BridgeControlFrame) async throws -> Void
    private let onStop: @Sendable (UUID) async -> Void

    private var continuation: AsyncStream<String>.Continuation?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var isStarted = false
    private var isOpen = false
    private var isClosed = false

    init(
        bridgePeer: BridgeCandidate,
        tunnelID: UUID = UUID(),
        sendBridgeFrame: @escaping @Sendable (Data, BridgeControlFrame) async throws -> Void,
        onStop: @escaping @Sendable (UUID) async -> Void = { _ in }
    ) {
        self.bridgePeer = bridgePeer
        self.tunnelID = tunnelID
        self.sendBridgeFrame = sendBridgeFrame
        self.onStop = onStop

        var streamContinuation: AsyncStream<String>.Continuation?
        inboundFrames = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async throws {
        guard !isStarted else { return }
        isStarted = true

        try await sendBridgeFrame(bridgePeer.publicKey, BridgeProtocol.tunnelOpen(tunnelID))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            openContinuation = continuation

            Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: self?.openTimeoutNanoseconds ?? 5_000_000_000)
                } catch {
                    return
                }

                await self?.handleOpenTimeout()
            }
        }
    }

    func stop() async {
        guard !isClosed else { return }
        isClosed = true
        openContinuation?.resume(throwing: BLEBridgeRelayTransportError.notConnected)
        openContinuation = nil
        isOpen = false
        await sendRemoteCloseIfNeeded(code: "client_closed", reason: "transport stopped")
        continuation?.finish()
        await onStop(tunnelID)
    }

    func send(text: String) async throws {
        guard isOpen, !isClosed else {
            throw BLEBridgeRelayTransportError.notConnected
        }
        try await sendBridgeFrame(bridgePeer.publicKey, BridgeProtocol.tunnelData(tunnelID, text: text))
    }

    func receive(_ frame: BridgeControlFrame, from peerPublicKey: Data) async {
        guard peerPublicKey == bridgePeer.publicKey else { return }
        guard !isClosed else { return }

        switch frame.payload {
        case .tunnelOpened(let payload):
            guard payload.tunnelID == tunnelID else { return }
            isOpen = true
            openContinuation?.resume()
            openContinuation = nil

        case .tunnelData(let payload):
            guard payload.tunnelID == tunnelID else { return }
            guard let data = Data(base64Encoded: payload.payloadB64),
                  let text = String(data: data, encoding: .utf8)
            else {
                continuation?.finish()
                return
            }
            continuation?.yield(text)

        case .tunnelClose(let payload):
            guard payload.tunnelID == tunnelID else { return }
            continuation?.finish()
            openContinuation?.resume(throwing: BLEBridgeRelayTransportError.tunnelRejected(payload.code))
            openContinuation = nil
            isOpen = false
            isClosed = true
            await onStop(tunnelID)

        case .tunnelError(let payload):
            guard payload.tunnelID == nil || payload.tunnelID == tunnelID else { return }
            continuation?.finish()
            openContinuation?.resume(throwing: BLEBridgeRelayTransportError.tunnelRejected(payload.message))
            openContinuation = nil
            isOpen = false
            isClosed = true
            await onStop(tunnelID)

        case .ping:
            try? await sendBridgeFrame(peerPublicKey, BridgeProtocol.pong)

        case .pong, .bridgeStatus, .tunnelOpen:
            break
        }
    }

    private func handleOpenTimeout() async {
        guard openContinuation != nil else { return }
        let continuation = openContinuation
        openContinuation = nil
        continuation?.resume(throwing: BLEBridgeRelayTransportError.tunnelTimedOut)
        isOpen = false
        isClosed = true
        await sendRemoteCloseIfNeeded(code: "open_timeout", reason: "bridge open timed out")
        self.continuation?.finish()
        await onStop(tunnelID)
    }

    private func sendRemoteCloseIfNeeded(code: String, reason: String) async {
        guard isStarted else { return }
        try? await sendBridgeFrame(
            bridgePeer.publicKey,
            BridgeProtocol.tunnelClose(tunnelID, code: code, reason: reason)
        )
    }
}
