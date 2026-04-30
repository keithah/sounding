import Foundation

/// Sanitized ID3 decoder failures.
///
/// Descriptions intentionally name only the failure class and safe bounded
/// context. They never include raw tag bytes, segment bytes, base64, URLs,
/// credentials, or parser internals.
public enum ID3DecodeError: Error, Equatable, CustomStringConvertible, Sendable {
    case unsupportedVersion(major: UInt8, context: String? = nil)
    case malformedSynchsafeSize
    case truncatedHeader
    case truncatedTag
    case tagTooLarge(maximum: Int, context: String? = nil)
    case malformedFrame
    case unsupportedFrameEncoding
    case unsupportedFrameFlags

    public var description: String {
        switch self {
        case let .unsupportedVersion(major, context):
            return scanDescription("unsupported ID3 major version \(major)", context: context)
        case .malformedSynchsafeSize:
            return scanDescription("tag size is not synchsafe")
        case .truncatedHeader:
            return scanDescription("tag header is truncated")
        case .truncatedTag:
            return scanDescription("declared tag bytes are truncated")
        case let .tagTooLarge(maximum, context):
            return scanDescription("tag exceeds maximum size \(maximum)", context: context)
        case .malformedFrame:
            return parseDescription("frame is malformed")
        case .unsupportedFrameEncoding:
            return parseDescription("frame encoding is unsupported")
        case .unsupportedFrameFlags:
            return parseDescription("frame flags are unsupported")
        }
    }

    private func scanDescription(_ reason: String, context: String? = nil) -> String {
        description(phase: "scan", reason: reason, context: context)
    }

    private func parseDescription(_ reason: String, context: String? = nil) -> String {
        description(phase: "parse", reason: reason, context: context)
    }

    private func description(phase: String, reason: String, context: String?) -> String {
        let contextSuffix = context.map { " (\($0))" } ?? ""
        return "ID3 \(phase) failed\(contextSuffix): \(reason)."
    }
}
