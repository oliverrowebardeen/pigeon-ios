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
    var bridgeEnabled = true
    var bridgeRelayReachable = false
    var bridgeCapacityRemaining: Int?
    var bridgePeerCentrals: [Data: CBCentral] = [:]
    var subscribedBridgeCentrals: [UUID: CBCentral] = [:]

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
        if let peripheralID = peerPeripheralMap[recipientPublicKey],
           let peripheral = connectedPeripherals[peripheralID],
           let messageChar = peripheralMessageChars[peripheralID] {
            sendEnvelope(envelope, to: peripheral, characteristic: messageChar)
            return
        }

        // Check all connected peers for potential forwarding
        for (peripheralID, peripheral) in connectedPeripherals {
            guard peripheralPeerMap[peripheralID] != recipientPublicKey,
                  let messageChar = peripheralMessageChars[peripheralID] else { continue }
            sendEnvelope(envelope, to: peripheral, characteristic: messageChar)
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
                    sendEnvelope(forwarded, to: peripheral, characteristic: messageChar)
                }
            }
        }

        // Also notify via peripheral manager to subscribed centrals
        broadcastEnvelopeToSubscribers(forwarded)
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
        do {
            let chunks = try MessageProtocol.chunkEnvelope(envelope)
            for chunk in chunks {
                peripheralManager.updateValue(chunk, for: messageCharacteristic, onSubscribedCentrals: nil)
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

                for envelope in pending {
                    sendEnvelope(envelope, to: peripheral, characteristic: messageChar)
                }

                for envelope in forwardable {
                    if envelope.senderPublicKey == peerPublicKey { continue }
                    if envelope.recipientPublicKey == peerPublicKey ||
                       envelope.hopCount < envelope.ttl {
                        sendEnvelope(envelope, to: peripheral, characteristic: messageChar)
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

nonisolated struct ReachabilityAdID: Hashable, Sendable {
    let senderPublicKey: Data
    let timestamp: Date
}
