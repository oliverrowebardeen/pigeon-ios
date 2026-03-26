import CoreBluetooth
import CryptoKit
import Foundation

// MARK: - CBPeripheralManagerDelegate

extension BLEManager: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        updateState()

        switch peripheral.state {
        case .poweredOn:
            startAdvertising()
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            print("[Pigeon] Failed to add service: \(error.localizedDescription)")
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            print("[Pigeon] Failed to start advertising: \(error.localizedDescription)")
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveRead request: CBATTRequest
    ) {
        switch request.characteristic.uuid {
        case BLEConstants.identityCharUUID:
            let payload = PeerIdentityPayload(
                publicKey: identity.publicKey.rawRepresentation,
                pigeonID: identity.pigeonID,
                displayName: currentDisplayName,
                bridgeProtocolVersion: BridgeProtocol.version,
                bridgeEnabled: bridgeEnabled,
                isMeshNode: false,
                relayReachable: bridgeRelayReachable,
                bridgeCapacityRemaining: bridgeCapacityRemaining
            )

            do {
                let data = try MessageProtocol.encodePeerIdentity(payload)
                if request.offset > data.count {
                    peripheral.respond(to: request, withResult: .invalidOffset)
                    return
                }
                request.value = data.subdata(in: request.offset ..< data.count)
                peripheral.respond(to: request, withResult: .success)
            } catch {
                peripheral.respond(to: request, withResult: .unlikelyError)
            }

        case BLEConstants.reachabilityCharUUID:
            let peerKeys = Array(nearbyPeers.keys)
            let payload = PeerReachabilityPayload(
                senderPublicKey: identity.publicKey.rawRepresentation,
                reachablePeers: peerKeys,
                hopCount: 0,
                ttl: BLEConstants.reachabilityTTL,
                timestamp: Date()
            )

            do {
                let data = try MessageProtocol.encodeReachability(payload)
                if request.offset > data.count {
                    peripheral.respond(to: request, withResult: .invalidOffset)
                    return
                }
                request.value = data.subdata(in: request.offset ..< data.count)
                peripheral.respond(to: request, withResult: .success)
            } catch {
                peripheral.respond(to: request, withResult: .unlikelyError)
            }

        default:
            peripheral.respond(to: request, withResult: .requestNotSupported)
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        for request in requests {
            guard let data = request.value else {
                peripheral.respond(to: request, withResult: .unlikelyError)
                continue
            }

            switch request.characteristic.uuid {
            case BLEConstants.messageCharUUID:
                processIncomingChunk(data)
                peripheral.respond(to: request, withResult: .success)

            case BLEConstants.ackCharUUID:
                handleReceivedACK(data)
                peripheral.respond(to: request, withResult: .success)

            case BLEConstants.bridgeControlCharUUID:
                processIncomingBridgeChunk(data, source: .central(request.central))
                peripheral.respond(to: request, withResult: .success)

            case BLEConstants.reachabilityCharUUID:
                handleReceivedReachability(data, fromPeerID: nil)
                peripheral.respond(to: request, withResult: .success)

            default:
                peripheral.respond(to: request, withResult: .requestNotSupported)
            }
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        if characteristic.uuid == BLEConstants.bridgeControlCharUUID {
            subscribedBridgeCentrals[central.identifier] = central
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        if characteristic.uuid == BLEConstants.bridgeControlCharUUID {
            subscribedBridgeCentrals.removeValue(forKey: central.identifier)
            bridgePeerCentrals = bridgePeerCentrals.filter { $0.value.identifier != central.identifier }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // Notification queue has space again — could resume sending if we were buffering
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        // Restore service if needed
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            for service in services where service.uuid == BLEConstants.serviceUUID {
                pigeonService = service
                for characteristic in service.characteristics ?? [] {
                    if let mutable = characteristic as? CBMutableCharacteristic {
                        switch mutable.uuid {
                        case BLEConstants.identityCharUUID:
                            identityCharacteristic = mutable
                        case BLEConstants.messageCharUUID:
                            messageCharacteristic = mutable
                        case BLEConstants.ackCharUUID:
                            ackCharacteristic = mutable
                        case BLEConstants.bridgeControlCharUUID:
                            bridgeControlCharacteristic = mutable
                        case BLEConstants.reachabilityCharUUID:
                            reachabilityCharacteristic = mutable
                        default:
                            break
                        }
                    }
                }
            }
        }

        if pigeonService == nil {
            startAdvertising()
        }
    }
}
