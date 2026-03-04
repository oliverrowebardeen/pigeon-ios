import Foundation

extension Data {
    nonisolated init?(hexString: String) {
        let cleaned = hexString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard cleaned.count % 2 == 0 else {
            return nil
        }

        var data = Data()
        data.reserveCapacity(cleaned.count / 2)

        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index ..< nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }

    nonisolated var hexEncodedString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    nonisolated var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated init?(base64URLEncoded string: String) {
        let normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let paddingLength = (4 - (normalized.count % 4)) % 4
        let padded = normalized + String(repeating: "=", count: paddingLength)

        guard let data = Data(base64Encoded: padded) else {
            return nil
        }

        self = data
    }

    nonisolated mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value & 0xFF00) >> 8))
        append(UInt8(value & 0x00FF))
    }

    nonisolated func readUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, count >= offset + 2 else {
            return nil
        }

        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }
}

extension UUID {
    nonisolated var byteArray: [UInt8] {
        let bytes = uuid
        return [
            bytes.0, bytes.1, bytes.2, bytes.3,
            bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11,
            bytes.12, bytes.13, bytes.14, bytes.15
        ]
    }

    nonisolated init?(byteArray: ArraySlice<UInt8>) {
        guard byteArray.count == 16 else {
            return nil
        }

        let values = Array(byteArray)
        self = UUID(uuid: (
            values[0], values[1], values[2], values[3],
            values[4], values[5], values[6], values[7],
            values[8], values[9], values[10], values[11],
            values[12], values[13], values[14], values[15]
        ))
    }
}
