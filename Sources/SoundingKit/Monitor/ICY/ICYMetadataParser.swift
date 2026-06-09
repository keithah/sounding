import Foundation

/// Pure parser for ICY/Icecast metadata blocks.
///
/// The parser has no network dependency. It accepts already-framed metadata bytes,
/// strips ICY null padding, parses semicolon-delimited key/value fields, and emits
/// one marker per changed non-empty metadata payload.
public struct ICYMetadataParser: Sendable {
    public static let requestHeaders = ["Icy-MetaData": "1"]
    public static let defaultMetaInt = 16_000

    private var lastMetadataSignature: String?

    public init() {
        self.lastMetadataSignature = nil
    }

    public mutating func marker(fromMetadataBlock metadata: Data) -> AdMarker? {
        let fields = Self.parseFields(from: metadata)
        guard let signature = Self.metadataSignature(from: fields) else { return nil }
        guard signature != lastMetadataSignature else { return nil }

        lastMetadataSignature = signature
        return Self.marker(from: fields)
    }

    public static func marker(from fields: [String: String]) -> AdMarker? {
        guard metadataSignature(from: fields) != nil else { return nil }

        var enrichedFields = fields
        enrichProgramFields(&enrichedFields)
        return AdMarker(
            type: "ICY",
            classification: .unknown,
            source: "icy_stream",
            fields: enrichedFields.reduce(into: [String: JSONValue]()) { result, field in
                result[field.key] = .string(field.value)
            }
        )
    }

    public static func parseFields(from metadata: Data) -> [String: String] {
        guard let sanitized = sanitizedMetadataString(from: metadata) else { return [:] }

        return parseFields(from: sanitized)
    }

    public static func sanitizedMetadataString(from metadata: Data) -> String? {
        guard !metadata.isEmpty else { return "" }
        let unpadded = metadata.prefix { byte in byte != 0 }
        guard !unpadded.isEmpty else { return "" }
        return String(data: Data(unpadded), encoding: .utf8)
    }

    private static func parseFields(from metadata: String) -> [String: String] {
        splitSemicolonAware(metadata).reduce(into: [String: String]()) { result, part in
            guard let separatorIndex = part.firstIndex(of: "=") else { return }

            let key = String(part[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }

            let valueStart = part.index(after: separatorIndex)
            let value = unquote(String(part[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines))
            result[key] = value
        }
    }

    private static func normalizedStreamTitle(from fields: [String: String]) -> String? {
        guard let rawTitle = fields["StreamTitle"] else { return nil }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func metadataSignature(from fields: [String: String]) -> String? {
        let normalizedPairs = fields.compactMap { key, value -> String? in
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty, !normalizedValue.isEmpty else { return nil }
            return "\(normalizedKey)=\(normalizedValue)"
        }
        .sorted()

        guard !normalizedPairs.isEmpty else { return nil }
        return normalizedPairs.joined(separator: "\u{1f}")
    }

    private static func enrichProgramFields(_ fields: inout [String: String]) {
        guard let streamTitle = normalizedStreamTitle(from: fields) else { return }
        for separator in [" - ", " – ", " — "] {
            let parts = streamTitle.components(separatedBy: separator)
            guard parts.count >= 2 else { continue }
            let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let title = parts.dropFirst().joined(separator: separator).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, !title.isEmpty else { continue }
            fields["Artist"] = fields["Artist"] ?? artist
            fields["Title"] = fields["Title"] ?? title
            return
        }
        fields["Title"] = fields["Title"] ?? streamTitle
    }

    private static func splitSemicolonAware(_ value: String) -> [String] {
        var parts = [String]()
        var current = String()
        var quote: Character?

        for character in value {
            switch character {
            case "'", "\"":
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
                current.append(character)
            case ";" where quote == nil:
                parts.append(current)
                current.removeAll(keepingCapacity: true)
            default:
                current.append(character)
            }
        }

        parts.append(current)
        return parts
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "'" || first == "\""),
              first == last else {
            return value
        }

        return String(value.dropFirst().dropLast())
    }
}
