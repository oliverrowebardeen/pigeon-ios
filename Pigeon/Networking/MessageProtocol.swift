import Foundation

nonisolated struct MessageEnvelope: Codable, Hashable, Sendable {
    let id: UUID
    let senderPublicKey: Data
    let recipientPublicKey: Data
    let timestamp: Date
    let nonce: Data
    let ciphertext: Data
    let tag: Data
    var hopCount: UInt8
    let ttl: UInt8

    init(
        id: UUID = UUID(),
        senderPublicKey: Data,
        recipientPublicKey: Data,
        timestamp: Date = Date(),
        nonce: Data,
        ciphertext: Data,
        tag: Data,
        hopCount: UInt8 = 0,
        ttl: UInt8 = BLEConstants.defaultTTL
    ) {
        self.id = id
        self.senderPublicKey = senderPublicKey
        self.recipientPublicKey = recipientPublicKey
        self.timestamp = timestamp
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
        self.hopCount = hopCount
        self.ttl = ttl
    }
}

nonisolated struct PeerIdentityPayload: Codable, Hashable, Sendable {
    let publicKey: Data
    let pigeonID: String
    let displayName: String?
    let bridgeProtocolVersion: Int?
    let bridgeEnabled: Bool?
    let relayReachable: Bool?
    let bridgeCapacityRemaining: Int?
}

nonisolated struct DeliveryACK: Codable, Hashable, Sendable {
    let messageID: UUID
    let senderPublicKey: Data
    let timestamp: Date
}

nonisolated struct BLEPacketHeader: Codable, Hashable, Sendable {
    let messageID: UUID
    let chunkIndex: UInt16
    let totalChunks: UInt16
    let payloadSize: UInt16
}

nonisolated struct BLEPacket: Hashable, Sendable {
    let header: BLEPacketHeader
    let payload: Data
}

nonisolated enum MessageProtocolError: Error {
    case invalidChunkSize
    case payloadTooLarge
    case malformedPacket
    case inconsistentChunks
    case missingChunk(UInt16)
}

nonisolated enum MessageProtocol {
    private static let envelopeEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let envelopeDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    private static let identityEncoder = JSONEncoder()
    private static let identityDecoder = JSONDecoder()

    private static let ackEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let ackDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    static func encodeEnvelope(_ envelope: MessageEnvelope) throws -> Data {
        try envelopeEncoder.encode(envelope)
    }

    static func decodeEnvelope(_ data: Data) throws -> MessageEnvelope {
        try envelopeDecoder.decode(MessageEnvelope.self, from: data)
    }

    static func encodePeerIdentity(_ payload: PeerIdentityPayload) throws -> Data {
        try identityEncoder.encode(payload)
    }

    static func decodePeerIdentity(_ data: Data) throws -> PeerIdentityPayload {
        try identityDecoder.decode(PeerIdentityPayload.self, from: data)
    }

    static func encodeACK(_ ack: DeliveryACK) throws -> Data {
        try ackEncoder.encode(ack)
    }

    static func decodeACK(_ data: Data) throws -> DeliveryACK {
        try ackDecoder.decode(DeliveryACK.self, from: data)
    }

    static func chunkEnvelope(
        _ envelope: MessageEnvelope,
        maxChunkPayloadSize: Int = BLEConstants.maxChunkPayloadSize
    ) throws -> [Data] {
        let body = try encodeEnvelope(envelope)
        return try chunk(data: body, messageID: envelope.id, maxChunkPayloadSize: maxChunkPayloadSize)
    }

    static func chunk(
        data: Data,
        messageID: UUID,
        maxChunkPayloadSize: Int = BLEConstants.maxChunkPayloadSize
    ) throws -> [Data] {
        guard maxChunkPayloadSize > 0 else {
            throw MessageProtocolError.invalidChunkSize
        }

        let totalChunkCount = max(1, (data.count + maxChunkPayloadSize - 1) / maxChunkPayloadSize)
        guard totalChunkCount <= Int(UInt16.max) else {
            throw MessageProtocolError.payloadTooLarge
        }

        let totalChunks = UInt16(totalChunkCount)
        var packets: [Data] = []
        packets.reserveCapacity(totalChunkCount)

        for index in 0 ..< totalChunkCount {
            let start = index * maxChunkPayloadSize
            let end = min(start + maxChunkPayloadSize, data.count)
            let payload = data.subdata(in: start ..< end)

            let header = BLEPacketHeader(
                messageID: messageID,
                chunkIndex: UInt16(index),
                totalChunks: totalChunks,
                payloadSize: UInt16(payload.count)
            )

            let packet = BLEPacket(header: header, payload: payload)
            packets.append(encodePacket(packet))
        }

        return packets
    }

    static func decodePacket(_ data: Data) throws -> BLEPacket {
        guard data.count >= BLEConstants.packetHeaderSize else {
            throw MessageProtocolError.malformedPacket
        }

        let uuidBytes = Array(data.prefix(16))
        guard let messageID = UUID(byteArray: uuidBytes[...]) else {
            throw MessageProtocolError.malformedPacket
        }

        guard
            let chunkIndex = data.readUInt16(at: 16),
            let totalChunks = data.readUInt16(at: 18),
            let payloadSize = data.readUInt16(at: 20)
        else {
            throw MessageProtocolError.malformedPacket
        }

        guard totalChunks > 0, chunkIndex < totalChunks else {
            throw MessageProtocolError.malformedPacket
        }

        let payloadStart = BLEConstants.packetHeaderSize
        let payload = data.suffix(from: payloadStart)

        guard payload.count == Int(payloadSize) else {
            throw MessageProtocolError.malformedPacket
        }

        let header = BLEPacketHeader(
            messageID: messageID,
            chunkIndex: chunkIndex,
            totalChunks: totalChunks,
            payloadSize: payloadSize
        )

        return BLEPacket(header: header, payload: Data(payload))
    }

    static func encodePacket(_ packet: BLEPacket) -> Data {
        var data = Data()
        data.reserveCapacity(BLEConstants.packetHeaderSize + Int(packet.header.payloadSize))

        data.append(contentsOf: packet.header.messageID.byteArray)
        data.appendUInt16(packet.header.chunkIndex)
        data.appendUInt16(packet.header.totalChunks)
        data.appendUInt16(packet.header.payloadSize)
        data.append(packet.payload)

        return data
    }

    static func reassembleEnvelope(from packetData: [Data]) throws -> MessageEnvelope {
        let payload = try reassemblePayload(from: packetData)
        return try decodeEnvelope(payload)
    }

    static func reassemblePayload(from packetData: [Data]) throws -> Data {
        let packets = try packetData.map(decodePacket(_:))
        return try reassemblePayload(from: packets)
    }

    static func reassemblePayload(from packets: [BLEPacket]) throws -> Data {
        guard let firstPacket = packets.first else {
            return Data()
        }

        let expectedMessageID = firstPacket.header.messageID
        let expectedTotalChunks = firstPacket.header.totalChunks

        guard expectedTotalChunks > 0 else {
            throw MessageProtocolError.inconsistentChunks
        }

        var chunkMap: [UInt16: Data] = [:]
        chunkMap.reserveCapacity(Int(expectedTotalChunks))

        for packet in packets {
            guard
                packet.header.messageID == expectedMessageID,
                packet.header.totalChunks == expectedTotalChunks,
                packet.payload.count == Int(packet.header.payloadSize)
            else {
                throw MessageProtocolError.inconsistentChunks
            }

            chunkMap[packet.header.chunkIndex] = packet.payload
        }

        guard chunkMap.count == Int(expectedTotalChunks) else {
            for index in 0 ..< expectedTotalChunks where chunkMap[index] == nil {
                throw MessageProtocolError.missingChunk(index)
            }
            throw MessageProtocolError.inconsistentChunks
        }

        var assembled = Data()

        for index in 0 ..< expectedTotalChunks {
            guard let chunk = chunkMap[index] else {
                throw MessageProtocolError.missingChunk(index)
            }
            assembled.append(chunk)
        }

        return assembled
    }

    static func incrementHopCountIfAllowed(_ envelope: MessageEnvelope) -> MessageEnvelope? {
        guard envelope.hopCount < envelope.ttl else {
            return nil
        }

        var next = envelope
        next.hopCount += 1
        return next
    }
}
