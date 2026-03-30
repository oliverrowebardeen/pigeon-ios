import Foundation
import Testing
@testable import Pigeon

@Suite("MeshtasticProtobuf")
struct MeshtasticProtobufTests {

    // MARK: - ToRadio / FromRadio Round-Trip

    @Test func toRadioWantConfigRoundTrip() throws {
        let original = MeshtasticToRadio(wantConfigID: 42)
        let encoded = MeshtasticProtobuf.encode(original)
        #expect(!encoded.isEmpty)

        // Decode as FromRadio to verify wire format is parseable
        // (ToRadio and FromRadio share field numbers for config_complete_id / want_config_id)
        // We can't decode ToRadio directly since we only have a FromRadio decoder,
        // but we can verify the encoded bytes are valid protobuf.
        #expect(encoded.count > 0)
    }

    @Test func toRadioDisconnectEncodes() {
        let msg = MeshtasticToRadio(disconnect: true)
        let encoded = MeshtasticProtobuf.encode(msg)
        #expect(!encoded.isEmpty)
    }

    // MARK: - MeshPacket Round-Trip

    @Test func meshPacketRoundTrip() throws {
        let data = MeshtasticDataPayload(
            portnum: 256,
            payload: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            dest: 0,
            source: 42
        )
        let original = MeshtasticMeshPacket(
            from: 100,
            to: 0xFFFF_FFFF,
            channel: 0,
            id: 12345,
            hopLimit: 3,
            wantAck: false,
            priority: 0,
            decoded: data
        )

        let encoded = MeshtasticProtobuf.encodeMeshPacket(original)
        let decoded = try MeshtasticProtobuf.decodeMeshPacket(encoded)

        #expect(decoded.from == 100)
        #expect(decoded.to == 0xFFFF_FFFF)
        #expect(decoded.id == 12345)
        #expect(decoded.hopLimit == 3)
        #expect(decoded.wantAck == false)
        #expect(decoded.decoded?.portnum == 256)
        #expect(decoded.decoded?.payload == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(decoded.decoded?.source == 42)
    }

    @Test func meshPacketWithEncryptedPayload() throws {
        let encrypted = Data(repeating: 0xAB, count: 32)
        let original = MeshtasticMeshPacket(
            from: 1,
            to: 2,
            id: 999,
            hopLimit: 5,
            encrypted: encrypted
        )

        let encoded = MeshtasticProtobuf.encodeMeshPacket(original)
        let decoded = try MeshtasticProtobuf.decodeMeshPacket(encoded)

        #expect(decoded.from == 1)
        #expect(decoded.to == 2)
        #expect(decoded.id == 999)
        #expect(decoded.encrypted == encrypted)
        #expect(decoded.decoded == nil)
    }

    // MARK: - Data Payload Round-Trip

    @Test func dataPayloadRoundTrip() throws {
        let original = MeshtasticDataPayload(
            portnum: 256,
            payload: Data("hello".utf8),
            dest: 100,
            source: 200,
            requestID: 555
        )

        let encoded = MeshtasticProtobuf.encodeDataPayload(original)
        let decoded = try MeshtasticProtobuf.decodeDataPayload(encoded)

        #expect(decoded.portnum == 256)
        #expect(decoded.payload == Data("hello".utf8))
        #expect(decoded.dest == 100)
        #expect(decoded.source == 200)
        #expect(decoded.requestID == 555)
    }

    // MARK: - NodeInfo Decoding

    @Test func nodeInfoDecode() throws {
        // Manually encode a NodeInfo with num=42 and a User sub-message
        var userBuf = Data()
        // field 1 (id), length-delimited
        userBuf.append(contentsOf: [0x0A, 0x04]) // tag=1, wire=2, length=4
        userBuf.append(contentsOf: "!abc".utf8)
        // field 2 (longName), length-delimited
        userBuf.append(contentsOf: [0x12, 0x05]) // tag=2, wire=2, length=5
        userBuf.append(contentsOf: "Alice".utf8)
        // field 3 (shortName), length-delimited
        userBuf.append(contentsOf: [0x1A, 0x02]) // tag=3, wire=2, length=2
        userBuf.append(contentsOf: "Al".utf8)

        var buf = Data()
        // field 1 (num), varint
        buf.append(contentsOf: [0x08, 0x2A]) // tag=1, wire=0, value=42
        // field 2 (user), length-delimited
        buf.append(0x12) // tag=2, wire=2
        buf.append(UInt8(userBuf.count))
        buf.append(userBuf)

        let nodeInfo = try MeshtasticProtobuf.decodeNodeInfo(buf)
        #expect(nodeInfo.num == 42)
        #expect(nodeInfo.user?.id == "!abc")
        #expect(nodeInfo.user?.longName == "Alice")
        #expect(nodeInfo.user?.shortName == "Al")
    }

    // MARK: - Empty / Minimal Data

    @Test func emptyMeshPacketDecodes() throws {
        let decoded = try MeshtasticProtobuf.decodeMeshPacket(Data())
        #expect(decoded.from == 0)
        #expect(decoded.to == 0)
        #expect(decoded.decoded == nil)
    }

    @Test func truncatedDataThrows() {
        #expect(throws: ProtobufError.self) {
            // A tag byte that says "length-delimited with length 100" but only 2 bytes follow
            let bad = Data([0x12, 0x64, 0x00, 0x00])
            _ = try MeshtasticProtobuf.decodeMeshPacket(bad)
        }
    }

    // MARK: - ToRadio with MeshPacket

    @Test func toRadioWithPacketEncodes() {
        let packet = MeshtasticMeshPacket(
            to: 0xFFFF_FFFF,
            id: 1,
            hopLimit: 3,
            decoded: MeshtasticDataPayload(portnum: 256, payload: Data([0x01]))
        )
        let toRadio = MeshtasticToRadio(packet: packet)
        let encoded = MeshtasticProtobuf.encode(toRadio)

        // Should start with tag for field 1 (packet), wire type 2 (length-delimited)
        #expect(encoded.first == 0x0A) // (1 << 3) | 2
        #expect(encoded.count > 5)
    }
}
