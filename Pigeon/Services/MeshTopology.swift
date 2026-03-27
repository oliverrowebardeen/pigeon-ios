import Foundation

actor MeshTopology {
    struct NodeReachability {
        let reachablePeers: Set<Data>
        let hasInternetGateway: Bool
        let lastUpdated: Date
    }

    private var graph: [Data: NodeReachability] = [:]
    private let staleTimeout: TimeInterval

    init(staleTimeout: TimeInterval = BLEConstants.reachabilityStaleTimeout) {
        self.staleTimeout = staleTimeout
    }

    func update(sender: Data, reachablePeers: [Data], hasInternetGateway: Bool, timestamp: Date) {
        let clampedTimestamp = min(timestamp, Date())
        graph[sender] = NodeReachability(
            reachablePeers: Set(reachablePeers),
            hasInternetGateway: hasInternetGateway,
            lastUpdated: clampedTimestamp
        )
    }

    func removeNode(_ publicKey: Data) {
        graph.removeValue(forKey: publicKey)
    }

    func pruneStale() {
        let cutoff = Date().addingTimeInterval(-staleTimeout)
        graph = graph.filter { $0.value.lastUpdated > cutoff }
    }

    /// BFS through the reachability graph starting from directPeers.
    func isTransitivelyReachable(target: Data, from directPeers: [Data]) -> Bool {
        var visited = Set<Data>()
        var queue = directPeers
        var head = 0

        while head < queue.count {
            let current = queue[head]
            head += 1
            if current == target { return true }
            guard !visited.contains(current) else { continue }
            visited.insert(current)

            if let node = graph[current] {
                for peer in node.reachablePeers where !visited.contains(peer) {
                    queue.append(peer)
                }
            }
        }
        return false
    }

    /// Returns the first-hop peer on the shortest path to any internet gateway.
    /// `directPeers` are peers we are directly connected to via BLE.
    func firstHopToGateway(from directPeers: [Data]) -> Data? {
        // Check if any direct peer IS a gateway
        for peer in directPeers {
            if graph[peer]?.hasInternetGateway == true {
                return peer
            }
        }

        // BFS: track which direct peer led to each node
        var visited = Set<Data>()
        // (node, firstHop) pairs
        var queue: [(Data, Data)] = directPeers.map { ($0, $0) }
        var head = 0

        while head < queue.count {
            let (current, firstHop) = queue[head]
            head += 1
            guard !visited.contains(current) else { continue }
            visited.insert(current)

            if let node = graph[current] {
                if node.hasInternetGateway {
                    return firstHop
                }
                for peer in node.reachablePeers where !visited.contains(peer) {
                    queue.append((peer, firstHop))
                }
            }
        }
        return nil
    }

    /// Whether any node in the reachable mesh has internet.
    func hasReachableGateway(from directPeers: [Data]) -> Bool {
        firstHopToGateway(from: directPeers) != nil
    }
}
