import Foundation

/// Parsed SCTE-35 splice descriptor preserved inside the bounded descriptor loop.
public struct SCTE35Descriptor: Equatable, Sendable {
    public let tag: UInt8
    public let length: UInt8
    public let identifier: String?
    public let segmentation: SCTE35SegmentationDescriptor?
    public let bytes: [UInt8]

    public init(
        tag: UInt8,
        length: UInt8,
        bytes: [UInt8],
        identifier: String? = nil,
        segmentation: SCTE35SegmentationDescriptor? = nil
    ) {
        self.tag = tag
        self.length = length
        self.identifier = identifier
        self.segmentation = segmentation
        self.bytes = bytes
    }

    static func parse(tag: UInt8, length: UInt8, bytes: [UInt8]) throws -> SCTE35Descriptor {
        guard Int(length) == bytes.count else {
            throw SCTE35DecodeError.malformedSection
        }

        let identifier = parseIdentifier(from: bytes)
        guard tag == 0x02, identifier == "CUEI" else {
            return SCTE35Descriptor(tag: tag, length: length, bytes: bytes, identifier: identifier)
        }

        let segmentation = try SCTE35SegmentationDescriptor.parse(from: bytes)
        return SCTE35Descriptor(
            tag: tag,
            length: length,
            bytes: bytes,
            identifier: identifier,
            segmentation: segmentation
        )
    }

    private static func parseIdentifier(from bytes: [UInt8]) -> String? {
        guard bytes.count >= 4 else { return nil }
        let prefix = bytes[0..<4]
        guard prefix.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return nil }
        return String(bytes: prefix, encoding: .ascii)
    }
}

/// Fixture-critical `segmentation_descriptor` fields from SCTE-35 splice descriptors.
public struct SCTE35SegmentationDescriptor: Equatable, Sendable {
    public let identifier: String
    public let segmentationEventID: UInt32
    public let segmentationEventCancelIndicator: Bool
    public let programSegmentationFlag: Bool?
    public let segmentationDurationFlag: Bool?
    public let deliveryNotRestrictedFlag: Bool?
    public let webDeliveryAllowedFlag: Bool?
    public let noRegionalBlackoutFlag: Bool?
    public let archiveAllowedFlag: Bool?
    public let deviceRestrictions: UInt8?
    public let segmentationDuration: Double?
    public let segmentationUPIDType: UInt8?
    public let segmentationUPID: String?
    public let segmentationTypeID: UInt8?
    public let segmentNumber: UInt8?
    public let segmentsExpected: UInt8?
    public let subSegmentNumber: UInt8?
    public let subSegmentsExpected: UInt8?

    private static let ticksPerSecond = 90_000.0

    static func parse(from bytes: [UInt8]) throws -> SCTE35SegmentationDescriptor {
        guard bytes.count >= 9 else {
            throw SCTE35DecodeError.malformedSection
        }
        let identifier = String(bytes: bytes[0..<4], encoding: .ascii) ?? ""
        guard identifier == "CUEI" else {
            throw SCTE35DecodeError.malformedSection
        }

        var offset = 4
        let eventID = try readUInt32(from: bytes, offset: &offset)
        let cancelByte = try readByte(from: bytes, offset: &offset)
        let cancelIndicator = (cancelByte & 0x80) != 0

        if cancelIndicator {
            guard offset == bytes.count else {
                throw SCTE35DecodeError.malformedSection
            }
            return SCTE35SegmentationDescriptor(
                identifier: identifier,
                segmentationEventID: eventID,
                segmentationEventCancelIndicator: true,
                programSegmentationFlag: nil,
                segmentationDurationFlag: nil,
                deliveryNotRestrictedFlag: nil,
                webDeliveryAllowedFlag: nil,
                noRegionalBlackoutFlag: nil,
                archiveAllowedFlag: nil,
                deviceRestrictions: nil,
                segmentationDuration: nil,
                segmentationUPIDType: nil,
                segmentationUPID: nil,
                segmentationTypeID: nil,
                segmentNumber: nil,
                segmentsExpected: nil,
                subSegmentNumber: nil,
                subSegmentsExpected: nil
            )
        }

        let flags = try readByte(from: bytes, offset: &offset)
        let programSegmentationFlag = (flags & 0x80) != 0
        let segmentationDurationFlag = (flags & 0x40) != 0
        let deliveryNotRestrictedFlag = (flags & 0x20) != 0

        let webDeliveryAllowedFlag: Bool?
        let noRegionalBlackoutFlag: Bool?
        let archiveAllowedFlag: Bool?
        let deviceRestrictions: UInt8?
        if deliveryNotRestrictedFlag {
            webDeliveryAllowedFlag = nil
            noRegionalBlackoutFlag = nil
            archiveAllowedFlag = nil
            deviceRestrictions = nil
        } else {
            webDeliveryAllowedFlag = (flags & 0x10) != 0
            noRegionalBlackoutFlag = (flags & 0x08) != 0
            archiveAllowedFlag = (flags & 0x04) != 0
            deviceRestrictions = flags & 0x03
        }

        guard programSegmentationFlag else {
            throw SCTE35DecodeError.unsupportedCommand
        }

        let segmentationDuration: Double?
        if segmentationDurationFlag {
            segmentationDuration = Double(try readUInt40(from: bytes, offset: &offset)) / ticksPerSecond
        } else {
            segmentationDuration = nil
        }

        let upidType = try readByte(from: bytes, offset: &offset)
        let upidLength = Int(try readByte(from: bytes, offset: &offset))
        guard offset + upidLength <= bytes.count else {
            throw SCTE35DecodeError.malformedSection
        }
        let upidBytes = Array(bytes[offset..<(offset + upidLength)])
        offset += upidLength
        let upid = Self.formatUPID(upidBytes)

        let segmentationTypeID = try readByte(from: bytes, offset: &offset)
        let segmentNumber = try readByte(from: bytes, offset: &offset)
        let segmentsExpected = try readByte(from: bytes, offset: &offset)

        let subSegmentNumber: UInt8?
        let subSegmentsExpected: UInt8?
        if offset == bytes.count {
            subSegmentNumber = nil
            subSegmentsExpected = nil
        } else if offset + 2 == bytes.count {
            subSegmentNumber = try readByte(from: bytes, offset: &offset)
            subSegmentsExpected = try readByte(from: bytes, offset: &offset)
        } else {
            throw SCTE35DecodeError.malformedSection
        }

        return SCTE35SegmentationDescriptor(
            identifier: identifier,
            segmentationEventID: eventID,
            segmentationEventCancelIndicator: false,
            programSegmentationFlag: programSegmentationFlag,
            segmentationDurationFlag: segmentationDurationFlag,
            deliveryNotRestrictedFlag: deliveryNotRestrictedFlag,
            webDeliveryAllowedFlag: webDeliveryAllowedFlag,
            noRegionalBlackoutFlag: noRegionalBlackoutFlag,
            archiveAllowedFlag: archiveAllowedFlag,
            deviceRestrictions: deviceRestrictions,
            segmentationDuration: segmentationDuration,
            segmentationUPIDType: upidType,
            segmentationUPID: upid,
            segmentationTypeID: segmentationTypeID,
            segmentNumber: segmentNumber,
            segmentsExpected: segmentsExpected,
            subSegmentNumber: subSegmentNumber,
            subSegmentsExpected: subSegmentsExpected
        )
    }

    private static func formatUPID(_ bytes: [UInt8]) -> String {
        if bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }), let ascii = String(bytes: bytes, encoding: .ascii) {
            return ascii
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func readByte(from bytes: [UInt8], offset: inout Int) throws -> UInt8 {
        guard offset < bytes.count else {
            throw SCTE35DecodeError.malformedSection
        }
        defer { offset += 1 }
        return bytes[offset]
    }

    private static func readUInt32(from bytes: [UInt8], offset: inout Int) throws -> UInt32 {
        guard offset + 4 <= bytes.count else {
            throw SCTE35DecodeError.malformedSection
        }
        let value = (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
        offset += 4
        return value
    }

    private static func readUInt40(from bytes: [UInt8], offset: inout Int) throws -> UInt64 {
        guard offset + 5 <= bytes.count else {
            throw SCTE35DecodeError.malformedSection
        }
        let value = (UInt64(bytes[offset]) << 32)
            | (UInt64(bytes[offset + 1]) << 24)
            | (UInt64(bytes[offset + 2]) << 16)
            | (UInt64(bytes[offset + 3]) << 8)
            | UInt64(bytes[offset + 4])
        offset += 5
        return value
    }
}
