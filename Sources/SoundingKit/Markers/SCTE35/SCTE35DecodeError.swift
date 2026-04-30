import Foundation

/// Sanitized SCTE-35 decoder failures.
///
/// Descriptions intentionally name only the failure class. They never include raw
/// SCTE-35 payload strings, packet bytes, source URLs, or caller-provided text.
public enum SCTE35DecodeError: Error, Equatable, CustomStringConvertible, Sendable {
    case emptyPayload
    case invalidStringEncoding
    case invalidBase64
    case invalidHex
    case malformedSection
    case unsupportedCommand
    case encryptedSection
    case boundedReadFailure

    public var description: String {
        switch self {
        case .emptyPayload:
            return "SCTE-35 decode failed: payload is empty."
        case .invalidStringEncoding:
            return "SCTE-35 decode failed: payload string must contain only ASCII characters."
        case .invalidBase64:
            return "SCTE-35 decode failed: payload is not valid base64."
        case .invalidHex:
            return "SCTE-35 decode failed: payload is not valid hexadecimal data."
        case .malformedSection:
            return "SCTE-35 decode failed: section is malformed."
        case .unsupportedCommand:
            return "SCTE-35 decode failed: command type is unsupported."
        case .encryptedSection:
            return "SCTE-35 decode failed: encrypted sections are unsupported."
        case .boundedReadFailure:
            return "SCTE-35 decode failed: attempted to read beyond available section bits."
        }
    }
}
