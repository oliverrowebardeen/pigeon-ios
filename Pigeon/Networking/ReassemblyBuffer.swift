import Foundation

nonisolated final class ReassemblyBuffer {
    let messageID: UUID
    let expectedChunkCount: UInt16
    let createdAt: Date
    private var chunks: [UInt16: Data] = [:]

    var isComplete: Bool { chunks.count == Int(expectedChunkCount) }

    var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > BLEConstants.reassemblyTimeoutSeconds
    }

    init(messageID: UUID, expectedChunkCount: UInt16, createdAt: Date = Date()) {
        self.messageID = messageID
        self.expectedChunkCount = expectedChunkCount
        self.createdAt = createdAt
    }

    @discardableResult
    func addChunk(index: UInt16, data: Data) -> Bool {
        guard index < expectedChunkCount else { return false }
        chunks[index] = data
        return isComplete
    }

    func assembledPacketData() -> [Data] {
        (0 ..< expectedChunkCount).compactMap { chunks[$0] }
    }
}
