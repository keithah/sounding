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
    case operationFailed(
        phase: MonitorPhase,
        source: String,
        streamType: StreamType,
        context: [String: String],
        reason: String
    )

    public var description: String {
        switch self {
        case let .invalidTimeout(timeout, source, streamType):
            return "Monitor configuration failed for \(streamType.rawValue) source \(Self.redactedSourceDescription(source)): timeout must be non-negative, got \(timeout)."
        case let .invalidFilter(filter):
            return "Monitor configuration failed: unknown filter '\(filter)'."
        case let .notImplemented(phase, source, streamType):
            return "Monitor \(phase.rawValue) failed for \(streamType.rawValue) source \(Self.redactedSourceDescription(source)): monitor execution is not implemented."
        case let .operationFailed(phase, source, streamType, context, reason):
            let contextDescription = Self.redactedContextDescription(context)
            let safeReason = Self.redactedReasonDescription(reason, phase: phase)
            return "Monitor \(phase.rawValue) failed for \(streamType.rawValue) source \(Self.redactedSourceDescription(source))\(contextDescription): \(safeReason)."
        }
    }

    public static func redactedSourceDescription(_ source: String) -> String {
        guard var components = URLComponents(string: source), components.scheme != nil else {
            return redactedRelativeSourceDescription(source)
        }

        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        return components.string ?? "[redacted-source]"
    }

    private static func redactedRelativeSourceDescription(_ source: String) -> String {
        var safe = source
        if let fragmentIndex = safe.firstIndex(of: "#") {
            safe = String(safe[..<fragmentIndex])
        }
        if let queryIndex = safe.firstIndex(of: "?") {
            safe = String(safe[..<queryIndex])
        }
        if let atIndex = safe.lastIndex(of: "@") {
            safe = String(safe[safe.index(after: atIndex)...])
        }
        safe = redactSecretAssignments(in: safe)
        safe = redactCredentialLikePathSegments(in: safe)
        return safe
    }

    private static func redactSecretAssignments(in value: String) -> String {
        value.replacingOccurrences(
            of: #"(?i)\b(token|access_token|api[_-]?key|secret|password|passwd|pwd)=([^/\s?&#]+)"#,
            with: "$1=[redacted]",
            options: .regularExpression
        )
    }

    private static func redactCredentialLikePathSegments(in value: String) -> String {
        value.replacingOccurrences(
            of: #"(?i)\b(user|username|login|account|client):([^/\s?&#]+)"#,
            with: "$1:[redacted]",
            options: .regularExpression
        )
    }

    private static func redactedContextDescription(_ context: [String: String]) -> String {
        guard !context.isEmpty else { return "" }

        let pairs = context.keys.sorted().map { key in
            "\(key)=\(redactedContextValue(context[key] ?? "", forKey: key))"
        }
        return " (\(pairs.joined(separator: ", ")))"
    }

    private static func redactedContextValue(_ value: String, forKey key: String) -> String {
        switch key {
        case "outputPath", "jsonOut", "path":
            return "[redacted]"
        case "source", "segmentURI", "manifestURI", "url", "uri":
            return redactedSourceDescription(value)
        default:
            return value
        }
    }

    private static func redactedReasonDescription(_ reason: String, phase: MonitorPhase) -> String {
        switch phase {
        case .output:
            return "[redacted-output-error]"
        case .configuration, .sourceOpen, .ingest, .decode:
            return redactedSourceDescription(reason)
        }
    }
}
