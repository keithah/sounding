/// A SoundingKit-owned semantic ad marker ready for tidemark-compatible JSON output.
///
/// Optional public fields deliberately encode as explicit JSON nulls so downstream
/// consumers can rely on a stable object shape. `breakDuration` is retained as a
/// normalized in-memory convenience for parsers, but it is not a top-level JSON key;
/// callers that need it in serialized output should include `Fields["BreakDuration"]`.
public struct AdMarker: Encodable, Equatable, Sendable {
    public var type: String
    public var classification: MarkerClassification
    public var source: String
    public var tag: String?
    public var pts: Double?
    public var segment: String?
    public var rawBase64: String?
    public var command: JSONValue?
    public var descriptors: [JSONValue]
    public var tags: [String: JSONValue]
    public var fields: [String: JSONValue]
    public var timestamp: String?
    public var breakDuration: Double?

    public init(
        type: String,
        classification: MarkerClassification,
        source: String,
        tag: String? = nil,
        pts: Double? = nil,
        segment: String? = nil,
        rawBase64: String? = nil,
        command: JSONValue? = nil,
        descriptors: [JSONValue] = [],
        tags: [String: JSONValue] = [:],
        fields: [String: JSONValue] = [:],
        timestamp: String? = nil,
        breakDuration: Double? = nil
    ) {
        self.type = type
        self.classification = classification
        self.source = source
        self.tag = tag
        self.pts = pts
        self.segment = segment
        self.rawBase64 = rawBase64
        self.command = command
        self.descriptors = descriptors
        self.tags = tags
        self.fields = fields
        self.timestamp = timestamp
        self.breakDuration = breakDuration
    }

    private enum CodingKeys: String, CodingKey {
        case type = "Type"
        case classification = "Classification"
        case source = "Source"
        case tag = "Tag"
        case pts = "PTS"
        case segment = "Segment"
        case rawBase64 = "RawBase64"
        case command = "Command"
        case descriptors = "Descriptors"
        case tags = "Tags"
        case fields = "Fields"
        case timestamp = "Timestamp"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(type, forKey: .type)
        try container.encode(classification, forKey: .classification)
        try container.encode(source, forKey: .source)
        try encodeNullable(tag, to: &container, forKey: .tag)
        try encodeNullable(pts, to: &container, forKey: .pts)
        try encodeNullable(segment, to: &container, forKey: .segment)
        try encodeNullable(rawBase64, to: &container, forKey: .rawBase64)
        try encodeNullable(command, to: &container, forKey: .command)
        try container.encode(descriptors, forKey: .descriptors)
        try container.encode(tags, forKey: .tags)
        try container.encode(fields, forKey: .fields)
        try encodeNullable(timestamp, to: &container, forKey: .timestamp)
    }

    private func encodeNullable<Value: Encodable>(
        _ value: Value?,
        to container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}
