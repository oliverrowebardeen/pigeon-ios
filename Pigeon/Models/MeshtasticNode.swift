import Foundation

/// A stock Meshtastic node discovered via BLE scan or mesh NodeInfo.
nonisolated struct MeshtasticNode: Identifiable, Hashable, Sendable {
    /// Meshtastic node number (unique per device)
    let id: UInt32

    var longName: String?
    var shortName: String?
    var rssi: Int?
    var lastSeen: Date
    var isConnected: Bool = false
}

/// Tracks how a peer is reachable for transport routing decisions.
nonisolated enum NodeConnectionType: Sendable {
    /// Phone-to-phone direct BLE
    case direct
    /// Pigeon ESP32 mesh node (full features)
    case pigeonNode
    /// Stock Meshtastic node (mesh-only, limited payload)
    case meshtasticNode
}
