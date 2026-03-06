import Foundation

nonisolated protocol RelaySessionTransport: Sendable {
    var inboundFrames: AsyncStream<String> { get }

    func start() async throws
    func stop() async
    func send(text: String) async throws
}

nonisolated enum RelayTransportPath: Sendable {
    case direct
    case bridged(BridgeCandidate)
}
