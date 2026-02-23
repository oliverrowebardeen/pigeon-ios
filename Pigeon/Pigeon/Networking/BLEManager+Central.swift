import CoreBluetooth
import CryptoKit
import Foundation

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateState()

        switch central.state {
        case .poweredOn:
            startScanning()
        case .poweredOff, .unauthorized, .unsupported:
            connectedPeripherals.removeAll()
            discoveredPeripherals.removeAll()
            peripheralPeerMap.removeAll()
            peerPeripheralMap.removeAll()
            peripheralMessageChars.removeAll()
            peripheralACKChars.removeAll()
            nearbyPeers.removeAll()
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
        let peripheralID = peripheral.identifier

        if discoveredPeripherals[peripheralID] == nil {
            discoveredPeripherals[peripheralID] = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }

        // Update RSSI for already-known peers
        if let publicKey = peripheralPeerMap[peripheralID],
           var peer = nearbyPeers[publicKey] {
            peer.rssi = RSSI.intValue
            peer.lastSeen = Date()
            nearbyPeers[publicKey] = peer
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                delegate?.bleManager(self, didUpdatePeer: peer)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let peripheralID = peripheral.identifier
        connectedPeripherals[peripheralID] = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([BLEConstants.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        discoveredPeripherals.removeValue(forKey: peripheral.identifier)
        // Retry after a delay
        bleQueue.asyncAfter(deadline: .now() + 2.0) { [weak central] in
            guard let central, central.state == .poweredOn else { return }
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let peripheralID = peripheral.identifier

        if let publicKey = peripheralPeerMap[peripheralID] {
            let pigeonID = nearbyPeers[publicKey]?.pigeonID
            nearbyPeers.removeValue(forKey: publicKey)
            peerPeripheralMap.removeValue(forKey: publicKey)
            if let pigeonID {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    delegate?.bleManager(self, didLosePeer: pigeonID)
                }
            }
        }

        connectedPeripherals.removeValue(forKey: peripheralID)
        peripheralPeerMap.removeValue(forKey: peripheralID)
        peripheralMessageChars.removeValue(forKey: peripheralID)
        peripheralACKChars.removeValue(forKey: peripheralID)

        // Attempt reconnection if the peripheral is still in range
        if central.state == .poweredOn {
            discoveredPeripherals.removeValue(forKey: peripheralID)
            // Let scanning re-discover and reconnect
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                discoveredPeripherals[peripheral.identifier] = peripheral
                peripheral.delegate = self
                if peripheral.state == .connected {
                    connectedPeripherals[peripheral.identifier] = peripheral
                    peripheral.discoverServices([BLEConstants.serviceUUID])
                } else {
                    central.connect(peripheral, options: nil)
                }
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let services = peripheral.services else { return }

        for service in services where service.uuid == BLEConstants.serviceUUID {
            peripheral.discoverCharacteristics(
                [BLEConstants.identityCharUUID, BLEConstants.messageCharUUID, BLEConstants.ackCharUUID],
                for: service
            )
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil,
              let characteristics = service.characteristics else { return }

        let peripheralID = peripheral.identifier

        for characteristic in characteristics {
            switch characteristic.uuid {
            case BLEConstants.identityCharUUID:
                peripheral.readValue(for: characteristic)

            case BLEConstants.messageCharUUID:
                peripheralMessageChars[peripheralID] = characteristic
                peripheral.setNotifyValue(true, for: characteristic)

            case BLEConstants.ackCharUUID:
                peripheralACKChars[peripheralID] = characteristic
                peripheral.setNotifyValue(true, for: characteristic)

            default:
                break
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }

        switch characteristic.uuid {
        case BLEConstants.identityCharUUID:
            handleIdentityRead(data, from: peripheral)

        case BLEConstants.messageCharUUID:
            processIncomingChunk(data)

        case BLEConstants.ackCharUUID:
            handleReceivedACK(data)

        default:
            break
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // Write confirmed — chunks are sent sequentially via writeWithResponse
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // Notification subscription updated
    }

    // MARK: - Identity handling

    private func handleIdentityRead(_ data: Data, from peripheral: CBPeripheral) {
        do {
            let payload = try MessageProtocol.decodePeerIdentity(data)
            let peripheralID = peripheral.identifier

            // Skip if this is our own identity
            guard payload.publicKey != identity.publicKey.rawRepresentation else { return }

            peripheralPeerMap[peripheralID] = payload.publicKey
            peerPeripheralMap[payload.publicKey] = peripheralID

            let now = Date()
            let peer = Peer(
                publicKey: payload.publicKey,
                pigeonID: payload.pigeonID,
                displayName: payload.displayName,
                rssi: nil,
                firstSeen: nearbyPeers[payload.publicKey]?.firstSeen ?? now,
                lastSeen: now,
                isSaved: nearbyPeers[payload.publicKey]?.isSaved ?? false
            )

            let isNew = nearbyPeers[payload.publicKey] == nil
            nearbyPeers[payload.publicKey] = peer

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if isNew {
                    delegate?.bleManager(self, didDiscoverPeer: peer)
                } else {
                    delegate?.bleManager(self, didUpdatePeer: peer)
                }
            }

            // Send any pending messages for this peer
            sendPendingMessages(toPeerWithPublicKey: payload.publicKey, peripheralID: peripheralID)
        } catch {
            // Malformed identity payload
        }
    }
}
