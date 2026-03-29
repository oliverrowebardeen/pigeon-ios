import Foundation
import Testing
@testable import Pigeon

@Suite("Mesh Key Exchange")
struct MeshKeyExchangeTests {

    @Test("KeyStore saves and loads by pigeonID")
    func keyStorePigeonIDIndex() throws {
        let keyStore = KeyStore.shared
        let fakeKey = Data(repeating: 0xAB, count: 32)
        let pigeonID = "deadbeef"

        // save is idempotent (updates on duplicate), so no cleanup needed
        try keyStore.savePeerKeyByPigeonID(fakeKey, pigeonID: pigeonID)
        let loaded = try keyStore.loadPeerKeyByPigeonID(pigeonID: pigeonID)
        #expect(loaded == fakeKey)
    }

    @Test("KeyStore pigeonID index is independent of trust alias")
    func pigeonIDIndexIndependentOfTrustAlias() throws {
        let keyStore = KeyStore.shared
        let fakeKey = Data(repeating: 0xCD, count: 32)
        let pigeonID = PigeonIdentity.makePigeonID(fromPublicKeyData: fakeKey)

        // Save under pigeonID index (as updateTrustState should do)
        try keyStore.savePeerKeyByPigeonID(fakeKey, pigeonID: pigeonID)

        // Verify it can be loaded by pigeonID (as didReceiveMeshPeers does)
        let loaded = try keyStore.loadPeerKeyByPigeonID(pigeonID: pigeonID)
        #expect(loaded == fakeKey)

        // Verify the old trust-alias lookup does NOT find it (different account)
        let trustLookup = try keyStore.loadKnownPeerPublicKey(pigeonID: pigeonID)
        #expect(trustLookup == nil)
    }

    @Test("Peer can be created from mesh discovery data")
    func meshDiscoveredPeerCreation() {
        let publicKey = Data(repeating: 0xEF, count: 32)
        let pigeonID = PigeonIdentity.makePigeonID(fromPublicKeyData: publicKey)
        let now = Date()

        let peer = Peer(
            publicKey: publicKey,
            displayName: pigeonID,
            rssi: nil,
            firstSeen: now,
            lastSeen: now,
            isSaved: false
        )

        #expect(peer.publicKey == publicKey)
        #expect(peer.pigeonID == pigeonID)
        #expect(peer.displayName == pigeonID)
        #expect(peer.isMeshNode == false)
    }
}
