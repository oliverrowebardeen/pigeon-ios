import Foundation
import Testing
@testable import Pigeon

@Suite("MeshTopology")
struct MeshTopologyTests {
    private func makeKey(_ byte: UInt8) -> Data {
        Data([byte])
    }

    // MARK: - isTransitivelyReachable

    @Test func directPeerIsReachable() async {
        let topology = MeshTopology()
        let a = makeKey(1)
        let b = makeKey(2)

        await topology.update(sender: a, reachablePeers: [b], hasInternetGateway: false, timestamp: Date())

        let result = await topology.isTransitivelyReachable(target: b, from: [a])
        #expect(result == true)
    }

    @Test func multiHopReachable() async {
        let topology = MeshTopology()
        let a = makeKey(1)
        let b = makeKey(2)
        let c = makeKey(3)

        await topology.update(sender: a, reachablePeers: [b], hasInternetGateway: false, timestamp: Date())
        await topology.update(sender: b, reachablePeers: [c], hasInternetGateway: false, timestamp: Date())

        let result = await topology.isTransitivelyReachable(target: c, from: [a])
        #expect(result == true)
    }

    @Test func unreachablePeer() async {
        let topology = MeshTopology()
        let a = makeKey(1)
        let target = makeKey(99)

        await topology.update(sender: a, reachablePeers: [makeKey(2)], hasInternetGateway: false, timestamp: Date())

        let result = await topology.isTransitivelyReachable(target: target, from: [a])
        #expect(result == false)
    }

    @Test func disconnectedSubgraph() async {
        let topology = MeshTopology()
        let a = makeKey(1)
        let b = makeKey(2)
        let c = makeKey(3)
        let d = makeKey(4)

        // a -> b (subgraph 1)
        await topology.update(sender: a, reachablePeers: [b], hasInternetGateway: false, timestamp: Date())
        // c -> d (subgraph 2, disconnected)
        await topology.update(sender: c, reachablePeers: [d], hasInternetGateway: false, timestamp: Date())

        let result = await topology.isTransitivelyReachable(target: d, from: [a])
        #expect(result == false)
    }

    // MARK: - firstHopToGateway

    @Test func directPeerIsGateway() async {
        let topology = MeshTopology()
        let a = makeKey(1)

        await topology.update(sender: a, reachablePeers: [], hasInternetGateway: true, timestamp: Date())

        let hop = await topology.firstHopToGateway(from: [a])
        #expect(hop == a)
    }

    @Test func multiHopGateway() async {
        let topology = MeshTopology()
        let a = makeKey(1)
        let b = makeKey(2)
        let c = makeKey(3)

        await topology.update(sender: a, reachablePeers: [b], hasInternetGateway: false, timestamp: Date())
        await topology.update(sender: b, reachablePeers: [c], hasInternetGateway: false, timestamp: Date())
        await topology.update(sender: c, reachablePeers: [], hasInternetGateway: true, timestamp: Date())

        let hop = await topology.firstHopToGateway(from: [a])
        #expect(hop == a)
    }

    @Test func noGatewayReturnsNil() async {
        let topology = MeshTopology()
        let a = makeKey(1)
        let b = makeKey(2)

        await topology.update(sender: a, reachablePeers: [b], hasInternetGateway: false, timestamp: Date())
        await topology.update(sender: b, reachablePeers: [], hasInternetGateway: false, timestamp: Date())

        let hop = await topology.firstHopToGateway(from: [a])
        #expect(hop == nil)
    }

    @Test func shortestPathGatewayPreferred() async {
        let topology = MeshTopology()
        let a = makeKey(1)
        let b = makeKey(2)
        let c = makeKey(3)

        // a -> b (gateway, 1 hop via a)
        // a -> c -> b would be longer but both reach same gateway
        // Direct peer b is a gateway
        await topology.update(sender: a, reachablePeers: [b, c], hasInternetGateway: false, timestamp: Date())
        await topology.update(sender: b, reachablePeers: [], hasInternetGateway: true, timestamp: Date())
        await topology.update(sender: c, reachablePeers: [makeKey(4)], hasInternetGateway: false, timestamp: Date())
        await topology.update(sender: makeKey(4), reachablePeers: [], hasInternetGateway: true, timestamp: Date())

        // b is a direct peer AND a gateway, so it should be returned directly
        let hop = await topology.firstHopToGateway(from: [a])
        #expect(hop == a)
    }

    @Test func emptyDirectPeersReturnsNil() async {
        let topology = MeshTopology()
        await topology.update(sender: makeKey(1), reachablePeers: [], hasInternetGateway: true, timestamp: Date())

        let hop = await topology.firstHopToGateway(from: [])
        #expect(hop == nil)
    }

    // MARK: - pruneStale

    @Test func pruneRemovesStaleEntries() async {
        let topology = MeshTopology(staleTimeout: 1)
        let a = makeKey(1)

        let oldTimestamp = Date().addingTimeInterval(-10)
        await topology.update(sender: a, reachablePeers: [makeKey(2)], hasInternetGateway: true, timestamp: oldTimestamp)

        await topology.pruneStale()

        let hop = await topology.firstHopToGateway(from: [a])
        #expect(hop == nil)
    }

    @Test func pruneKeepsFreshEntries() async {
        let topology = MeshTopology(staleTimeout: 120)
        let a = makeKey(1)

        await topology.update(sender: a, reachablePeers: [], hasInternetGateway: true, timestamp: Date())

        await topology.pruneStale()

        let hop = await topology.firstHopToGateway(from: [a])
        #expect(hop == a)
    }

    // MARK: - removeNode

    @Test func removeNodeClearsEntry() async {
        let topology = MeshTopology()
        let a = makeKey(1)

        await topology.update(sender: a, reachablePeers: [], hasInternetGateway: true, timestamp: Date())
        await topology.removeNode(a)

        let hop = await topology.firstHopToGateway(from: [a])
        #expect(hop == nil)
    }

    // MARK: - Clock skew protection

    @Test func futureTimestampIsClamped() async {
        let topology = MeshTopology(staleTimeout: 5)
        let a = makeKey(1)

        let futureTimestamp = Date().addingTimeInterval(3600)
        await topology.update(sender: a, reachablePeers: [], hasInternetGateway: true, timestamp: futureTimestamp)

        // Should still be prunable with a short timeout since timestamp gets clamped to now
        let topology2 = MeshTopology(staleTimeout: 0)
        await topology2.update(sender: a, reachablePeers: [], hasInternetGateway: true, timestamp: futureTimestamp)
        // Give a tiny margin for the clamp
        try? await Task.sleep(nanoseconds: 10_000_000)
        await topology2.pruneStale()

        let hop = await topology2.firstHopToGateway(from: [a])
        #expect(hop == nil)
    }
}
