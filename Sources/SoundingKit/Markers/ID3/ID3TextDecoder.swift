import Foundation

enum ID3TextDecoder {
    static func decode(_ payload: Data) throws -> [String] {
        let bytes = [UInt8](payload)
        guard let encoding = bytes.first else { return [] }
        let body = Array(bytes.dropFirst())

        switch encoding {
        case 0:
            return splitSingleByteStrings(body).map { latin1String(from: $0) }
        case 1:
            return try decodeUTF16WithBOM(body)
        case 2:
            return try splitDoubleByteStrings(body).map { try utf16String(from: $0, endian: .big) }
        case 3:
            return splitSingleByteStrings(body).map { String(decoding: $0, as: UTF8.self) }
        default:
            throw ID3DecodeError.unsupportedFrameEncoding
        }
    }

    private enum Endian {
        case little
        case big
    }

    private static func splitSingleByteStrings(_ bytes: [UInt8]) -> [[UInt8]] {
        var parts: [[UInt8]] = []
        var current: [UInt8] = []

        for byte in bytes {
            if byte == 0 {
                parts.append(current)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
        }

        if !current.isEmpty || parts.isEmpty {
            parts.append(current)
        }

        return parts.filter { !$0.isEmpty }
    }

    private static func splitDoubleByteStrings(_ bytes: [UInt8]) -> [[UInt8]] {
        var parts: [[UInt8]] = []
        var current: [UInt8] = []
        var index = 0

        while index + 1 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                parts.append(current)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(bytes[index])
                current.append(bytes[index + 1])
            }
            index += 2
        }

        if index < bytes.count {
            current.append(bytes[index])
        }

        if !current.isEmpty || parts.isEmpty {
            parts.append(current)
        }

        return parts.filter { !$0.isEmpty }
    }

    private static func latin1String(from bytes: [UInt8]) -> String {
        String(String.UnicodeScalarView(bytes.map { UnicodeScalar(Int($0))! }))
    }

    private static func decodeUTF16WithBOM(_ bytes: [UInt8]) throws -> [String] {
        guard bytes.count >= 2 else { return bytes.isEmpty ? [] : [latin1String(from: bytes)] }

        if bytes[0] == 0xFF, bytes[1] == 0xFE {
            return try splitDoubleByteStrings(Array(bytes.dropFirst(2))).map { try utf16String(from: $0, endian: .little) }
        }

        if bytes[0] == 0xFE, bytes[1] == 0xFF {
            return try splitDoubleByteStrings(Array(bytes.dropFirst(2))).map { try utf16String(from: $0, endian: .big) }
        }

        return try splitDoubleByteStrings(bytes).map { try utf16String(from: $0, endian: .big) }
    }

    private static func utf16String(from bytes: [UInt8], endian: Endian) throws -> String {
        guard bytes.count.isMultiple(of: 2) else { throw ID3DecodeError.malformedFrame }

        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)

        var index = 0
        while index < bytes.count {
            let first = UInt16(bytes[index])
            let second = UInt16(bytes[index + 1])
            switch endian {
            case .little:
                units.append(first | (second << 8))
            case .big:
                units.append((first << 8) | second)
            }
            index += 2
        }

        return String(decoding: units, as: UTF16.self)
    }
}
