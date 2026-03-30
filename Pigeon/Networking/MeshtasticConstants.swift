import CoreBluetooth
import Foundation

nonisolated enum MeshtasticConstants {
    // MARK: - BLE Service & Characteristics

    /// Meshtastic BLE service UUID
    static let serviceUUID = CBUUID(string: "6ba1b218-15a8-461f-9fa8-5dcae273eafd")

    /// Phone reads decoded protobuf packets from this characteristic
    static let fromRadioCharUUID = CBUUID(string: "2c55e69e-4993-11ed-b878-0242ac120002")

    /// Phone writes encoded protobuf packets to this characteristic
    static let toRadioCharUUID = CBUUID(string: "f75c76d2-129e-4dad-a1dd-7866124401e7")

    /// Notifies phone that new data is available to read from FromRadio
    static let fromNumCharUUID = CBUUID(string: "ed9da18c-a800-4f66-a670-aa7547e34453")

    // MARK: - Pigeon Protocol

    /// Meshtastic portnum for Pigeon private app data (PRIVATE_APP = 256)
    static let pigeonPortnum: UInt32 = 256

    /// BLE framing marker prepended to ToRadio writes (sent big-endian / network byte order)
    static let bleFramingMarker: UInt16 = 0x94C3

    /// Broadcast destination address — all nodes relay
    static let broadcastAddress: UInt32 = 0xFFFF_FFFF

    /// Default hop limit for Pigeon packets
    static let defaultHopLimit: UInt32 = 3

    // MARK: - LoRa Constraints

    /// Maximum LoRa payload size in bytes (conservative for LongFast)
    static let maxLoRaPayloadSize = 230

    /// Maximum Pigeon ciphertext after compact envelope overhead
    static let maxDirectCiphertextSize = 120

    /// Maximum Pigeon ciphertext for group broadcast
    static let maxGroupCiphertextSize = 150

    // MARK: - Connection

    /// Config handshake timeout
    static let configHandshakeTimeoutSeconds: TimeInterval = 10
}
