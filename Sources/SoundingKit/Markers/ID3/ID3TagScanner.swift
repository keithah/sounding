import Foundation

public struct ID3Version: Equatable, Sendable {
    public let major: UInt8
    public let revision: UInt8

    public init(major: UInt8, revision: UInt8) {
        self.major = major
        self.revision = revision
    }
}

public struct ID3TagBytes: Equatable, Sendable {
    public let version: ID3Version
    public let flags: UInt8
    public let payloadRange: Range<Int>
    public let data: Data
    public let hasFooter: Bool
    public let byteRange: Range<Int>

    public init(
        version: ID3Version,
        flags: UInt8,
        payloadRange: Range<Int>,
        data: Data,
        hasFooter: Bool,
        byteRange: Range<Int>
    ) {
        self.version = version
        self.flags = flags
        self.payloadRange = payloadRange
        self.data = data
        self.hasFooter = hasFooter
        self.byteRange = byteRange
    }
}

public struct ID3TagScanner: Sendable {
    public static let defaultMaximumTagSize = 1_048_576

    public let maximumTagSize: Int

    public init(maximumTagSize: Int = Self.defaultMaximumTagSize) {
        self.maximumTagSize = maximumTagSize
    }

    public static func scan(_ data: Data) throws -> [ID3TagBytes] {
        try ID3TagScanner().scan(data)
    }

    public func scan(_ data: Data) throws -> [ID3TagBytes] {
        guard !data.isEmpty else { return [] }

        let bytes = [UInt8](data)
        var tags: [ID3TagBytes] = []
        var cursor = 0

        while cursor < bytes.count {
            guard let magicOffset = nextMagicOffset(in: bytes, startingAt: cursor) else {
                break
            }

            do {
                let tag = try parseTag(in: data, bytes: bytes, at: magicOffset)
                tags.append(tag)
                cursor = tag.byteRange.upperBound
            } catch {
                guard magicOffset > 0, case ID3DecodeError.unsupportedVersion = error else {
                    throw error
                }
                cursor = magicOffset + 3
            }
        }

        return tags
    }

    private func nextMagicOffset(in bytes: [UInt8], startingAt start: Int) -> Int? {
        guard bytes.count >= 3, start <= bytes.count - 3 else { return nil }

        var index = start
        while index <= bytes.count - 3 {
            if bytes[index] == 0x49, bytes[index + 1] == 0x44, bytes[index + 2] == 0x33 {
                return index
            }
            index += 1
        }
        return nil
    }

    private func parseTag(in data: Data, bytes: [UInt8], at offset: Int) throws -> ID3TagBytes {
        guard offset + 10 <= bytes.count else {
            throw ID3DecodeError.truncatedHeader
        }

        let major = bytes[offset + 3]
        let revision = bytes[offset + 4]
        let flags = bytes[offset + 5]

        guard major == 3 || major == 4 else {
            throw ID3DecodeError.unsupportedVersion(major: major)
        }

        let sizeBytes = Array(bytes[(offset + 6)..<(offset + 10)])
        let payloadSize = try decodeSynchsafe(sizeBytes)
        let hasFooter = (flags & 0x10) != 0
        let footerSize = hasFooter ? 10 : 0
        let fullTagSize = 10 + payloadSize + footerSize

        guard fullTagSize <= maximumTagSize else {
            throw ID3DecodeError.tagTooLarge(maximum: maximumTagSize)
        }

        let endOffset = offset + fullTagSize
        guard endOffset <= bytes.count else {
            throw ID3DecodeError.truncatedTag
        }

        let payloadStart = offset + 10
        let payloadEnd = payloadStart + payloadSize
        let byteRange = offset..<endOffset

        return ID3TagBytes(
            version: ID3Version(major: major, revision: revision),
            flags: flags,
            payloadRange: payloadStart..<payloadEnd,
            data: data.subdata(in: byteRange),
            hasFooter: hasFooter,
            byteRange: byteRange
        )
    }

    private func decodeSynchsafe(_ bytes: [UInt8]) throws -> Int {
        precondition(bytes.count == 4)

        var value = 0
        for byte in bytes {
            guard (byte & 0x80) == 0 else {
                throw ID3DecodeError.malformedSynchsafeSize
            }
            value = (value << 7) | Int(byte)
        }
        return value
    }
}
