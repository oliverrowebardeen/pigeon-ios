import Foundation

nonisolated enum DirectWebSocketRelayTransportError: Error {
    case invalidFrame
    case notStarted
}

actor DirectWebSocketRelayTransport: RelaySessionTransport {
    let inboundFrames: AsyncStream<String>

    private let relayURL: URL
    private var continuation: AsyncStream<String>.Continuation?
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
        let task = URLSession.shared.webSocketTask(with: relayURL)
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
