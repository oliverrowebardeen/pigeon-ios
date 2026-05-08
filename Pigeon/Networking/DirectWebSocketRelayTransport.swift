import Foundation

nonisolated enum DirectWebSocketRelayTransportError: Error {
    case invalidFrame
    case notStarted
}

actor DirectWebSocketRelayTransport: RelaySessionTransport {
    let inboundFrames: AsyncStream<String>

    private let relayURL: URL
    private var continuation: AsyncStream<String>.Continuation?
    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    init(relayURL: URL) {
        self.relayURL = relayURL
        var streamContinuation: AsyncStream<String>.Continuation?
        inboundFrames = AsyncStream { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation
    }

    func start() async throws {
        guard webSocketTask == nil else { return }

        // Dedicated ephemeral URLSession per transport instance: avoids
        // URLSession.shared's pooled connection state surviving an interface
        // migration (e.g. cellular → Wi-Fi), which leaves the next WebSocket
        // attempt pointing at a dead route until the app is restarted.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        // Bound only the initial HTTP upgrade. timeoutIntervalForResource is a
        // total-task-lifetime cap on URLSessionWebSocketTask; setting it would
        // force-close the long-lived socket. Leave it at the default (7 days);
        // app-layer ping/pong on the actor catches dead connections.
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        self.session = session

        let task = session.webSocketTask(with: relayURL)
        webSocketTask = task
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    func stop() async {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        // invalidateAndCancel releases any pooled connection state held by this
        // session so a subsequent reconnect cannot inherit a dead route.
        session?.invalidateAndCancel()
        session = nil
        continuation?.finish()
    }

    func send(text: String) async throws {
        guard let webSocketTask else {
            throw DirectWebSocketRelayTransportError.notStarted
        }
        try await webSocketTask.send(.string(text))
    }

    private func runReceiveLoop() async {
        while let webSocketTask {
            do {
                let message = try await webSocketTask.receive()
                switch message {
                case .string(let text):
                    continuation?.yield(text)
                case .data(let data):
                    guard let text = String(data: data, encoding: .utf8) else {
                        continuation?.finish()
                        return
                    }
                    continuation?.yield(text)
                @unknown default:
                    continuation?.finish()
                    return
                }
            } catch {
                continuation?.finish()
                return
            }
        }
    }
}
