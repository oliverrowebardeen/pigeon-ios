import CoreBluetooth
import CryptoKit
import Foundation

protocol BLEManagerDelegate: AnyObject {
    func bleManager(_ manager: BLEManager, didReceiveMessage message: Message, inConversation conversationID: UUID)
    func bleManager(_ manager: BLEManager, didDiscoverPeer peer: Peer)
    func bleManager(_ manager: BLEManager, didUpdatePeer peer: Peer)
    func bleManager(_ manager: BLEManager, didLosePeer pigeonID: String)
    func bleManager(_ manager: BLEManager, didDeliverMessage messageID: UUID)
    func bleManager(_ manager: BLEManager, didFailMessage messageID: UUID)
    func bleManagerDidUpdateState(_ manager: BLEManager)
}

final class BLEManager: NSObject {
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

    // MARK: - Central role state

    var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    var connectedPeripherals: [UUID: CBPeripheral] = [:]
    var peripheralPeerMap: [UUID: Data] = [:]
    var peerPeripheralMap: [Data: UUID] = [:]
    var peripheralMessageChars: [UUID: CBCharacteristic] = [:]
    var peripheralACKChars: [UUID: CBCharacteristic] = [:]

    // MARK: - Reassembly

    var reassemblyBuffers: [UUID: ReassemblyBuffer] = [:]
    private var reassemblyPurgeTimer: Timer?

    // MARK: - Nearby peers (live, in-memory)

    var nearbyPeers: [Data: Peer] = [:]

    // MARK: - Lifecycle

    init(identity: PigeonIdentity, crypto: CryptoManager, router: MeshRouter, store: PigeonStore) {
        self.identity = identity
        self.crypto = crypto
        self.router = router
        self.store = store
        super.init()
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
    }

    func stop() {
        reassemblyPurgeTimer?.invalidate()
        reassemblyPurgeTimer = nil

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
        reassemblyBuffers.removeAll()
        nearbyPeers.removeAll()
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
        centralManager.scanForPeripherals(
            withServices: [BLEConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func startAdvertising() {
        guard peripheralManager.state == .poweredOn else { return }

        setupService()

        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BLEConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: identity.displayName ?? "Pigeon"
        ])
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

        let service = CBMutableService(type: BLEConstants.serviceUUID, primary: true)
        service.characteristics = [identityCharacteristic, messageCharacteristic, ackCharacteristic]
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
        do {
            let plaintext = try crypto.decryptToString(
                envelope: envelope,
                recipientPrivateKey: identity.privateKey
            )

            let senderPigeonID = PigeonIdentity.makePigeonID(
                fromPublicKeyData: envelope.senderPublicKey
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                let peer = Peer(
                    publicKey: envelope.senderPublicKey,
                    pigeonID: senderPigeonID,
                    displayName: nearbyPeers[envelope.senderPublicKey]?.displayName,
                    firstSeen: Date(),
                    lastSeen: Date(),
                    isSaved: false
                )

                let conversation: Conversation
                do {
                    conversation = try store.getOrCreateConversation(for: peer)
                } catch {
                    return
                }

                let message = Message(
                    id: envelope.id,
                    conversationID: conversation.id,
                    senderPublicKey: envelope.senderPublicKey,
                    recipientPublicKey: envelope.recipientPublicKey,
                    plaintext: plaintext,
                    timestamp: envelope.timestamp,
                    status: .delivered,
                    isIncoming: true
                )

                delegate?.bleManager(self, didReceiveMessage: message, inConversation: conversation.id)
            }

            // Send ACK back through the mesh
            sendACKForMessage(envelope)
        } catch {
            // Decryption failed — message wasn't for us or is corrupted
        }
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

    // MARK: - Internal: Send pending messages to newly connected peer

    func sendPendingMessages(toPeerWithPublicKey peerPublicKey: Data, peripheralID: UUID) {
        Task {
            let pending = await router.dequeueOutbound(for: peerPublicKey)
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
