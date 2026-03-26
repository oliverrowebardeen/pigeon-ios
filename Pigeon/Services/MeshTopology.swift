import Foundation

actor MeshTopology {
    struct NodeReachability {
        let reachablePeers: Set<Data>
        let lastUpdated: Date
    }

    private var graph: [Data: NodeReachability] = [:]
    private let staleTimeout: TimeInterval

    init(staleTimeout: TimeInterval = BLEConstants.reachabilityStaleTimeout) {
        self.staleTimeout = staleTimeout
    }

    func update(sender: Data, reachablePeers: [Data], timestamp: Date) {
        // Guard against clock-skewed peers sending future timestamps
        let clampedTimestamp = min(timestamp, Date())
        graph[sender] = NodeReachability(
            reachablePeers: Set(reachablePeers),
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
}
