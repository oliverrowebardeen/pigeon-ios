import CoreBluetooth
import Foundation

nonisolated enum BLEConstants {
    static let serviceUUID = CBUUID(string: "E1A71B10-9F11-4F1F-93F8-1A0D3A2B0001")
    static let messageCharUUID = CBUUID(string: "E1A71B10-9F11-4F1F-93F8-1A0D3A2B0002")
    static let identityCharUUID = CBUUID(string: "E1A71B10-9F11-4F1F-93F8-1A0D3A2B0003")
    static let ackCharUUID = CBUUID(string: "E1A71B10-9F11-4F1F-93F8-1A0D3A2B0004")
    static let bridgeControlCharUUID = CBUUID(string: "E1A71B10-9F11-4F1F-93F8-1A0D3A2B0005")
    static let reachabilityCharUUID = CBUUID(string: "E1A71B10-9F11-4F1F-93F8-1A0D3A2B0006")

    static let defaultTTL: UInt8 = 5
    static let reachabilityTTL: UInt8 = 3
    static let reachabilityBroadcastInterval: TimeInterval = 30
    static let reachabilityStaleTimeout: TimeInterval = 120
    static let connectionKeepAliveSeconds: TimeInterval = 30
    static let forwardingRetentionSeconds: TimeInterval = 3_600
    static let reassemblyTimeoutSeconds: TimeInterval = 30

    static let maxWriteLength = 512
    static let packetHeaderSize = 22
    static let maxChunkPayloadSize = 480
}
