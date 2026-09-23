import Foundation

// MARK: - Meshtastic Protobuf Message Types

/// Decoded MeshPacket.Data payload
nonisolated struct MeshtasticDataPayload: Sendable {
    var portnum: UInt32
    var payload: Data
    var dest: UInt32 = 0
    var source: UInt32 = 0
    var requestID: UInt32 = 0
}

/// Decoded MeshPacket
nonisolated struct MeshtasticMeshPacket: Sendable {
    var from: UInt32 = 0
    var to: UInt32 = 0
    var channel: UInt32 = 0
    var id: UInt32 = 0
    var hopLimit: UInt32 = 0
    var wantAck: Bool = false
    var priority: UInt32 = 0

    // oneof: decoded (Data) or encrypted (bytes)
    var decoded: MeshtasticDataPayload?
    var encrypted: Data?
}

/// User info from NodeInfo
nonisolated struct MeshtasticUser: Sendable {
    var id: String = ""
    var longName: String = ""
    var shortName: String = ""
    var hwModel: UInt32 = 0
}

/// NodeInfo from mesh
nonisolated struct MeshtasticNodeInfo: Sendable {
    var num: UInt32 = 0
    var user: MeshtasticUser?
}

/// FromRadio message (what the phone reads from the Meshtastic device)
nonisolated struct MeshtasticFromRadio: Sendable {
    var id: UInt32 = 0

    // oneof payload variants
    var packet: MeshtasticMeshPacket?
    var myInfo: MeshtasticMyNodeInfo?
    var nodeInfo: MeshtasticNodeInfo?
    var configCompleteID: UInt32?
    var rebooted: Bool?
}

/// MyNodeInfo
nonisolated struct MeshtasticMyNodeInfo: Sendable {
    var myNodeNum: UInt32 = 0
}

/// ToRadio message (what the phone writes to the Meshtastic device)
nonisolated struct MeshtasticToRadio: Sendable {
    // oneof: packet, wantConfigID, disconnect, heartbeat
    var packet: MeshtasticMeshPacket?
    var wantConfigID: UInt32?
    var disconnect: Bool?
    var heartbeat: Bool?
}

// MARK: - Protobuf Wire Format Constants

/// Protobuf field numbers for each message type
nonisolated private enum FieldNumbers {
    nonisolated enum ToRadio {
        static let packet: UInt32 = 1
        static let wantConfigID: UInt32 = 3
        static let disconnect: UInt32 = 4
    }

    nonisolated enum FromRadio {
        static let id: UInt32 = 1
        static let packet: UInt32 = 2
        static let myInfo: UInt32 = 3
        static let nodeInfo: UInt32 = 4
        static let configCompleteID: UInt32 = 8
        static let rebooted: UInt32 = 14
    }

    nonisolated enum MeshPacket {
        static let from: UInt32 = 1
        static let to: UInt32 = 2
        static let channel: UInt32 = 3
        static let decoded: UInt32 = 4
        static let encrypted: UInt32 = 5
        static let id: UInt32 = 6
        static let hopLimit: UInt32 = 9
        static let wantAck: UInt32 = 10
        static let priority: UInt32 = 11
    }

    nonisolated enum DataPayload {
        static let portnum: UInt32 = 1
        static let payload: UInt32 = 2
        static let dest: UInt32 = 4
        static let source: UInt32 = 5
        static let requestID: UInt32 = 6
    }

    nonisolated enum NodeInfo {
        static let num: UInt32 = 1
        static let user: UInt32 = 2
    }

    nonisolated enum User {
        static let id: UInt32 = 1
        static let longName: UInt32 = 2
        static let shortName: UInt32 = 3
        static let hwModel: UInt32 = 6
    }

    nonisolated enum MyNodeInfo {
        static let myNodeNum: UInt32 = 1
    }
}

// MARK: - Protobuf Wire Types

nonisolated private enum WireType: UInt8 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

// MARK: - Protobuf Encoder

nonisolated enum MeshtasticProtobuf {

    // MARK: - ToRadio Encoding

    static func encode(_ toRadio: MeshtasticToRadio) -> Data {
        var buf = Data()

        if let packet = toRadio.packet {
            let encoded = encodeMeshPacket(packet)
            buf.appendTag(field: FieldNumbers.ToRadio.packet, wireType: .lengthDelimited)
            buf.appendVarint(UInt64(encoded.count))
            buf.append(encoded)
        }

        if let configID = toRadio.wantConfigID {
            buf.appendTag(field: FieldNumbers.ToRadio.wantConfigID, wireType: .varint)
            buf.appendVarint(UInt64(configID))
        }

        if toRadio.disconnect == true {
            buf.appendTag(field: FieldNumbers.ToRadio.disconnect, wireType: .varint)
            buf.appendVarint(1)
        }

        return buf
    }

    // MARK: - FromRadio Decoding

    static func decodeFromRadio(_ data: Data) throws -> MeshtasticFromRadio {
        var result = MeshtasticFromRadio()
        var reader = ProtobufReader(data: data)

        while !reader.isAtEnd {
            let (field, wireType) = try reader.readTag()

            switch (field, wireType) {
            case (FieldNumbers.FromRadio.id, WireType.varint.rawValue):
                result.id = try reader.readUInt32Varint()

            case (FieldNumbers.FromRadio.packet, WireType.lengthDelimited.rawValue):
                let bytes = try reader.readBytes()
                result.packet = try decodeMeshPacket(bytes)

            case (FieldNumbers.FromRadio.myInfo, WireType.lengthDelimited.rawValue):
                let bytes = try reader.readBytes()
                result.myInfo = try decodeMyNodeInfo(bytes)

            case (FieldNumbers.FromRadio.nodeInfo, WireType.lengthDelimited.rawValue):
                let bytes = try reader.readBytes()
                result.nodeInfo = try decodeNodeInfo(bytes)

            case (FieldNumbers.FromRadio.configCompleteID, WireType.varint.rawValue):
                result.configCompleteID = try reader.readUInt32Varint()

            case (FieldNumbers.FromRadio.rebooted, WireType.varint.rawValue):
                result.rebooted = try reader.readVarint() != 0

            default:
                try reader.skipField(wireType: wireType)
            }
        }

        return result
    }

    // MARK: - MeshPacket Encode/Decode

    static func encodeMeshPacket(_ packet: MeshtasticMeshPacket) -> Data {
        var buf = Data()

        if packet.from != 0 {
            buf.appendTag(field: FieldNumbers.MeshPacket.from, wireType: .varint)
            buf.appendVarint(UInt64(packet.from))
        }

        if packet.to != 0 {
            buf.appendTag(field: FieldNumbers.MeshPacket.to, wireType: .varint)
            buf.appendVarint(UInt64(packet.to))
        }

        if packet.channel != 0 {
            buf.appendTag(field: FieldNumbers.MeshPacket.channel, wireType: .varint)
            buf.appendVarint(UInt64(packet.channel))
        }

        if let decoded = packet.decoded {
            let encoded = encodeDataPayload(decoded)
            buf.appendTag(field: FieldNumbers.MeshPacket.decoded, wireType: .lengthDelimited)
            buf.appendVarint(UInt64(encoded.count))
            buf.append(encoded)
        }

        if let encrypted = packet.encrypted {
            buf.appendTag(field: FieldNumbers.MeshPacket.encrypted, wireType: .lengthDelimited)
            buf.appendVarint(UInt64(encrypted.count))
            buf.append(encrypted)
        }

        if packet.id != 0 {
            buf.appendTag(field: FieldNumbers.MeshPacket.id, wireType: .fixed32)
            buf.appendFixed32(packet.id)
        }

        if packet.hopLimit != 0 {
            buf.appendTag(field: FieldNumbers.MeshPacket.hopLimit, wireType: .varint)
            buf.appendVarint(UInt64(packet.hopLimit))
        }

        if packet.wantAck {
            buf.appendTag(field: FieldNumbers.MeshPacket.wantAck, wireType: .varint)
            buf.appendVarint(1)
        }

        if packet.priority != 0 {
            buf.appendTag(field: FieldNumbers.MeshPacket.priority, wireType: .varint)
            buf.appendVarint(UInt64(packet.priority))
        }

        return buf
    }

    static func decodeMeshPacket(_ data: Data) throws -> MeshtasticMeshPacket {
        var result = MeshtasticMeshPacket()
        var reader = ProtobufReader(data: data)

        while !reader.isAtEnd {
            let (field, wireType) = try reader.readTag()

            switch (field, wireType) {
            case (FieldNumbers.MeshPacket.from, WireType.varint.rawValue):
                result.from = try reader.readUInt32Varint()

            case (FieldNumbers.MeshPacket.to, WireType.varint.rawValue):
                result.to = try reader.readUInt32Varint()

            case (FieldNumbers.MeshPacket.channel, WireType.varint.rawValue):
                result.channel = try reader.readUInt32Varint()

            case (FieldNumbers.MeshPacket.decoded, WireType.lengthDelimited.rawValue):
                let bytes = try reader.readBytes()
                result.decoded = try decodeDataPayload(bytes)

            case (FieldNumbers.MeshPacket.encrypted, WireType.lengthDelimited.rawValue):
                result.encrypted = try reader.readBytes()

            case (FieldNumbers.MeshPacket.id, WireType.fixed32.rawValue):
                result.id = try reader.readFixed32()

            case (FieldNumbers.MeshPacket.hopLimit, WireType.varint.rawValue):
                result.hopLimit = try reader.readUInt32Varint()

            case (FieldNumbers.MeshPacket.wantAck, WireType.varint.rawValue):
                result.wantAck = try reader.readVarint() != 0

            case (FieldNumbers.MeshPacket.priority, WireType.varint.rawValue):
                result.priority = try reader.readUInt32Varint()

            default:
                try reader.skipField(wireType: wireType)
            }
        }

        return result
    }

    // MARK: - Data Payload Encode/Decode

    static func encodeDataPayload(_ payload: MeshtasticDataPayload) -> Data {
        var buf = Data()

        if payload.portnum != 0 {
            buf.appendTag(field: FieldNumbers.DataPayload.portnum, wireType: .varint)
            buf.appendVarint(UInt64(payload.portnum))
        }

        if !payload.payload.isEmpty {
            buf.appendTag(field: FieldNumbers.DataPayload.payload, wireType: .lengthDelimited)
            buf.appendVarint(UInt64(payload.payload.count))
            buf.append(payload.payload)
        }

        if payload.dest != 0 {
            buf.appendTag(field: FieldNumbers.DataPayload.dest, wireType: .varint)
            buf.appendVarint(UInt64(payload.dest))
        }

        if payload.source != 0 {
            buf.appendTag(field: FieldNumbers.DataPayload.source, wireType: .varint)
            buf.appendVarint(UInt64(payload.source))
        }

        if payload.requestID != 0 {
            buf.appendTag(field: FieldNumbers.DataPayload.requestID, wireType: .varint)
            buf.appendVarint(UInt64(payload.requestID))
        }

        return buf
    }

    static func decodeDataPayload(_ data: Data) throws -> MeshtasticDataPayload {
        var result = MeshtasticDataPayload(portnum: 0, payload: Data())
        var reader = ProtobufReader(data: data)

        while !reader.isAtEnd {
            let (field, wireType) = try reader.readTag()

            switch (field, wireType) {
            case (FieldNumbers.DataPayload.portnum, WireType.varint.rawValue):
                result.portnum = try reader.readUInt32Varint()

            case (FieldNumbers.DataPayload.payload, WireType.lengthDelimited.rawValue):
                result.payload = try reader.readBytes()

            case (FieldNumbers.DataPayload.dest, WireType.varint.rawValue):
                result.dest = try reader.readUInt32Varint()

            case (FieldNumbers.DataPayload.source, WireType.varint.rawValue):
                result.source = try reader.readUInt32Varint()

            case (FieldNumbers.DataPayload.requestID, WireType.varint.rawValue):
                result.requestID = try reader.readUInt32Varint()

            default:
                try reader.skipField(wireType: wireType)
            }
        }

        return result
    }

    // MARK: - NodeInfo / User / MyNodeInfo

    static func decodeNodeInfo(_ data: Data) throws -> MeshtasticNodeInfo {
        var result = MeshtasticNodeInfo()
        var reader = ProtobufReader(data: data)

        while !reader.isAtEnd {
            let (field, wireType) = try reader.readTag()

            switch (field, wireType) {
            case (FieldNumbers.NodeInfo.num, WireType.varint.rawValue):
                result.num = try reader.readUInt32Varint()

            case (FieldNumbers.NodeInfo.user, WireType.lengthDelimited.rawValue):
                let bytes = try reader.readBytes()
                result.user = try decodeUser(bytes)

            default:
                try reader.skipField(wireType: wireType)
            }
        }

        return result
    }

    static func decodeUser(_ data: Data) throws -> MeshtasticUser {
        var result = MeshtasticUser()
        var reader = ProtobufReader(data: data)

        while !reader.isAtEnd {
            let (field, wireType) = try reader.readTag()

            switch (field, wireType) {
            case (FieldNumbers.User.id, WireType.lengthDelimited.rawValue):
                result.id = try reader.readString()

            case (FieldNumbers.User.longName, WireType.lengthDelimited.rawValue):
                result.longName = try reader.readString()

            case (FieldNumbers.User.shortName, WireType.lengthDelimited.rawValue):
                result.shortName = try reader.readString()

            case (FieldNumbers.User.hwModel, WireType.varint.rawValue):
                result.hwModel = try reader.readUInt32Varint()

            default:
                try reader.skipField(wireType: wireType)
            }
        }

        return result
    }

    static func decodeMyNodeInfo(_ data: Data) throws -> MeshtasticMyNodeInfo {
        var result = MeshtasticMyNodeInfo()
        var reader = ProtobufReader(data: data)

        while !reader.isAtEnd {
            let (field, wireType) = try reader.readTag()

            switch (field, wireType) {
            case (FieldNumbers.MyNodeInfo.myNodeNum, WireType.varint.rawValue):
                result.myNodeNum = try reader.readUInt32Varint()

            default:
                try reader.skipField(wireType: wireType)
            }
        }

        return result
    }
}

// MARK: - Protobuf Error

nonisolated enum ProtobufError: Error {
    case truncated
    case malformedVarint
    case invalidWireType
    case invalidUTF8
}

// MARK: - Protobuf Reader

nonisolated private struct ProtobufReader {
    private let data: Data
    private var offset: Int = 0

    var isAtEnd: Bool { offset >= data.count }

    init(data: Data) {
        self.data = data
    }

    mutating func readTag() throws -> (field: UInt32, wireType: UInt8) {
        let tagValue = try readUInt32Varint()
        guard tagValue >> 3 != 0 else { throw ProtobufError.invalidWireType }
        let field = tagValue >> 3
        let wireType = UInt8(tagValue & 0x07)
        return (field, wireType)
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while offset < data.count {
            let byte = data[data.startIndex + offset]
            offset += 1
            guard shift < 63 || byte <= 1 else { throw ProtobufError.malformedVarint }
            result |= UInt64(byte & 0x7F) << shift

            if byte & 0x80 == 0 {
                return result
            }

            shift += 7
            if shift >= 64 {
                throw ProtobufError.malformedVarint
            }
        }

        throw ProtobufError.truncated
    }

    mutating func readUInt32Varint() throws -> UInt32 {
        guard let value = UInt32(exactly: try readVarint()) else {
            throw ProtobufError.malformedVarint
        }
        return value
    }

    mutating func readLength() throws -> Int {
        let value = try readVarint()
        guard value <= UInt64(data.count - offset) else { throw ProtobufError.truncated }
        return Int(value)
    }

    mutating func readFixed32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw ProtobufError.truncated }
        let value = data.withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4
        return UInt32(littleEndian: value)
    }

    mutating func readFixed64() throws -> UInt64 {
        guard offset + 8 <= data.count else { throw ProtobufError.truncated }
        let value = data.withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        }
        offset += 8
        return UInt64(littleEndian: value)
    }

    mutating func readBytes() throws -> Data {
        let length = try readLength()
        guard offset + length <= data.count else { throw ProtobufError.truncated }
        let start = data.startIndex + offset
        let bytes = data[start ..< start + length]
        offset += length
        return Data(bytes)
    }

    mutating func readString() throws -> String {
        let bytes = try readBytes()
        guard let str = String(data: bytes, encoding: .utf8) else {
            throw ProtobufError.invalidUTF8
        }
        return str
    }

    mutating func skipField(wireType: UInt8) throws {
        switch wireType {
        case WireType.varint.rawValue:
            _ = try readVarint()
        case WireType.fixed64.rawValue:
            guard offset + 8 <= data.count else { throw ProtobufError.truncated }
            offset += 8
        case WireType.lengthDelimited.rawValue:
            let length = try readLength()
            guard offset + length <= data.count else { throw ProtobufError.truncated }
            offset += length
        case WireType.fixed32.rawValue:
            guard offset + 4 <= data.count else { throw ProtobufError.truncated }
            offset += 4
        default:
            throw ProtobufError.invalidWireType
        }
    }
}

// MARK: - Data Extensions for Protobuf Writing

extension Data {
    nonisolated fileprivate mutating func appendVarint(_ value: UInt64) {
        var v = value
        while v > 0x7F {
            append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        append(UInt8(v))
    }

    nonisolated fileprivate mutating func appendTag(field: UInt32, wireType: WireType) {
        appendVarint(UInt64(field << 3 | UInt32(wireType.rawValue)))
    }

    nonisolated fileprivate mutating func appendFixed32(_ value: UInt32) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 4))
    }
}
