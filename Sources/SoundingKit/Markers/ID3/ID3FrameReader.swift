import Foundation

public struct ID3FrameReader: Sendable {
    private static let frameHeaderLength = 10
    private static let appleTransportTimestampOwner = "com.apple.streaming.transportStreamTimestamp"
    private static let timestampMask: UInt64 = 0x1FFFFFFFF

    public init() {}

    public func readFrames(from tag: ID3TagBytes) throws -> [ID3Frame] {
        guard tag.version.major == 3 || tag.version.major == 4 else {
            throw ID3DecodeError.unsupportedVersion(major: tag.version.major)
        }

        let tagBytes = [UInt8](tag.data)
        let payloadStart = tag.payloadRange.lowerBound - tag.byteRange.lowerBound
        let payloadEnd = tag.payloadRange.upperBound - tag.byteRange.lowerBound
        guard payloadStart >= 0, payloadEnd >= payloadStart, payloadEnd <= tagBytes.count else {
            throw ID3DecodeError.malformedFrame
        }

        let payload = Array(tagBytes[payloadStart..<payloadEnd])
        var frames: [ID3Frame] = []
        var cursor = 0

        while cursor < payload.count {
            if payload[cursor] == 0 { break }

            guard cursor + Self.frameHeaderLength <= payload.count else {
                throw ID3DecodeError.malformedFrame
            }

            let header = Array(payload[cursor..<(cursor + Self.frameHeaderLength)])
            let idBytes = Array(header[0..<4])
            guard isValidFrameID(idBytes), let frameID = String(bytes: idBytes, encoding: .ascii) else {
                throw ID3DecodeError.malformedFrame
            }

            let dataLength = try decodeFrameSize(Array(header[4..<8]), major: tag.version.major)
            let flagBytes = Array(header[8..<10])
            guard supports(flagBytes: flagBytes, major: tag.version.major) else {
                throw ID3DecodeError.unsupportedFrameFlags
            }

            let bodyStart = cursor + Self.frameHeaderLength
            let bodyEnd = bodyStart + dataLength
            guard bodyEnd <= payload.count else {
                throw ID3DecodeError.malformedFrame
            }

            let framePayload = Data(payload[bodyStart..<bodyEnd])
            frames.append(try decode(frameID: frameID, payload: framePayload))
            cursor = bodyEnd
        }

        return frames
    }

    private func decodeFrameSize(_ bytes: [UInt8], major: UInt8) throws -> Int {
        precondition(bytes.count == 4)

        if major == 4 {
            var value = 0
            for byte in bytes {
                guard (byte & 0x80) == 0 else { throw ID3DecodeError.malformedFrame }
                value = (value << 7) | Int(byte)
            }
            return value
        }

        return bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    private func supports(flagBytes: [UInt8], major: UInt8) -> Bool {
        precondition(flagBytes.count == 2)

        if major == 4 {
            let formatFlags = flagBytes[1]
            return (formatFlags & 0x0F) == 0
        }

        let formatFlags = flagBytes[1]
        return (formatFlags & 0xE0) == 0
    }

    private func decode(frameID: String, payload: Data) throws -> ID3Frame {
        switch frameID {
        case "TIT2", "TIT3":
            return .text(id: frameID, texts: try ID3TextDecoder.decode(payload))
        case "TXXX":
            let values = try ID3TextDecoder.decode(payload)
            let description = values.first ?? ""
            return .userText(description: description, texts: Array(values.dropFirst()))
        case "PRIV":
            return try decodePrivateFrame(payload)
        default:
            return .unsupported(id: frameID, dataLength: payload.count)
        }
    }

    private func decodePrivateFrame(_ payload: Data) throws -> ID3Frame {
        let bytes = [UInt8](payload)
        guard let terminator = bytes.firstIndex(of: 0) else {
            throw ID3DecodeError.malformedFrame
        }

        let ownerBytes = Array(bytes[..<terminator])
        let owner = String(decoding: ownerBytes, as: UTF8.self)
        let privateBytes = Array(bytes[(terminator + 1)...])
        let timestamp: ID3TransportTimestamp?

        if owner == Self.appleTransportTimestampOwner {
            timestamp = try decodeAppleTransportTimestamp(privateBytes)
        } else {
            timestamp = nil
        }

        return .private(owner: owner, dataLength: privateBytes.count, transportTimestamp: timestamp)
    }

    private func decodeAppleTransportTimestamp(_ bytes: [UInt8]) throws -> ID3TransportTimestamp {
        guard bytes.count == 8 else { throw ID3DecodeError.malformedFrame }

        let rawValue = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard (rawValue & ~Self.timestampMask) == 0 else {
            throw ID3DecodeError.malformedFrame
        }

        let ticks = rawValue & Self.timestampMask
        return ID3TransportTimestamp(ticks: ticks, seconds: Double(ticks) / 90_000.0)
    }

    private func isValidFrameID(_ bytes: [UInt8]) -> Bool {
        bytes.allSatisfy { byte in
            (0x41...0x5A).contains(byte) || (0x30...0x39).contains(byte)
        }
    }
}
