import Foundation

public enum AppVerifyLiveExpectation: String, Codable, Equatable, Sendable {
    case disabled
    case warn
    case strict
}

public struct AppVerifyLiveExpectations: Codable, Equatable, Sendable {
    public var transcript: AppVerifyLiveExpectation
    public var metadata: AppVerifyLiveExpectation

    public init(
        transcript: AppVerifyLiveExpectation = .warn,
        metadata: AppVerifyLiveExpectation = .warn
    ) {
        self.transcript = transcript
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            transcript: try container.decodeIfPresent(AppVerifyLiveExpectation.self, forKey: .transcript) ?? .warn,
            metadata: try container.decodeIfPresent(AppVerifyLiveExpectation.self, forKey: .metadata) ?? .warn
        )
    }

    private enum CodingKeys: String, CodingKey {
        case transcript
        case metadata
    }
}

public struct AppVerifyLiveStreamSpec: Codable, Equatable, Sendable {
    public var id: String
    public var source: String
    public var streamType: StreamType
    public var resolvedStreamType: StreamType
    public var redactedSource: String
    public var timeoutSeconds: Double
    public var maxChunks: Int
    public var required: Bool
    public var expectations: AppVerifyLiveExpectations

    public init(
        id: String,
        source: String,
        streamType: StreamType = .auto,
        timeoutSeconds: Double = AppVerifyLiveConfiguration.defaultTimeoutSeconds,
        maxChunks: Int = AppVerifyLiveConfiguration.defaultMaxChunks,
        required: Bool = true,
        expectations: AppVerifyLiveExpectations = AppVerifyLiveExpectations()
    ) {
        self.id = id
        self.source = source
        self.streamType = streamType
        self.resolvedStreamType = Self.resolvedTypeHint(streamType: streamType, source: source)
        self.redactedSource = AppVerifyEvidenceSanitizer.sourceDescription(source)
        self.timeoutSeconds = timeoutSeconds
        self.maxChunks = maxChunks
        self.required = required
        self.expectations = expectations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let source = try container.decode(String.self, forKey: .source)
        let streamType = try container.decodeIfPresent(StreamType.self, forKey: .streamType) ?? .auto
        let timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
            ?? AppVerifyLiveConfiguration.defaultTimeoutSeconds
        let maxChunks = try container.decodeIfPresent(Int.self, forKey: .maxChunks)
            ?? AppVerifyLiveConfiguration.defaultMaxChunks
        let required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
        let expectations = try container.decodeIfPresent(AppVerifyLiveExpectations.self, forKey: .expectations)
            ?? AppVerifyLiveExpectations()
        self.init(
            id: id,
            source: source,
            streamType: streamType,
            timeoutSeconds: timeoutSeconds,
            maxChunks: maxChunks,
            required: required,
            expectations: expectations
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case streamType
        case resolvedStreamType
        case redactedSource
        case timeoutSeconds
        case maxChunks
        case required
        case expectations
    }

    fileprivate func validated(index: Int) throws -> AppVerifyLiveStreamSpec {
        let safeID = AppVerifyEvidenceSanitizer.redact(id)
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppVerifyLiveConfigurationError.validationFailed("live stream at index \(index) id must not be blank")
        }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppVerifyLiveConfigurationError.validationFailed("live stream '\(safeID)' source must not be blank")
        }
        guard Self.supportedExplicitTypes.contains(streamType) || streamType == .auto else {
            throw AppVerifyLiveConfigurationError.validationFailed("live stream '\(safeID)' uses unsupported stream type '\(streamType.rawValue)'")
        }
        guard resolvedStreamType != .auto else {
            throw AppVerifyLiveConfigurationError.validationFailed("live stream '\(safeID)' auto stream type could not be resolved; use an .m3u8 source or explicit icecast/icy")
        }
        guard timeoutSeconds.isFinite,
              timeoutSeconds >= AppVerifyLiveConfiguration.minimumTimeoutSeconds,
              timeoutSeconds <= AppVerifyLiveConfiguration.maximumTimeoutSeconds
        else {
            throw AppVerifyLiveConfigurationError.validationFailed(
                "live stream '\(safeID)' timeoutSeconds must be between \(AppVerifyLiveConfiguration.minimumTimeoutSeconds) and \(AppVerifyLiveConfiguration.maximumTimeoutSeconds)"
            )
        }
        guard maxChunks >= AppVerifyLiveConfiguration.minimumMaxChunks,
              maxChunks <= AppVerifyLiveConfiguration.maximumMaxChunks
        else {
            throw AppVerifyLiveConfigurationError.validationFailed(
                "live stream '\(safeID)' maxChunks must be between \(AppVerifyLiveConfiguration.minimumMaxChunks) and \(AppVerifyLiveConfiguration.maximumMaxChunks)"
            )
        }
        guard required || (expectations.transcript != .strict && expectations.metadata != .strict) else {
            throw AppVerifyLiveConfigurationError.validationFailed("live stream '\(safeID)' optional streams cannot use strict transcript or metadata expectations")
        }
        var copy = self
        copy.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.resolvedStreamType = Self.resolvedTypeHint(streamType: streamType, source: copy.source)
        copy.redactedSource = AppVerifyEvidenceSanitizer.sourceDescription(copy.source)
        return copy
    }

    private static let supportedExplicitTypes: Set<StreamType> = [.hls, .icecast, .icy]

    private static func resolvedTypeHint(streamType: StreamType, source: String) -> StreamType {
        guard streamType == .auto else { return streamType }
        return sourceLooksLikeHLS(source) ? .hls : .auto
    }

    private static func sourceLooksLikeHLS(_ source: String) -> Bool {
        if let components = URLComponents(string: source) {
            return components.path.lowercased().hasSuffix(".m3u8")
        }
        return source.split(separator: "?", maxSplits: 1).first?
            .split(separator: "#", maxSplits: 1).first?
            .lowercased()
            .hasSuffix(".m3u8") == true
    }
}

public struct AppVerifyLiveConfiguration: Codable, Equatable, Sendable {
    public static let defaultTimeoutSeconds: Double = 8
    public static let minimumTimeoutSeconds: Double = 0.05
    public static let maximumTimeoutSeconds: Double = 30
    public static let defaultMaxChunks: Int = 4
    public static let minimumMaxChunks: Int = 1
    public static let maximumMaxChunks: Int = 32
    public static let maximumStreamCount: Int = 32

    public var streams: [AppVerifyLiveStreamSpec]

    public init(streams: [AppVerifyLiveStreamSpec]) throws {
        try Self.validate(streams: streams)
        self.streams = try streams.enumerated().map { try $0.element.validated(index: $0.offset) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let streams = try container.decode([AppVerifyLiveStreamSpec].self, forKey: .streams)
        try self.init(streams: streams)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(streams, forKey: .streams)
    }

    private enum CodingKeys: String, CodingKey {
        case streams
    }

    private static func validate(streams: [AppVerifyLiveStreamSpec]) throws {
        guard !streams.isEmpty else {
            throw AppVerifyLiveConfigurationError.validationFailed("app-verify live requires at least one stream")
        }
        guard streams.count <= maximumStreamCount else {
            throw AppVerifyLiveConfigurationError.validationFailed("app-verify live supports at most \(maximumStreamCount) streams per sequential run")
        }
    }
}

public enum AppVerifyLiveConfigurationError: Error, Equatable, CustomStringConvertible, Sendable {
    case validationFailed(String)

    public var description: String {
        switch self {
        case .validationFailed(let message):
            return "App verification live configuration failed: \(AppVerifyEvidenceSanitizer.redact(message))."
        }
    }
}
