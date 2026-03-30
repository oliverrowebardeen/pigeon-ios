import CoreBluetooth
import CryptoKit
import Foundation

protocol BLEManagerDelegate: AnyObject {
    func bleManager(_ manager: BLEManager, didReceiveEnvelope envelope: MessageEnvelope)
    func bleManager(_ manager: BLEManager, didReceiveBridgeFrame frame: BridgeControlFrame, from peerPublicKey: Data)
    func bleManager(_ manager: BLEManager, didDiscoverPeer peer: Peer)
    func bleManager(_ manager: BLEManager, didUpdatePeer peer: Peer)
    func bleManager(_ manager: BLEManager, didLosePeer publicKey: Data)
    func bleManager(_ manager: BLEManager, didDeliverMessage messageID: UUID)
    func bleManager(_ manager: BLEManager, didFailMessage messageID: UUID)
    func bleManager(_ manager: BLEManager, didReceiveReachability payload: PeerReachabilityPayload)
    func bleManager(_ manager: BLEManager, didRelayEnvelope envelope: MessageEnvelope)
    func bleManager(_ manager: BLEManager, didReceiveMeshPeers peers: [(pigeonID: String, publicKey: Data)], fromNodeWithPublicKey nodePublicKey: Data)
    func bleManager(_ manager: BLEManager, didReceiveMeshNodeBridgeStatus status: MeshNodeBridgeStatus, fromNodeWithPublicKey nodePublicKey: Data)
    func bleManagerDidUpdateState(_ manager: BLEManager)
}

final class BLEManager: NSObject {
    enum BridgeSendError: Error {
        case peerUnavailable
    }

    enum State: Equatable {
        case idle
        case starting
        case running
        case unauthorized
        case unsupported
        case poweredOff
    }

    private(set) var state: State = .idle

    // MARK: - Dependencies

    let identity: PigeonIdentity
    private let crypto: CryptoManager
    private let router: MeshRouter
    private let store: PigeonStore

    weak var delegate: BLEManagerDelegate?

    // MARK: - CoreBluetooth

    var centralManager: CBCentralManager!
    var peripheralManager: CBPeripheralManager!

    let bleQueue = DispatchQueue(label: "com.pigeon.ble", qos: .userInitiated)

    // MARK: - Peripheral role state

    var pigeonService: CBMutableService?
    var messageCharacteristic: CBMutableCharacteristic!
    var identityCharacteristic: CBMutableCharacteristic!
    var ackCharacteristic: CBMutableCharacteristic!
    var bridgeControlCharacteristic: CBMutableCharacteristic!
    var reachabilityCharacteristic: CBMutableCharacteristic!

    // MARK: - Central role state

    var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    var connectedPeripherals: [UUID: CBPeripheral] = [:]
    var peripheralPeerMap: [UUID: Data] = [:]
    var peerPeripheralMap: [Data: UUID] = [:]
    var peripheralMessageChars: [UUID: CBCharacteristic] = [:]
    var peripheralACKChars: [UUID: CBCharacteristic] = [:]
    var peripheralBridgeControlChars: [UUID: CBCharacteristic] = [:]
    var peripheralReachabilityChars: [UUID: CBCharacteristic] = [:]
    var peripheralIdentityChars: [UUID: CBCharacteristic] = [:]
    let reconnectDelaySeconds: TimeInterval = 1.0
    let reconnectAttemptIntervalSeconds: TimeInterval = 2.0
    var lastConnectAttemptAt: [UUID: Date] = [:]
    var backgroundConnectOptions: [String: Any] {
        [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ]
    }

    // MARK: - Reassembly

    var reassemblyBuffers: [UUID: ReassemblyBuffer] = [:]
    var bridgeReassemblyBuffers: [UUID: ReassemblyBuffer] = [:]
    var bridgePacketSources: [UUID: BridgePacketSource] = [:]
    private var reassemblyPurgeTimer: Timer?

    // MARK: - Nearby peers (live, in-memory)

    var nearbyPeers: [Data: Peer] = [:]
    var currentDisplayName: String?
    private var reachabilityBroadcastTimer: Timer?
    private var seenReachabilityAds: [ReachabilityAdID: Date] = [:]
    private(set) var hasInternetGateway = false
    var bridgeEnabled = true
    var bridgeRelayReachable = false
    var bridgeCapacityRemaining: Int?
    var bridgePeerCentrals: [Data: CBCentral] = [:]
    var subscribedBridgeCentrals: [UUID: CBCentral] = [:]
    var subscribedMessageCentrals: [UUID: CBCentral] = [:]
    var pendingMeshRegistrations: Set<UUID> = []
    var meshNodeDeviceIDs: Set<UUID> = []

    // MARK: - Lifecycle

    init(identity: PigeonIdentity, crypto: CryptoManager, router: MeshRouter, store: PigeonStore) {
        self.identity = identity
        self.crypto = crypto
        self.router = router
        self.store = store
        self.currentDisplayName = identity.displayName
        super.init()
    }

    enum BridgePacketSource {
        case peripheral(UUID)
        case central(CBCentral)
    }

    func start() {
        guard state == .idle else { return }
        state = .starting

        centralManager = CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.pigeon.central"
            ]
        )

        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: bleQueue,
            options: [
                CBPeripheralManagerOptionRestoreIdentifierKey: "com.pigeon.peripheral"
            ]
        )

        startReassemblyPurgeTimer()
        startReachabilityBroadcastTimer()
    }

    func stop() {
        reassemblyPurgeTimer?.invalidate()
        reassemblyPurgeTimer = nil
        reachabilityBroadcastTimer?.invalidate()
        reachabilityBroadcastTimer = nil

        if centralManager?.isScanning == true {
            centralManager.stopScan()
        }

        for (_, peripheral) in connectedPeripherals {
            centralManager.cancelPeripheralConnection(peripheral)
        }

        if peripheralManager?.isAdvertising == true {
            peripheralManager.stopAdvertising()
        }

        discoveredPeripherals.removeAll()
        connectedPeripherals.removeAll()
        peripheralPeerMap.removeAll()
        peerPeripheralMap.removeAll()
        peripheralMessageChars.removeAll()
        peripheralACKChars.removeAll()
        peripheralBridgeControlChars.removeAll()
        peripheralReachabilityChars.removeAll()
        peripheralIdentityChars.removeAll()
        pendingMeshRegistrations.removeAll()
        subscribedMessageCentrals.removeAll()
        meshNodeDeviceIDs.removeAll()
        lastConnectAttemptAt.removeAll()
        reassemblyBuffers.removeAll()
        bridgeReassemblyBuffers.removeAll()
        bridgePacketSources.removeAll()
        nearbyPeers.removeAll()
        seenReachabilityAds.removeAll()
        bridgePeerCentrals.removeAll()
        subscribedBridgeCentrals.removeAll()
        state = .idle
    }

    // MARK: - Outbound messaging

    func sendMessage(_ envelope: MessageEnvelope, to recipientPublicKey: Data) {
        Task {
            await router.enqueueOutbound(envelope)
        }

        bleQueue.async { [weak self] in
            self?.attemptDirectSend(envelope, to: recipientPublicKey)
        }
    }

    // MARK: - Internal: Scanning & Advertising

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        guard centralManager.isScanning == false else { return }
        centralManager.scanForPeripherals(
            withServices: [BLEConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func startAdvertising() {
        guard peripheralManager.state == .poweredOn else { return }
        guard peripheralManager.isAdvertising == false else { return }

        setupService()

        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BLEConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: currentDisplayName ?? "Pigeon"
        ])
    }

    func updateDisplayName(_ newValue: String?) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            currentDisplayName = newValue

            guard let peripheralManager, peripheralManager.state == .poweredOn else {
                return
            }

            if peripheralManager.isAdvertising {
                peripheralManager.stopAdvertising()
            }

            peripheralManager.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [BLEConstants.serviceUUID],
                CBAdvertisementDataLocalNameKey: currentDisplayName ?? "Pigeon"
            ])
        }
    }

    func updateInternetGatewayStatus(_ hasInternet: Bool) {
        bleQueue.async { [weak self] in
            guard let self, hasInternetGateway != hasInternet else { return }
            hasInternetGateway = hasInternet
            broadcastOwnReachability()
        }
    }

    func updateBridgeAvailability(enabled: Bool, relayReachable: Bool, capacityRemaining: Int?) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            guard bridgeEnabled != enabled ||
                bridgeRelayReachable != relayReachable ||
                bridgeCapacityRemaining != capacityRemaining
            else {
                return
            }
            bridgeEnabled = enabled
            bridgeRelayReachable = relayReachable
            bridgeCapacityRemaining = capacityRemaining
            broadcastBridgeStatusToPeers()
        }
    }

    func sendBridgeFrame(_ frame: BridgeControlFrame, to peerPublicKey: Data) throws {
        try bleQueue.sync {
            try sendBridgeFrameLocked(frame, to: peerPublicKey)
        }
    }

    private func sendBridgeFrameLocked(_ frame: BridgeControlFrame, to peerPublicKey: Data) throws {
        let envelope = try BridgeProtocol.encrypt(
            frame,
            using: crypto,
            senderPrivateKey: identity.privateKey,
            recipientPublicKey: peerPublicKey
        )
        let chunks = try MessageProtocol.chunkEnvelope(envelope)

        if let peripheralID = peerPeripheralMap[peerPublicKey],
           let peripheral = connectedPeripherals[peripheralID],
           let bridgeChar = peripheralBridgeControlChars[peripheralID] {
            sendChunks(chunks, to: peripheral, characteristic: bridgeChar)
            return
        }

        if let central = bridgePeerCentrals[peerPublicKey],
           let bridgeControlCharacteristic {
            for chunk in chunks {
                peripheralManager.updateValue(chunk, for: bridgeControlCharacteristic, onSubscribedCentrals: [central])
            }
            return
        }

        throw BridgeSendError.peerUnavailable
    }

    // MARK: - Mesh Node WiFi Provisioning

    func sendWiFiCredentials(ssid: String, password: String, toMeshNode peripheralID: UUID) {
        bleQueue.async { [weak self] in
            guard let self,
                  let peripheral = connectedPeripherals[peripheralID],
                  let bridgeChar = peripheralBridgeControlChars[peripheralID] else { return }

            let command: [String: String] = ["ssid": ssid, "pass": password]
            guard let data = try? JSONSerialization.data(withJSONObject: command) else { return }
            peripheral.writeValue(data, for: bridgeChar, type: .withResponse)
            print("[Pigeon] Sent WiFi credentials to mesh node \(peripheralID)")
        }
    }

    func peripheralID(forPeerPublicKey publicKey: Data) -> UUID? {
        bleQueue.sync { peerPeripheralMap[publicKey] }
    }

    func clearWiFiCredentials(forMeshNode peripheralID: UUID) {
        bleQueue.async { [weak self] in
            guard let self,
                  let peripheral = connectedPeripherals[peripheralID],
                  let bridgeChar = peripheralBridgeControlChars[peripheralID] else { return }

            let command: [String: String] = ["wifi": "off"]
            guard let data = try? JSONSerialization.data(withJSONObject: command) else { return }
            peripheral.writeValue(data, for: bridgeChar, type: .withResponse)
            print("[Pigeon] Sent WiFi disconnect to mesh node \(peripheralID)")
        }
    }

    func refreshPeerIdentity(peripheralID: UUID) {
        bleQueue.async { [weak self] in
            guard let self,
                  let peripheral = connectedPeripherals[peripheralID],
                  let identityChar = peripheralIdentityChars[peripheralID] else { return }
            peripheral.readValue(for: identityChar)
        }
    }

    func refreshRadioActivity(forceRestart: Bool = false) {
        bleQueue.async { [weak self] in
            guard let self else { return }

            if let centralManager, centralManager.state == .poweredOn {
                if forceRestart, centralManager.isScanning {
                    centralManager.stopScan()
                }
                startScanning()
                reconnectKnownPeripherals()
            }

            if let peripheralManager, peripheralManager.state == .poweredOn {
                if forceRestart, peripheralManager.isAdvertising {
                    peripheralManager.stopAdvertising()
                }
                startAdvertising()
            }
        }
    }

    private func reconnectKnownPeripherals() {
        guard let centralManager, centralManager.state == .poweredOn else { return }

        for peripheral in discoveredPeripherals.values where peripheral.state == .disconnected {
            connectToPeripheral(peripheral, using: centralManager)
        }
    }

    func connectToPeripheral(_ peripheral: CBPeripheral, using central: CBCentralManager) {
        let peripheralID = peripheral.identifier
        let now = Date()

        if let lastAttempt = lastConnectAttemptAt[peripheralID],
           now.timeIntervalSince(lastAttempt) < reconnectAttemptIntervalSeconds {
            return
        }

        lastConnectAttemptAt[peripheralID] = now
        central.connect(peripheral, options: backgroundConnectOptions)
    }

    private func setupService() {
        guard pigeonService == nil else { return }

        identityCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.identityCharUUID,
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )

        messageCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.messageCharUUID,
            properties: [.write, .writeWithoutResponse, .notify],
            value: nil,
            permissions: [.writeable]
        )

        ackCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.ackCharUUID,
            properties: [.write, .writeWithoutResponse, .notify],
            value: nil,
            permissions: [.writeable]
        )

        bridgeControlCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.bridgeControlCharUUID,
            properties: [.write, .writeWithoutResponse, .notify],
            value: nil,
            permissions: [.writeable]
        )

        reachabilityCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.reachabilityCharUUID,
            properties: [.read, .write, .writeWithoutResponse, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )

        let service = CBMutableService(type: BLEConstants.serviceUUID, primary: true)
        service.characteristics = [identityCharacteristic, messageCharacteristic, ackCharacteristic, bridgeControlCharacteristic, reachabilityCharacteristic]
        pigeonService = service
        peripheralManager.add(service)
    }

    // MARK: - Internal: Direct send

    private func attemptDirectSend(_ envelope: MessageEnvelope, to recipientPublicKey: Data) {
        let recipientHex = recipientPublicKey.prefix(4).map { String(format: "%02x", $0) }.joined()

        if let peripheralID = peerPeripheralMap[recipientPublicKey],
           let peripheral = connectedPeripherals[peripheralID],
           let messageChar = peripheralMessageChars[peripheralID] {
            print("[Pigeon BLE] Direct send to \(recipientHex) (peripheralID=\(peripheralID))")
            sendEnvelope(envelope, to: peripheral, characteristic: messageChar)
            return
        }

        // Check all connected peers for potential forwarding
        print("[Pigeon BLE] No direct connection to \(recipientHex), forwarding to \(connectedPeripherals.count) connected peers")
        for (peripheralID, peripheral) in connectedPeripherals {
            guard peripheralPeerMap[peripheralID] != recipientPublicKey,
                  let messageChar = peripheralMessageChars[peripheralID] else { continue }

            let peerKey = peripheralPeerMap[peripheralID]
            let peerHex = peerKey?.prefix(4).map { String(format: "%02x", $0) }.joined() ?? "unknown"
            let meshNode = isMeshNode(peripheralID: peripheralID)
            let peerIsMeshNode = peerKey.flatMap { nearbyPeers[$0]?.isMeshNode } ?? false
            print("[Pigeon BLE] Forwarding to peer \(peerHex) (peripheralID=\(peripheralID), isMeshNode=\(meshNode), peerIsMeshNode=\(peerIsMeshNode), inMeshNodeDeviceIDs=\(meshNodeDeviceIDs.contains(peripheralID)))")

            // Mesh nodes get the routing header so they can bridge to internet
            if meshNode {
                print("[Pigeon BLE] → Sending WITH routing header to mesh node \(peerHex)")
                sendEnvelopeWithRoutingHeader(envelope, to: peripheral, characteristic: messageChar, recipientPublicKey: recipientPublicKey)
            } else {
                print("[Pigeon BLE] → Sending WITHOUT routing header to \(peerHex)")
                sendEnvelope(envelope, to: peripheral, characteristic: messageChar)
            }
        }

        // Also broadcast to centrals connected via peripheral role (e.g. ESP32 nodes)
        broadcastEnvelopeToSubscribers(envelope)
    }

    private func isMeshNode(peripheralID: UUID) -> Bool {
        if meshNodeDeviceIDs.contains(peripheralID) {
            return true
        }
        guard let publicKey = peripheralPeerMap[peripheralID] else { return false }
        return nearbyPeers[publicKey]?.isMeshNode == true
    }

    private func sendEnvelopeWithRoutingHeader(
        _ envelope: MessageEnvelope,
        to peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        recipientPublicKey: Data
    ) {
        do {
            let chunks = try MessageProtocol.chunkEnvelopeWithRoutingHeader(
                envelope,
                recipientPublicKey: recipientPublicKey
            )
            sendChunks(chunks, to: peripheral, characteristic: characteristic)
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                delegate?.bleManager(self, didFailMessage: envelope.id)
            }
        }
    }

    func sendEnvelope(_ envelope: MessageEnvelope, to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        do {
            let chunks = try MessageProtocol.chunkEnvelope(envelope)
            sendChunks(chunks, to: peripheral, characteristic: characteristic)
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                delegate?.bleManager(self, didFailMessage: envelope.id)
            }
        }
    }

    private func sendChunks(_ chunks: [Data], to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        for chunk in chunks {
            peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
        }
    }

    private func broadcastBridgeStatusToPeers() {
        let frame = BridgeProtocol.status(
            bridgeEnabled: bridgeEnabled,
            relayReachable: bridgeRelayReachable,
            capacityRemaining: bridgeCapacityRemaining
        )

        for peerPublicKey in peerPeripheralMap.keys {
            try? sendBridgeFrameLocked(frame, to: peerPublicKey)
        }

        for peerPublicKey in bridgePeerCentrals.keys {
            try? sendBridgeFrameLocked(frame, to: peerPublicKey)
        }
    }

    // MARK: - Internal: Handle received envelope

    func handleReassembledData(_ data: Data) {
        do {
            let envelope = try MessageProtocol.decodeEnvelope(data)
            handleReceivedEnvelope(envelope)
        } catch {
            // Malformed envelope, drop silently
        }
    }

    private func handleReceivedEnvelope(_ envelope: MessageEnvelope) {
        Task {
            let isNew = await router.markSeen(envelope.id)
            guard isNew else { return }

            let myPublicKey = identity.publicKey.rawRepresentation

            if envelope.recipientPublicKey == myPublicKey {
                handleMessageForUs(envelope)
            } else {
                handleMessageForRelay(envelope)
            }
        }
    }

    private func handleMessageForUs(_ envelope: MessageEnvelope) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            delegate?.bleManager(self, didReceiveEnvelope: envelope)
        }
    }

    func sendACK(for envelope: MessageEnvelope) {
        sendACKForMessage(envelope)
    }

    private func handleMessageForRelay(_ envelope: MessageEnvelope) {
        guard let forwarded = MessageProtocol.incrementHopCountIfAllowed(envelope) else {
            return // TTL exceeded
        }

        Task {
            await router.storeForForwarding(forwarded)
        }

        bleQueue.async { [weak self] in
            guard let self else { return }
            for (peripheralID, peripheral) in connectedPeripherals {
                // Don't forward back to the sender
                if peripheralPeerMap[peripheralID] == envelope.senderPublicKey { continue }
                if let messageChar = peripheralMessageChars[peripheralID] {
                    if isMeshNode(peripheralID: peripheralID) {
                        sendEnvelopeWithRoutingHeader(
                            forwarded,
                            to: peripheral,
                            characteristic: messageChar,
                            recipientPublicKey: forwarded.recipientPublicKey
                        )
                    } else {
                        sendEnvelope(forwarded, to: peripheral, characteristic: messageChar)
                    }
                }
            }
        }

        // Also notify via peripheral manager to subscribed centrals
        broadcastEnvelopeToSubscribers(forwarded)

        // Notify delegate so gateway nodes can upload to relay
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            delegate?.bleManager(self, didRelayEnvelope: forwarded)
        }
    }

    private func sendACKForMessage(_ envelope: MessageEnvelope) {
        let ack = DeliveryACK(
            messageID: envelope.id,
            senderPublicKey: identity.publicKey.rawRepresentation,
            timestamp: Date()
        )

        do {
            let ackData = try MessageProtocol.encodeACK(ack)
            bleQueue.async { [weak self] in
                guard let self else { return }

                // Send ACK to the peer we received from
                // Try direct connection first
                if let peripheralID = peerPeripheralMap[envelope.senderPublicKey],
                   let peripheral = connectedPeripherals[peripheralID],
                   let ackChar = peripheralACKChars[peripheralID] {
                    peripheral.writeValue(ackData, for: ackChar, type: .withResponse)
                }

                // Also broadcast via peripheral role
                if let ackChar = ackCharacteristic {
                    peripheralManager.updateValue(ackData, for: ackChar, onSubscribedCentrals: nil)
                }
            }
        } catch {
            // ACK encoding failed, not critical
        }
    }

    func handleReceivedACK(_ data: Data) {
        do {
            let ack = try MessageProtocol.decodeACK(data)
            Task {
                await router.acknowledgeDelivery(ack.messageID)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                delegate?.bleManager(self, didDeliverMessage: ack.messageID)
            }
        } catch {
            // Malformed ACK, ignore
        }
    }

    private func broadcastEnvelopeToSubscribers(_ envelope: MessageEnvelope) {
        // Separate mesh node centrals (need routing header) from regular centrals
        var meshCentrals: [CBCentral] = []
        var regularCentrals: [CBCentral] = []

        for (centralID, central) in subscribedMessageCentrals {
            if meshNodeDeviceIDs.contains(centralID) {
                meshCentrals.append(central)
            } else {
                regularCentrals.append(central)
            }
        }

        do {
            if !regularCentrals.isEmpty {
                let chunks = try MessageProtocol.chunkEnvelope(envelope)
                for chunk in chunks {
                    peripheralManager.updateValue(chunk, for: messageCharacteristic, onSubscribedCentrals: regularCentrals)
                }
            }

            if !meshCentrals.isEmpty {
                let chunks = try MessageProtocol.chunkEnvelopeWithRoutingHeader(
                    envelope,
                    recipientPublicKey: envelope.recipientPublicKey
                )
                for chunk in chunks {
                    peripheralManager.updateValue(chunk, for: messageCharacteristic, onSubscribedCentrals: meshCentrals)
                }
            }
        } catch {
            // Chunking failed
        }
    }

    // MARK: - Internal: Chunk reassembly

    func processIncomingChunk(_ data: Data) {
        do {
            let packet = try MessageProtocol.decodePacket(data)
            let header = packet.header

            let buffer: ReassemblyBuffer
            if let existing = reassemblyBuffers[header.messageID] {
                buffer = existing
            } else {
                buffer = ReassemblyBuffer(
                    messageID: header.messageID,
                    expectedChunkCount: header.totalChunks
                )
                reassemblyBuffers[header.messageID] = buffer
            }

            let complete = buffer.addChunk(index: header.chunkIndex, data: data)

            if complete {
                reassemblyBuffers.removeValue(forKey: header.messageID)
                let packetData = buffer.assembledPacketData()
                do {
                    let payload = try MessageProtocol.reassemblePayload(from: packetData)
                    handleReassembledData(payload)
                } catch {
                    // Reassembly failed
                }
            }
        } catch {
            // Malformed packet
        }
    }

    func processIncomingBridgeChunk(_ data: Data, source: BridgePacketSource) {
        // Try plain JSON first (mesh node protocol)
        if handleMeshNodeMessage(data, source: source) {
            return
        }

        do {
            let packet = try MessageProtocol.decodePacket(data)
            let header = packet.header

            let buffer: ReassemblyBuffer
            if let existing = bridgeReassemblyBuffers[header.messageID] {
                buffer = existing
            } else {
                buffer = ReassemblyBuffer(messageID: header.messageID, expectedChunkCount: header.totalChunks)
                bridgeReassemblyBuffers[header.messageID] = buffer
                bridgePacketSources[header.messageID] = source
            }

            let complete = buffer.addChunk(index: header.chunkIndex, data: data)

            if complete {
                bridgeReassemblyBuffers.removeValue(forKey: header.messageID)
                let source = bridgePacketSources.removeValue(forKey: header.messageID)
                let packetData = buffer.assembledPacketData()

                do {
                    let payload = try MessageProtocol.reassemblePayload(from: packetData)
                    handleReassembledBridgeData(payload, source: source)
                } catch {
                    // Drop malformed bridge payloads.
                }
            }
        } catch {
            // Drop malformed bridge chunks.
        }
    }

    // MARK: - Mesh Node Protocol

    /// Handles plain JSON messages from ESP32 mesh nodes on bridge control.
    /// Returns true if the data was a mesh node message, false to fall through to chunked processing.
    private func handleMeshNodeMessage(_ data: Data, source: BridgePacketSource) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        // Firmware bridge_status notifications omit "type" — infer from "bridge" key
        let type: String
        if let explicit = json["type"] as? String {
            type = explicit
        } else if json["bridge"] is String {
            type = "bridge_status"
        } else {
            return false
        }

        // Resolve the node's public key on bleQueue (current queue) to avoid data race
        let peripheralID: UUID?
        if case .peripheral(let id) = source { peripheralID = id } else { peripheralID = nil }

        switch type {
        case "peers":
            guard let peersArray = json["peers"] as? [[String: String]] else {
                print("[Pigeon] Malformed mesh node 'peers' message: missing peers array")
                return true
            }
            guard let peripheralID,
                  let nodePublicKey = peripheralPeerMap[peripheralID] else { return true }

            var parsedPeers: [(pigeonID: String, publicKey: Data)] = []
            for peerObj in peersArray {
                guard let pigeonID = peerObj["pigeonID"],
                      let publicKeyBase64 = peerObj["publicKey"],
                      let publicKeyData = Data(base64Encoded: publicKeyBase64),
                      publicKeyData.count == 32,
                      let _ = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData) else {
                    continue
                }
                parsedPeers.append((pigeonID: pigeonID, publicKey: publicKeyData))
            }

            print("[Pigeon] Mesh node \(peripheralID) reports \(parsedPeers.count) peers")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                delegate?.bleManager(self, didReceiveMeshPeers: parsedPeers, fromNodeWithPublicKey: nodePublicKey)
            }

        case "bridge_status":
            guard let bridge = json["bridge"] as? String else {
                print("[Pigeon] Malformed mesh node 'bridge_status': missing bridge field")
                return true
            }
            guard let peripheralID,
                  let nodePublicKey = peripheralPeerMap[peripheralID] else { return true }

            let status = MeshNodeBridgeStatus(
                bridge: bridge,
                ssid: json["ssid"] as? String,
                ip: json["ip"] as? String,
                capacityRemaining: json["capacity_remaining"] as? Int ?? json["bridgeCapacityRemaining"] as? Int
            )
            print("[Pigeon] Mesh node \(peripheralID) bridge status: \(bridge)")

            // Update the peer's bridge state
            if var peer = nearbyPeers[nodePublicKey] {
                peer.relayReachable = status.isOnline
                peer.bridgeEnabled = status.bridge != "no_wifi"
                peer.bridgeState = status.bridge
                peer.bridgeCapacityRemaining = status.capacityRemaining ?? peer.bridgeCapacityRemaining
                nearbyPeers[nodePublicKey] = peer
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    delegate?.bleManager(self, didUpdatePeer: peer)
                    delegate?.bleManager(self, didReceiveMeshNodeBridgeStatus: status, fromNodeWithPublicKey: nodePublicKey)
                }
            }

        default:
            print("[Pigeon] Unknown mesh node message type: \(type)")
        }

        return true
    }

    /// Registers this device's pigeonID with a mesh node after connecting.
    /// Called from BLEManager+Central after identity handshake with a mesh node.
    func registerWithMeshNode(peripheralID: UUID) {
        bleQueue.async { [weak self] in
            guard let self,
                  let peripheral = connectedPeripherals[peripheralID],
                  let bridgeChar = peripheralBridgeControlChars[peripheralID] else { return }

            let publicKeyBase64 = identity.publicKey.rawRepresentation.base64EncodedString()
            let message: [String: String] = [
                "type": "register",
                "pigeonID": identity.pigeonID,
                "publicKey": publicKeyBase64
            ]

            guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
            peripheral.writeValue(data, for: bridgeChar, type: .withResponse)
            print("[Pigeon] Registered with mesh node \(peripheralID) (pigeonID: \(identity.pigeonID), publicKey included)")
        }
    }

    private func handleReassembledBridgeData(_ data: Data, source: BridgePacketSource?) {
        do {
            let envelope = try MessageProtocol.decodeEnvelope(data)
            guard envelope.recipientPublicKey == identity.publicKey.rawRepresentation else {
                return
            }

            let frame = try BridgeProtocol.decrypt(
                envelope,
                using: crypto,
                recipientPrivateKey: identity.privateKey
            )

            if case .central(let central) = source {
                bridgePeerCentrals[envelope.senderPublicKey] = central
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                delegate?.bleManager(self, didReceiveBridgeFrame: frame, from: envelope.senderPublicKey)
            }
        } catch {
            // Drop malformed bridge frames.
        }
    }

    // MARK: - Internal: Send pending messages to newly connected peer

    func sendPendingMessages(toPeerWithPublicKey peerPublicKey: Data, peripheralID: UUID) {
        Task {
            let pending = await router.outboundMessages(for: peerPublicKey)
            let forwardable = await router.forwardableMessages()

            bleQueue.async { [weak self] in
                guard let self,
                      let peripheral = connectedPeripherals[peripheralID],
                      let messageChar = peripheralMessageChars[peripheralID] else { return }

                let meshNode = isMeshNode(peripheralID: peripheralID)

                for envelope in pending {
                    if meshNode {
                        sendEnvelopeWithRoutingHeader(envelope, to: peripheral, characteristic: messageChar, recipientPublicKey: envelope.recipientPublicKey)
                    } else {
                        sendEnvelope(envelope, to: peripheral, characteristic: messageChar)
                    }
                }

                for envelope in forwardable {
                    if envelope.senderPublicKey == peerPublicKey { continue }
                    if envelope.recipientPublicKey == peerPublicKey ||
                       envelope.hopCount < envelope.ttl {
                        if meshNode {
                            sendEnvelopeWithRoutingHeader(envelope, to: peripheral, characteristic: messageChar, recipientPublicKey: envelope.recipientPublicKey)
                        } else {
                            sendEnvelope(envelope, to: peripheral, characteristic: messageChar)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Internal: Reassembly purge timer

    private func startReassemblyPurgeTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.reassemblyPurgeTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                self?.bleQueue.async {
                    self?.purgeExpiredBuffers()
                }
            }
        }
    }

    private func purgeExpiredBuffers() {
        reassemblyBuffers = reassemblyBuffers.filter { !$0.value.isExpired }
        bridgeReassemblyBuffers = bridgeReassemblyBuffers.filter { !$0.value.isExpired }
        let adCutoff = Date().addingTimeInterval(-BLEConstants.reachabilityStaleTimeout)
        seenReachabilityAds = seenReachabilityAds.filter { $0.value > adCutoff }
    }

    // MARK: - Reachability broadcast

    private func startReachabilityBroadcastTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.reachabilityBroadcastTimer = Timer.scheduledTimer(
                withTimeInterval: BLEConstants.reachabilityBroadcastInterval,
                repeats: true
            ) { [weak self] _ in
                self?.bleQueue.async {
                    self?.broadcastOwnReachability()
                }
            }
        }
    }

    func broadcastOwnReachability() {
        let peerKeys = Array(nearbyPeers.keys)
        let payload = PeerReachabilityPayload(
            senderPublicKey: identity.publicKey.rawRepresentation,
            reachablePeers: peerKeys,
            hasInternetGateway: hasInternetGateway,
            hopCount: 0,
            ttl: BLEConstants.reachabilityTTL,
            timestamp: Date()
        )

        guard let data = try? MessageProtocol.encodeReachability(payload) else { return }

        // Update characteristic value for future reads
        reachabilityCharacteristic?.value = data

        // Notify subscribed centrals (peripheral role)
        if let reachChar = reachabilityCharacteristic, peripheralManager?.state == .poweredOn {
            peripheralManager.updateValue(data, for: reachChar, onSubscribedCentrals: nil)
        }

        // Write to connected peripherals (central role)
        for (peripheralID, peripheral) in connectedPeripherals {
            if let reachChar = peripheralReachabilityChars[peripheralID] {
                peripheral.writeValue(data, for: reachChar, type: .withResponse)
            }
        }
    }

    func handleReceivedReachability(_ data: Data, fromPeerID senderPeripheralID: UUID?) {
        guard let payload = try? MessageProtocol.decodeReachability(data) else { return }

        let adID = ReachabilityAdID(senderPublicKey: payload.senderPublicKey, timestamp: payload.timestamp)
        guard seenReachabilityAds[adID] == nil else { return }
        seenReachabilityAds[adID] = Date()

        // Notify delegate
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            delegate?.bleManager(self, didReceiveReachability: payload)
        }

        // Forward if within TTL
        guard payload.hopCount < payload.ttl else { return }
        var forwarded = payload
        forwarded.hopCount += 1
        guard let forwardedData = try? MessageProtocol.encodeReachability(forwarded) else { return }

        // Forward to connected peripherals (central role), except source
        for (peripheralID, peripheral) in connectedPeripherals {
            if peripheralID == senderPeripheralID { continue }
            if let reachChar = peripheralReachabilityChars[peripheralID] {
                peripheral.writeValue(forwardedData, for: reachChar, type: .withResponse)
            }
        }

        // Forward to subscribed centrals (peripheral role)
        if let reachChar = reachabilityCharacteristic, peripheralManager?.state == .poweredOn {
            peripheralManager.updateValue(forwardedData, for: reachChar, onSubscribedCentrals: nil)
        }
    }

    // MARK: - Internal: State update

    func updateState() {
        let centralState = centralManager?.state ?? .unknown
        let peripheralState = peripheralManager?.state ?? .unknown

        let newState: State
        if centralState == .unauthorized || peripheralState == .unauthorized {
            newState = .unauthorized
        } else if centralState == .unsupported || peripheralState == .unsupported {
            newState = .unsupported
        } else if centralState == .poweredOff || peripheralState == .poweredOff {
            newState = .poweredOff
        } else if centralState == .poweredOn && peripheralState == .poweredOn {
            newState = .running
        } else {
            newState = .starting
        }

        if newState != state {
            state = newState
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                delegate?.bleManagerDidUpdateState(self)
            }
        }
    }
}

nonisolated struct MeshNodeBridgeStatus: Sendable {
    let bridge: String    // "online", "connecting", "auth", "offline", "no_wifi"
    let ssid: String?
    let ip: String?
    let capacityRemaining: Int?

    var isOnline: Bool { bridge == "online" }
    var isConnecting: Bool { bridge == "connecting" }
}

nonisolated struct ReachabilityAdID: Hashable, Sendable {
    let senderPublicKey: Data
    let timestamp: Date
}
