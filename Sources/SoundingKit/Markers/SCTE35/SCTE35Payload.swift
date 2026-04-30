import Foundation

/// Caller-provided SCTE-35 payload forms supported by the native decoder.
public enum SCTE35PayloadInput: Equatable, Sendable {
    case base64(String)
    case hex(String)
    case data(Data)
}

/// Normalized SCTE-35 section bytes and their canonical base64 representation.
public struct SCTE35Payload: Equatable, Sendable {
    public let bytes: [UInt8]
    public let rawBase64: String

    public init(input: SCTE35PayloadInput) throws {
        let data: Data

        switch input {
        case let .base64(value):
            data = try Self.decodeBase64(value)
        case let .hex(value):
            data = try Self.decodeHex(value)
        case let .data(value):
            data = try Self.decodeData(value)
        }

        try Self.validateSection(data)
        self.bytes = [UInt8](data)
        self.rawBase64 = data.base64EncodedString()
    }

    private static func decodeBase64(_ value: String) throws -> Data {
        let normalized = try normalizedASCIIString(value)
        guard let data = Data(base64Encoded: normalized) else {
            throw SCTE35DecodeError.invalidBase64
        }
        return data
    }

    private static func decodeHex(_ value: String) throws -> Data {
        var normalized = try normalizedASCIIString(value)
        if normalized.hasPrefix("0x") || normalized.hasPrefix("0X") {
            normalized.removeFirst(2)
        }

        guard !normalized.isEmpty, normalized.count.isMultiple(of: 2) else {
            throw SCTE35DecodeError.invalidHex
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(normalized.count / 2)

        var index = normalized.startIndex
        while index < normalized.endIndex {
            let nextIndex = normalized.index(index, offsetBy: 2)
            let byteString = normalized[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else {
                throw SCTE35DecodeError.invalidHex
            }
            bytes.append(byte)
            index = nextIndex
        }

        return Data(bytes)
    }

    private static func decodeData(_ value: Data) throws -> Data {
        guard !value.isEmpty else {
            throw SCTE35DecodeError.emptyPayload
        }
        return value
    }

    private static func normalizedASCIIString(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SCTE35DecodeError.emptyPayload
        }
        guard trimmed.unicodeScalars.allSatisfy(\.isASCII) else {
            throw SCTE35DecodeError.invalidStringEncoding
        }
        return trimmed
    }

    private static func validateSection(_ data: Data) throws {
        guard !data.isEmpty else {
            throw SCTE35DecodeError.emptyPayload
        }

        // SCTE-35 sections always carry at least the table id plus the two-byte
        // section length field. Later parser tasks perform semantic validation.
        guard data.count >= 3 else {
            throw SCTE35DecodeError.malformedSection
        }
    }
}
