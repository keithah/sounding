import Foundation

/// Pure parser for SCTE-35 related HLS manifest marker tags.
///
/// Parsing is intentionally line-scoped and deterministic: no I/O, clocks, network, global
/// state, or SCTE-35 binary decoding happen here. Unsupported and malformed marker lines are
/// ignored so monitor failure reporting can remain phase-specific in later pipeline layers.
public struct HLSManifestMediaSegment: Equatable, Sendable {
    public let uri: String
    public let mediaSequence: String
    public let duration: String?
    public let scte35Tags: [HLSManifestSCTE35Tag]

    public init(
        uri: String,
        mediaSequence: String,
        duration: String? = nil,
        scte35Tags: [HLSManifestSCTE35Tag] = []
    ) {
        self.uri = uri
        self.mediaSequence = mediaSequence
        self.duration = duration
        self.scte35Tags = scte35Tags
    }
}

public enum HLSManifestParser {
    public static func parseMediaSegments(_ manifest: String) -> [HLSManifestMediaSegment] {
        var mediaSequence = 0
        var pendingTags = [HLSManifestSCTE35Tag]()
        var pendingDuration: String?
        var segments = [HLSManifestMediaSegment]()

        for rawLine in manifest.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = normalizedMediaSequence(from: line)
                continue
            }

            if line.hasPrefix("#EXTINF:") {
                pendingDuration = parseExtInfDuration(line)
                continue
            }

            if line.hasPrefix("#") {
                if let tag = parseTagLine(line) {
                    pendingTags.append(tag)
                }
                continue
            }

            segments.append(HLSManifestMediaSegment(
                uri: line,
                mediaSequence: String(mediaSequence),
                duration: pendingDuration,
                scte35Tags: pendingTags
            ))
            mediaSequence += 1
            pendingDuration = nil
            pendingTags.removeAll(keepingCapacity: true)
        }

        return segments
    }

    public static func parseTagLine(_ line: String) -> HLSManifestSCTE35Tag? {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return nil }

        let (tagName, rawBody) = splitTagNameAndBody(trimmedLine)

        switch tagName {
        case "#EXT-X-SCTE35":
            return parseExtXSCTE35(tagName: tagName, rawBody: rawBody)
        case "#EXT-OATCLS-SCTE35":
            return parsePayloadOnlyTag(kind: .oatclsSCTE35, tagName: tagName, rawBody: rawBody)
        case "#EXT-X-DATERANGE":
            return parseDateRange(tagName: tagName, rawBody: rawBody)
        case "#EXT-X-CUE-OUT-CONT":
            return parseCueOutCont(tagName: tagName, rawBody: rawBody)
        case "#EXT-X-CUE-OUT":
            return parseDirectCueOut(tagName: tagName, rawBody: rawBody)
        case "#EXT-X-CUE-IN":
            return parseDirectCueIn(tagName: tagName)
        default:
            return nil
        }
    }

    private static func parseExtXSCTE35(tagName: String, rawBody: String?) -> HLSManifestSCTE35Tag? {
        guard let body = normalizedBody(rawBody) else { return nil }
        let attributes = parseAttributes(body)

        if let cue = nonEmpty(attributes["CUE"]) {
            return HLSManifestSCTE35Tag(
                kind: .scte35,
                rawTagName: tagName,
                payload: cue,
                payloadEncodingHint: .base64,
                fields: jsonFields(from: attributes),
                sanitizedTagIdentity: "\(tagName)[CUE]"
            )
        }

        if attributes.keys.contains("CUE") {
            return nil
        }

        return HLSManifestSCTE35Tag(
            kind: .scte35,
            rawTagName: tagName,
            payload: body,
            payloadEncodingHint: .base64,
            fields: [:],
            sanitizedTagIdentity: tagName
        )
    }

    private static func parsePayloadOnlyTag(
        kind: HLSManifestSCTE35Tag.Kind,
        tagName: String,
        rawBody: String?
    ) -> HLSManifestSCTE35Tag? {
        guard let payload = normalizedBody(rawBody) else { return nil }

        return HLSManifestSCTE35Tag(
            kind: kind,
            rawTagName: tagName,
            payload: payload,
            payloadEncodingHint: .base64,
            fields: [:],
            sanitizedTagIdentity: tagName
        )
    }

    private static func parseDateRange(tagName: String, rawBody: String?) -> HLSManifestSCTE35Tag? {
        guard let body = normalizedBody(rawBody) else { return nil }
        let attributes = parseAttributes(body)

        if let payload = nonEmpty(attributes["SCTE35-OUT"]) {
            return HLSManifestSCTE35Tag(
                kind: .daterange,
                rawTagName: tagName,
                payload: payload,
                payloadEncodingHint: .hex,
                fields: jsonFields(from: attributes),
                sanitizedTagIdentity: "\(tagName)[SCTE35-OUT]"
            )
        }

        if let payload = nonEmpty(attributes["SCTE35-IN"]) {
            return HLSManifestSCTE35Tag(
                kind: .daterange,
                rawTagName: tagName,
                payload: payload,
                payloadEncodingHint: .hex,
                fields: jsonFields(from: attributes),
                sanitizedTagIdentity: "\(tagName)[SCTE35-IN]"
            )
        }

        return nil
    }

    private static func parseCueOutCont(tagName: String, rawBody: String?) -> HLSManifestSCTE35Tag? {
        guard let body = normalizedBody(rawBody) else { return nil }
        let attributes = parseAttributes(body)
        guard let payload = nonEmpty(attributes["SCTE35"]) else { return nil }

        return HLSManifestSCTE35Tag(
            kind: .cueOutCont,
            rawTagName: tagName,
            payload: payload,
            payloadEncodingHint: .base64,
            fields: jsonFields(from: attributes),
            sanitizedTagIdentity: "\(tagName)[SCTE35]"
        )
    }

    private static func parseDirectCueOut(tagName: String, rawBody: String?) -> HLSManifestSCTE35Tag {
        var fields: [String: JSONValue] = ["cue": .string("out")]

        if let body = normalizedBody(rawBody) {
            let attributes = parseAttributes(body)
            if attributes.isEmpty {
                fields["duration"] = .string(body)
            } else {
                fields.merge(jsonFields(from: attributes)) { _, new in new }
            }
        }

        return HLSManifestSCTE35Tag(
            kind: .cueOut,
            rawTagName: tagName,
            fields: fields,
            sanitizedTagIdentity: tagName
        )
    }

    private static func parseDirectCueIn(tagName: String) -> HLSManifestSCTE35Tag {
        HLSManifestSCTE35Tag(
            kind: .cueIn,
            rawTagName: tagName,
            fields: ["cue": .string("in")],
            sanitizedTagIdentity: tagName
        )
    }

    private static func normalizedMediaSequence(from line: String) -> Int {
        let (_, rawBody) = splitTagNameAndBody(line)
        guard let rawBody,
              let value = Int(rawBody.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }

        return max(0, value)
    }

    private static func parseExtInfDuration(_ line: String) -> String? {
        let (_, rawBody) = splitTagNameAndBody(line)
        guard let rawBody else { return nil }
        let duration = rawBody.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return duration?.isEmpty == false ? duration : nil
    }

    private static func splitTagNameAndBody(_ line: String) -> (String, String?) {
        guard let colonIndex = line.firstIndex(of: ":") else {
            return (line, nil)
        }

        let tagName = String(line[..<colonIndex])
        let bodyStart = line.index(after: colonIndex)
        return (tagName, String(line[bodyStart...]))
    }

    private static func normalizedBody(_ rawBody: String?) -> String? {
        guard let rawBody else { return nil }
        let trimmed = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func jsonFields(from attributes: [String: String]) -> [String: JSONValue] {
        attributes.reduce(into: [String: JSONValue]()) { result, pair in
            result[pair.key] = .string(pair.value)
        }
    }

    private static func parseAttributes(_ body: String) -> [String: String] {
        splitCommaAware(body).reduce(into: [String: String]()) { result, part in
            guard let separatorIndex = part.firstIndex(of: "=") else { return }
            let key = String(part[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }

            let valueStart = part.index(after: separatorIndex)
            let rawValue = String(part[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            result[key] = unquote(rawValue)
        }
    }

    private static func splitCommaAware(_ value: String) -> [String] {
        var parts = [String]()
        var current = String()
        var isInsideQuotes = false

        for character in value {
            switch character {
            case "\"":
                isInsideQuotes.toggle()
                current.append(character)
            case "," where !isInsideQuotes:
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
              value.first == "\"",
              value.last == "\"" else {
            return value
        }

        return String(value.dropFirst().dropLast())
    }
}
