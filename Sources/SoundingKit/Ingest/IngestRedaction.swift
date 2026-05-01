import Foundation

/// SoundingKit-owned redaction boundary for ingest operational text.
///
/// Ingest failures can include full source URLs, Foundation filesystem paths, temporary
/// provider audio paths, model cache directories, and secret-like key/value pairs. This
/// helper keeps persisted diagnostics and CLI-facing messages useful while stripping
/// path-sensitive and credential-bearing material before it crosses the ingest boundary.
public enum IngestRedaction {
    /// Redacts arbitrary prose emitted by decoders, providers, Foundation, or CLI adapters.
    public static func redact(_ value: String) -> String {
        var safe = redactURLTokens(in: value)
        safe = redactSecretAssignments(in: safe)
        safe = redactCredentialLikeSegments(in: safe)
        safe = redactAbsolutePaths(in: safe)
        return safe
    }

    /// Redacts a structured source/URI value while preserving safe network host/path identity.
    public static func sourceDescription(_ source: String) -> String {
        guard var components = URLComponents(string: source), let scheme = components.scheme else {
            if source.hasPrefix("/") || source.hasPrefix("./") || source.hasPrefix("../")
                || source.contains("/")
            {
                return "[redacted-path]"
            }
            return redact(source)
        }

        let lowercasedScheme = scheme.lowercased()
        if lowercasedScheme == "file" {
            return "[redacted-path]"
        }

        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        if components.host == nil, lowercasedScheme != "udp" {
            return "\(scheme)://[redacted-source]"
        }

        return components.string ?? "[redacted-source]"
    }

    /// Redacts only string leaves in diagnostic context while preserving structure and numbers.
    public static func context(_ context: [String: JSONValue]?) -> [String: JSONValue]? {
        guard let context else { return nil }
        return context.mapValues(redactJSONValue)
    }

    /// Redacts provider/model labels before they are surfaced as progress text.
    public static func component(_ value: String) -> String {
        redact(value)
    }

    private static func redactJSONValue(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text):
            return .string(redact(text))
        case .object(let object):
            return .object(object.mapValues(redactJSONValue))
        case .array(let values):
            return .array(values.map(redactJSONValue))
        case .number, .bool, .null:
            return value
        }
    }

    private static func redactURLTokens(in value: String) -> String {
        let pattern = #"\b[A-Za-z][A-Za-z0-9+.-]*://[^\s\"'<>)]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let nsValue = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
        guard !matches.isEmpty else { return value }

        var result = value
        for match in matches.reversed() {
            let token = nsValue.substring(with: match.range)
            let replacement = sourceDescription(token)
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    private static func redactSecretAssignments(in value: String) -> String {
        value.replacingOccurrences(
            of:
                #"(?i)\b(token|access_token|api[_-]?key|secret|password|passwd|pwd|key)\s*=\s*([^\s&;,\"']+)"#,
            with: "$1=[redacted]",
            options: .regularExpression
        )
    }

    private static func redactCredentialLikeSegments(in value: String) -> String {
        value.replacingOccurrences(
            of: #"(?i)\b(user|username|login|account|client):([^/\s?&#]+)"#,
            with: "$1:[redacted]",
            options: .regularExpression
        )
    }

    private static func redactAbsolutePaths(in value: String) -> String {
        value.replacingOccurrences(
            of:
                #"(?<!:)\/(?:Users|tmp|private\/tmp|var\/folders|var\/tmp|Volumes|Applications|Library)\/[^\s\"'<>)]*"#,
            with: "[redacted-path]",
            options: .regularExpression
        )
    }
}
