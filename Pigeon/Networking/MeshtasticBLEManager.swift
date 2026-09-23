import CoreBluetooth
import Foundation

// MARK: - Delegate Protocol

protocol MeshtasticBLEManagerDelegate: AnyObject {
    /// A Meshtastic node was found during BLE scanning
    func meshtasticManager(_ manager: MeshtasticBLEManager, didDiscoverNode node: MeshtasticNode)

    /// Connected to a Meshtastic node and config handshake completed
    func meshtasticManager(_ manager: MeshtasticBLEManager, didConnectToNode node: MeshtasticNode)

    /// Disconnected from a Meshtastic node
    func meshtasticManager(_ manager: MeshtasticBLEManager, didDisconnectFromNode node: MeshtasticNode)

    /// Received a Pigeon-portnum payload from the Meshtastic mesh
    func meshtasticManager(_ manager: MeshtasticBLEManager, didReceivePigeonEnvelope data: Data, fromMeshtasticNodeNum: UInt32)

    /// Received updated node list from mesh topology (NodeInfo messages)
    func meshtasticManager(_ manager: MeshtasticBLEManager, didUpdateNodeList nodes: [MeshtasticNode])

    /// BLE state changed
    func meshtasticManagerDidUpdateState(_ manager: MeshtasticBLEManager)
}

// MARK: - Manager

final class MeshtasticBLEManager: NSObject {

    enum State: Equatable {
        case idle
        case scanning
        case connecting
        case configuring  // Config handshake in progress
        case connected
        case unauthorized
        case unsupported
        case poweredOff
    }

    // MARK: - Public State

    private(set) var state: State = .idle
    private(set) var discoveredNodes: [UInt32: MeshtasticNode] = [:]
    private(set) var connectedNode: MeshtasticNode?
    private(set) var myNodeNum: UInt32 = 0

    weak var delegate: MeshtasticBLEManagerDelegate?

    // MARK: - CoreBluetooth

    private var centralManager: CBCentralManager!
    private let bleQueue = DispatchQueue(label: "com.pigeon.meshtastic.ble", qos: .userInitiated)

    // MARK: - Connected Peripheral State

    private var connectedPeripheral: CBPeripheral?
    private var fromRadioChar: CBCharacteristic?
    private var toRadioChar: CBCharacteristic?
    private var fromNumChar: CBCharacteristic?

    // MARK: - Config Handshake

    private var configRequestID: UInt32 = 0
    private var configHandshakeTimer: Timer?
    private var isConfigComplete = false
    private var drainReadsRemaining = 0
    private static let maxDrainReads = 50

    // MARK: - Discovered Peripherals (for reconnection)

    private var peripheralNodeMap: [UUID: UInt32] = [:]  // CBPeripheral.identifier → node num
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]

    // MARK: - Lifecycle

    func start() {
        guard centralManager == nil else { return }
        centralManager = CBCentralManager(delegate: self, queue: bleQueue, options: [
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

    func stop() {
        stopScanning()
        if let peripheral = connectedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        connectedNode = nil
        configHandshakeTimer?.invalidate()
        configHandshakeTimer = nil
        updateState(.idle)
    }

    // MARK: - Scanning

    func startScanning() {
        guard centralManager?.state == .poweredOn else { return }
        centralManager.scanForPeripherals(
            withServices: [MeshtasticConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        if state == .idle || state == .scanning {
            updateState(.scanning)
        }
    }

    func stopScanning() {
        centralManager?.stopScan()
    }

    // MARK: - Connection

    func connect(to node: MeshtasticNode) {
        guard let peripheral = discoveredPeripherals.values.first(where: { peripheral in
            peripheralNodeMap[peripheral.identifier] == node.id
        }) else { return }

        // Disconnect existing if different
        if let existing = connectedPeripheral, existing.identifier != peripheral.identifier {
            centralManager.cancelPeripheralConnection(existing)
        }

        updateState(.connecting)
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
        ])
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        // Send disconnect ToRadio
        let disconnectMsg = MeshtasticToRadio(disconnect: true)
        let encoded = MeshtasticProtobuf.encode(disconnectMsg)
        writeToRadio(encoded, on: peripheral)
        centralManager.cancelPeripheralConnection(peripheral)
    }

    // MARK: - Sending Pigeon Data

    /// Sends a Pigeon compact envelope through the connected Meshtastic node.
    func sendPigeonPayload(_ payload: Data) -> Bool {
        guard let peripheral = connectedPeripheral, toRadioChar != nil, isConfigComplete else {
            return false
        }

        let data = MeshtasticDataPayload(
            portnum: MeshtasticConstants.pigeonPortnum,
            payload: payload
        )

        let meshPacket = MeshtasticMeshPacket(
            to: MeshtasticConstants.broadcastAddress,
            id: UInt32.random(in: 1 ... UInt32.max),
            hopLimit: MeshtasticConstants.defaultHopLimit,
            wantAck: false,
            decoded: data
        )

        let toRadioMsg = MeshtasticToRadio(packet: meshPacket)
        let encoded = MeshtasticProtobuf.encode(toRadioMsg)
        writeToRadio(encoded, on: peripheral)
        return true
    }

    // MARK: - Private: BLE Write with Framing

    private func writeToRadio(_ protobufData: Data, on peripheral: CBPeripheral) {
        guard let char = toRadioChar else { return }

        // Meshtastic BLE framing: 2-byte marker + 2-byte length + protobuf
        var framed = Data(capacity: 4 + protobufData.count)
        var marker = MeshtasticConstants.bleFramingMarker.bigEndian
        framed.append(Data(bytes: &marker, count: 2))
        var length = UInt16(protobufData.count).bigEndian
        framed.append(Data(bytes: &length, count: 2))
        framed.append(protobufData)

        peripheral.writeValue(framed, for: char, type: .withResponse)
    }

    // MARK: - Private: Config Handshake

    private func beginConfigHandshake(_ peripheral: CBPeripheral) {
        configRequestID = UInt32.random(in: 1 ... UInt32.max)
        isConfigComplete = false

        let toRadioMsg = MeshtasticToRadio(wantConfigID: configRequestID)
        let encoded = MeshtasticProtobuf.encode(toRadioMsg)
        writeToRadio(encoded, on: peripheral)

        updateState(.configuring)

        // Timeout
        DispatchQueue.main.async { [weak self] in
            self?.configHandshakeTimer?.invalidate()
            self?.configHandshakeTimer = Timer.scheduledTimer(
                withTimeInterval: MeshtasticConstants.configHandshakeTimeoutSeconds,
                repeats: false
            ) { [weak self] _ in
                guard let self, !self.isConfigComplete else { return }
                print("[Meshtastic] Config handshake timed out")
                if let p = self.connectedPeripheral {
                    self.centralManager.cancelPeripheralConnection(p)
                }
            }
        }
    }

    private func handleFromRadio(_ data: Data) {
        guard let fromRadio = try? MeshtasticProtobuf.decodeFromRadio(data) else {
            print("[Meshtastic] Failed to decode FromRadio (\(data.count) bytes)")
            return
        }

        // Config complete?
        if let completeID = fromRadio.configCompleteID, completeID == configRequestID {
            isConfigComplete = true
            configHandshakeTimer?.invalidate()
            configHandshakeTimer = nil
            updateState(.connected)

            if var node = connectedNode {
                node.isConnected = true
                connectedNode = node
                discoveredNodes[node.id] = node
                delegate?.meshtasticManager(self, didConnectToNode: node)
            }
            return
        }

        // MyNodeInfo — learn our own node number
        if let myInfo = fromRadio.myInfo {
            myNodeNum = myInfo.myNodeNum
        }

        // NodeInfo — mesh topology update
        if let nodeInfo = fromRadio.nodeInfo {
            var node = discoveredNodes[nodeInfo.num] ?? MeshtasticNode(
                id: nodeInfo.num,
                lastSeen: Date()
            )
            if let user = nodeInfo.user {
                node.longName = user.longName.isEmpty ? nil : user.longName
                node.shortName = user.shortName.isEmpty ? nil : user.shortName
            }
            node.lastSeen = Date()
            discoveredNodes[node.id] = node
            delegate?.meshtasticManager(self, didUpdateNodeList: Array(discoveredNodes.values))
        }

        // MeshPacket with Pigeon portnum
        if let packet = fromRadio.packet, let decoded = packet.decoded {
            if decoded.portnum == MeshtasticConstants.pigeonPortnum && !decoded.payload.isEmpty {
                delegate?.meshtasticManager(
                    self,
                    didReceivePigeonEnvelope: decoded.payload,
                    fromMeshtasticNodeNum: packet.from
                )
            }
            // Non-Pigeon portnums are intentionally ignored.
        }
    }

    // MARK: - Private: Read Loop

    /// After FromNum notification, read all available FromRadio packets.
    private func drainFromRadio(_ peripheral: CBPeripheral) {
        guard let char = fromRadioChar else { return }
        drainReadsRemaining = Self.maxDrainReads
        peripheral.readValue(for: char)
    }

    // MARK: - Private: State Update

    private func updateState(_ newState: State) {
        state = newState
        delegate?.meshtasticManagerDidUpdateState(self)
    }
}

// MARK: - CBCentralManagerDelegate

extension MeshtasticBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanning()
        case .unauthorized:
            updateState(.unauthorized)
        case .unsupported:
            updateState(.unsupported)
        case .poweredOff:
            updateState(.poweredOff)
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let rssiValue = RSSI.intValue
        guard rssiValue != 127 else { return }  // Invalid RSSI

        discoveredPeripherals[peripheral.identifier] = peripheral

        // If we already know this peripheral's node num, update it
        if let nodeNum = peripheralNodeMap[peripheral.identifier] {
            if var existing = discoveredNodes[nodeNum] {
                existing.rssi = rssiValue
                existing.lastSeen = Date()
                discoveredNodes[nodeNum] = existing
                delegate?.meshtasticManager(self, didDiscoverNode: existing)
            }
        } else {
            // New peripheral — we don't know the node num yet.
            // Derive a stable temporary ID from the first 4 bytes of the CBPeripheral UUID.
            let uuid = peripheral.identifier.uuid
            let tempNum = UInt32(uuid.0) << 24 | UInt32(uuid.1) << 16 | UInt32(uuid.2) << 8 | UInt32(uuid.3)
            peripheralNodeMap[peripheral.identifier] = tempNum

            let node = MeshtasticNode(
                id: tempNum,
                longName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
                rssi: rssiValue,
                lastSeen: Date()
            )
            discoveredNodes[tempNum] = node
            delegate?.meshtasticManager(self, didDiscoverNode: node)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([MeshtasticConstants.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[Meshtastic] Failed to connect: \(error?.localizedDescription ?? "unknown")")
        updateState(.scanning)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let wasConnected = connectedPeripheral?.identifier == peripheral.identifier

        if wasConnected {
            let node = connectedNode
            connectedPeripheral = nil
            connectedNode = nil
            fromRadioChar = nil
            toRadioChar = nil
            fromNumChar = nil
            isConfigComplete = false
            configHandshakeTimer?.invalidate()
            configHandshakeTimer = nil

            if let node {
                var updated = node
                updated.isConnected = false
                discoveredNodes[node.id] = updated
                delegate?.meshtasticManager(self, didDisconnectFromNode: updated)
            }

            updateState(.scanning)
            startScanning()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension MeshtasticBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == MeshtasticConstants.serviceUUID }) else {
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([
            MeshtasticConstants.fromRadioCharUUID,
            MeshtasticConstants.toRadioCharUUID,
            MeshtasticConstants.fromNumCharUUID,
        ], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }

        for char in chars {
            switch char.uuid {
            case MeshtasticConstants.fromRadioCharUUID:
                fromRadioChar = char
            case MeshtasticConstants.toRadioCharUUID:
                toRadioChar = char
            case MeshtasticConstants.fromNumCharUUID:
                fromNumChar = char
                peripheral.setNotifyValue(true, for: char)
            default:
                break
            }
        }

        // All three characteristics found — begin config handshake
        if fromRadioChar != nil && toRadioChar != nil && fromNumChar != nil {
            connectedPeripheral = peripheral
            // Create a temporary node for the connected peripheral
            let uuid = peripheral.identifier.uuid
            let nodeNum = peripheralNodeMap[peripheral.identifier] ??
                (UInt32(uuid.0) << 24 | UInt32(uuid.1) << 16 | UInt32(uuid.2) << 8 | UInt32(uuid.3))
            connectedNode = discoveredNodes[nodeNum] ?? MeshtasticNode(id: nodeNum, lastSeen: Date())
            beginConfigHandshake(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else { return }

        if characteristic.uuid == MeshtasticConstants.fromNumCharUUID {
            // FromNum notification — new data available, drain FromRadio
            drainFromRadio(peripheral)
            return
        }

        if characteristic.uuid == MeshtasticConstants.fromRadioCharUUID {
            guard let data = characteristic.value, !data.isEmpty else { return }
            handleFromRadio(data)

            // Keep reading until empty response or safety limit reached
            drainReadsRemaining -= 1
            if drainReadsRemaining > 0 {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            print("[Meshtastic] Write error: \(error.localizedDescription)")
        }
    }
}
