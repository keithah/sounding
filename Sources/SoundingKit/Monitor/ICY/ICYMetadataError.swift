import Foundation

/// Structural phase within a single ICY metadata frame read.
public enum ICYMetadataReadPhase: String, Equatable, Sendable {
    case audio
    case metadataLength
    case metadata
}

/// Safe, structural ICY metadata errors.
///
/// Errors deliberately expose only phase/source class/count information so callers can
/// wrap them in `MonitorError` without leaking raw stream chunks or metadata text.
public enum ICYMetadataError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidMetaInt(Int)
    case incompleteRead(phase: ICYMetadataReadPhase, expectedByteCount: Int, actualByteCount: Int)

    public var context: [String: String] {
        switch self {
        case let .invalidMetaInt(value):
            return [
                "sourceClass": "icy_stream",
                "phase": "configuration",
                "metaInt": String(value)
            ]
        case let .incompleteRead(phase, expectedByteCount, actualByteCount):
            return [
                "sourceClass": "icy_stream",
                "phase": phase.rawValue,
                "expectedByteCount": String(expectedByteCount),
                "actualByteCount": String(actualByteCount)
            ]
        }
    }

    public var description: String {
        switch self {
        case let .invalidMetaInt(value):
            return "ICY metadata framing failed: metaint must be positive, got \(value)."
        case let .incompleteRead(phase, expectedByteCount, actualByteCount):
            return "ICY metadata framing failed during \(phase.rawValue): expected \(expectedByteCount) bytes, got \(actualByteCount)."
        }
    }
}
