import Foundation

/// Phase where a monitor operation failed.
public enum MonitorPhase: String, Equatable, Sendable {
    case configuration
    case sourceOpen
    case ingest
    case decode
    case output
}

/// SoundingKit-owned monitor error contract with redacted source diagnostics.
public enum MonitorError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidTimeout(Double, source: String, streamType: StreamType)
    case invalidFilter(String)
    case notImplemented(phase: MonitorPhase, source: String, streamType: StreamType)

    public var description: String {
        switch self {
        case let .invalidTimeout(timeout, source, streamType):
            return "Monitor configuration failed for \(streamType.rawValue) source \(Self.redactedSourceDescription(source)): timeout must be non-negative, got \(timeout)."
        case let .invalidFilter(filter):
            return "Monitor configuration failed: unknown filter '\(filter)'."
        case let .notImplemented(phase, source, streamType):
            return "Monitor \(phase.rawValue) failed for \(streamType.rawValue) source \(Self.redactedSourceDescription(source)): monitor execution is not implemented."
        }
    }

    public static func redactedSourceDescription(_ source: String) -> String {
        guard var components = URLComponents(string: source), components.scheme != nil else {
            return source
        }

        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        return components.string ?? "[redacted-source]"
    }
}
