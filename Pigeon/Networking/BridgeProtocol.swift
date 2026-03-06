import CryptoKit
import Foundation

nonisolated enum BridgeProtocolError: Error {
    case invalidEnvelope
    case invalidPayload
}

nonisolated struct BridgeStatusPayload: Codable, Hashable, Sendable {
    let bridgeProtocolVersion: Int
    let bridgeEnabled: Bool
    let relayReachable: Bool
    let capacityRemaining: Int?

    enum CodingKeys: String, CodingKey {
        case bridgeProtocolVersion = "bridge_protocol_version"
        case bridgeEnabled = "bridge_enabled"
        case relayReachable = "relay_reachable"
        case capacityRemaining = "capacity_remaining"
    }
}

nonisolated struct TunnelOpenPayload: Codable, Hashable, Sendable {
    let tunnelID: UUID

    enum CodingKeys: String, CodingKey {
        case tunnelID = "tunnel_id"
    }
}

nonisolated struct TunnelOpenedPayload: Codable, Hashable, Sendable {
    let tunnelID: UUID

    enum CodingKeys: String, CodingKey {
        case tunnelID = "tunnel_id"
    }
}

nonisolated struct TunnelDataPayload: Codable, Hashable, Sendable {
    let tunnelID: UUID
    let payloadB64: String

    enum CodingKeys: String, CodingKey {
        case tunnelID = "tunnel_id"
        case payloadB64 = "payload_b64"
    }
}

nonisolated struct TunnelClosePayload: Codable, Hashable, Sendable {
    let tunnelID: UUID
    let code: String
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case tunnelID = "tunnel_id"
        case code
        case reason
    }
}

nonisolated struct TunnelErrorPayload: Codable, Hashable, Sendable {
    let tunnelID: UUID?
    let code: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case tunnelID = "tunnel_id"
        case code
        case message
    }
}

nonisolated enum BridgeControlPayload: Hashable, Sendable {
    case bridgeStatus(BridgeStatusPayload)
    case tunnelOpen(TunnelOpenPayload)
    case tunnelOpened(TunnelOpenedPayload)
    case tunnelData(TunnelDataPayload)
    case tunnelClose(TunnelClosePayload)
    case tunnelError(TunnelErrorPayload)
    case ping
    case pong
}

nonisolated struct BridgeControlFrame: Codable, Hashable, Sendable {
    let type: String
    let tunnelID: UUID?
    let payload: BridgeControlPayload

    init(type: String, tunnelID: UUID? = nil, payload: BridgeControlPayload) {
        self.type = type
        self.tunnelID = tunnelID
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case tunnelID = "tunnel_id"
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let tunnelID = try container.decodeIfPresent(UUID.self, forKey: .tunnelID)

        self.type = type
        self.tunnelID = tunnelID

        switch type {
        case "bridge_status":
            payload = .bridgeStatus(try container.decode(BridgeStatusPayload.self, forKey: .payload))
        case "tunnel_open":
            payload = .tunnelOpen(try container.decode(TunnelOpenPayload.self, forKey: .payload))
        case "tunnel_opened":
            payload = .tunnelOpened(try container.decode(TunnelOpenedPayload.self, forKey: .payload))
        case "tunnel_data":
            payload = .tunnelData(try container.decode(TunnelDataPayload.self, forKey: .payload))
        case "tunnel_close":
            payload = .tunnelClose(try container.decode(TunnelClosePayload.self, forKey: .payload))
        case "tunnel_error":
            payload = .tunnelError(try container.decode(TunnelErrorPayload.self, forKey: .payload))
        case "ping":
            payload = .ping
        case "pong":
            payload = .pong
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported bridge control type"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(tunnelID, forKey: .tunnelID)

        switch payload {
        case .bridgeStatus(let payload):
            try container.encode(payload, forKey: .payload)
        case .tunnelOpen(let payload):
            try container.encode(payload, forKey: .payload)
        case .tunnelOpened(let payload):
            try container.encode(payload, forKey: .payload)
        case .tunnelData(let payload):
            try container.encode(payload, forKey: .payload)
        case .tunnelClose(let payload):
            try container.encode(payload, forKey: .payload)
        case .tunnelError(let payload):
            try container.encode(payload, forKey: .payload)
        case .ping, .pong:
            try container.encode([String: String](), forKey: .payload)
        }
    }
}

nonisolated enum BridgeProtocol {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    static let version = 1

    static func status(
        bridgeEnabled: Bool,
        relayReachable: Bool,
        capacityRemaining: Int?
    ) -> BridgeControlFrame {
        BridgeControlFrame(
            type: "bridge_status",
            payload: .bridgeStatus(
                BridgeStatusPayload(
                    bridgeProtocolVersion: version,
                    bridgeEnabled: bridgeEnabled,
                    relayReachable: relayReachable,
                    capacityRemaining: capacityRemaining
                )
            )
        )
    }

    static func tunnelOpen(_ tunnelID: UUID) -> BridgeControlFrame {
        BridgeControlFrame(
            type: "tunnel_open",
            tunnelID: tunnelID,
            payload: .tunnelOpen(TunnelOpenPayload(tunnelID: tunnelID))
        )
    }

    static func tunnelOpened(_ tunnelID: UUID) -> BridgeControlFrame {
        BridgeControlFrame(
            type: "tunnel_opened",
            tunnelID: tunnelID,
            payload: .tunnelOpened(TunnelOpenedPayload(tunnelID: tunnelID))
        )
    }

    static func tunnelData(_ tunnelID: UUID, text: String) -> BridgeControlFrame {
        let data = Data(text.utf8)
        return BridgeControlFrame(
            type: "tunnel_data",
            tunnelID: tunnelID,
            payload: .tunnelData(
                TunnelDataPayload(tunnelID: tunnelID, payloadB64: data.base64EncodedString())
            )
        )
    }

    static func tunnelClose(_ tunnelID: UUID, code: String, reason: String? = nil) -> BridgeControlFrame {
        BridgeControlFrame(
            type: "tunnel_close",
            tunnelID: tunnelID,
            payload: .tunnelClose(
                TunnelClosePayload(tunnelID: tunnelID, code: code, reason: reason)
            )
        )
    }

    static func tunnelError(_ tunnelID: UUID?, code: String, message: String) -> BridgeControlFrame {
        BridgeControlFrame(
            type: "tunnel_error",
            tunnelID: tunnelID,
            payload: .tunnelError(
                TunnelErrorPayload(tunnelID: tunnelID, code: code, message: message)
            )
        )
    }

    static var ping: BridgeControlFrame {
        BridgeControlFrame(type: "ping", payload: .ping)
    }

    static var pong: BridgeControlFrame {
        BridgeControlFrame(type: "pong", payload: .pong)
    }

    static func encode(_ frame: BridgeControlFrame) throws -> Data {
        try encoder.encode(frame)
    }

    static func decode(_ data: Data) throws -> BridgeControlFrame {
        try decoder.decode(BridgeControlFrame.self, from: data)
    }

    static func encrypt(
        _ frame: BridgeControlFrame,
        using crypto: CryptoManager,
        senderPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        recipientPublicKey: Data
    ) throws -> MessageEnvelope {
        let data = try encode(frame)
        return try crypto.encrypt(
            plaintext: data,
            senderPrivateKey: senderPrivateKey,
            recipientPublicKeyData: recipientPublicKey
        )
    }

    static func decrypt(
        _ envelope: MessageEnvelope,
        using crypto: CryptoManager,
        recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> BridgeControlFrame {
        let plaintext = try crypto.decrypt(envelope: envelope, recipientPrivateKey: recipientPrivateKey)
        return try decode(plaintext)
    }
}
