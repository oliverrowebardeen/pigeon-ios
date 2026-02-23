import Foundation

actor MeshRouter {
    private let forwardingRetention: TimeInterval
    private let seenMessageRetention: TimeInterval

    private var outboundQueue: [Data: [MessageEnvelope]] = [:]
    private var forwardingStore: [UUID: (envelope: MessageEnvelope, expiresAt: Date)] = [:]
    private var seenMessageCache: [UUID: Date] = [:]

    init(
        forwardingRetention: TimeInterval = BLEConstants.forwardingRetentionSeconds,
        seenMessageRetention: TimeInterval = BLEConstants.forwardingRetentionSeconds
    ) {
        self.forwardingRetention = forwardingRetention
        self.seenMessageRetention = seenMessageRetention
    }

    func enqueueOutbound(_ envelope: MessageEnvelope) {
        var queue = outboundQueue[envelope.recipientPublicKey, default: []]
        guard !queue.contains(where: { $0.id == envelope.id }) else {
            return
        }
        queue.append(envelope)
        outboundQueue[envelope.recipientPublicKey] = queue
    }

    func dequeueOutbound(for recipientPublicKey: Data, limit: Int = .max) -> [MessageEnvelope] {
        guard var messages = outboundQueue[recipientPublicKey], !messages.isEmpty else {
            return []
        }

        let count = min(limit, messages.count)
        let drained = Array(messages.prefix(count))
        messages.removeFirst(count)

        if messages.isEmpty {
            outboundQueue.removeValue(forKey: recipientPublicKey)
        } else {
            outboundQueue[recipientPublicKey] = messages
        }

        return drained
    }

    func outboundMessages(for recipientPublicKey: Data, limit: Int = .max) -> [MessageEnvelope] {
        purgeExpired(now: Date())

        guard let messages = outboundQueue[recipientPublicKey], !messages.isEmpty else {
            return []
        }

        let count = min(limit, messages.count)
        return Array(messages.prefix(count))
    }

    @discardableResult
    func markSeen(_ messageID: UUID, now: Date = Date()) -> Bool {
        purgeExpired(now: now)

        if seenMessageCache[messageID] != nil {
            return false
        }

        seenMessageCache[messageID] = now.addingTimeInterval(seenMessageRetention)
        return true
    }

    func hasSeen(_ messageID: UUID, now: Date = Date()) -> Bool {
        purgeExpired(now: now)
        return seenMessageCache[messageID] != nil
    }

    func storeForForwarding(_ envelope: MessageEnvelope, now: Date = Date()) {
        guard envelope.hopCount < envelope.ttl else {
            return
        }

        let expiry = now.addingTimeInterval(forwardingRetention)
        forwardingStore[envelope.id] = (envelope: envelope, expiresAt: expiry)
    }

    func forwardableMessages(now: Date = Date()) -> [MessageEnvelope] {
        purgeExpired(now: now)

        return forwardingStore.values
            .map(\.envelope)
            .filter { $0.hopCount < $0.ttl }
    }

    func removeForwardedMessage(_ messageID: UUID) {
        forwardingStore.removeValue(forKey: messageID)
    }

    func acknowledgeDelivery(_ messageID: UUID) {
        forwardingStore.removeValue(forKey: messageID)

        for (recipientKey, messages) in outboundQueue {
            let filtered = messages.filter { $0.id != messageID }
            if filtered.isEmpty {
                outboundQueue.removeValue(forKey: recipientKey)
            } else if filtered.count != messages.count {
                outboundQueue[recipientKey] = filtered
            }
        }
    }

    private func purgeExpired(now: Date) {
        forwardingStore = forwardingStore.filter { _, item in
            item.expiresAt > now
        }

        seenMessageCache = seenMessageCache.filter { _, expiry in
            expiry > now
        }
    }
}
