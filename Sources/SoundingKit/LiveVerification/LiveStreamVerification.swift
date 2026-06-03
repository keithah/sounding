import Foundation

/// A single stream entry from local-only live verification configuration.
public struct LiveStreamSpec: Codable, Equatable, Sendable {
    public var id: String
    public var source: String
    public var streamType: StreamType
    public var filter: String
    public var timeoutSeconds: Double?
    public var minimumMarkers: Int
    public var required: Bool

    public init(
        id: String,
        source: String,
        streamType: StreamType = .auto,
        filter: String = "all",
        timeoutSeconds: Double? = nil,
        minimumMarkers: Int = 1,
        required: Bool = true
    ) {
        self.id = id
        self.source = source
        self.streamType = streamType
        self.filter = filter
        self.timeoutSeconds = timeoutSeconds
        self.minimumMarkers = minimumMarkers
        self.required = required
    }
}

/// Local-only live verification configuration decoded by the CLI and executed by SoundingKit.
public struct LiveStreamVerificationConfig: Codable, Equatable, Sendable {
    public static let maximumAllowedConcurrentStreams = 64

    public var streams: [LiveStreamSpec]
    public var maxConcurrentStreams: Int?

    public init(streams: [LiveStreamSpec], maxConcurrentStreams: Int? = nil) throws {
        try Self.validate(streams: streams, maxConcurrentStreams: maxConcurrentStreams)
        self.streams = streams
        self.maxConcurrentStreams = maxConcurrentStreams
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let streams = try container.decode([LiveStreamSpec].self, forKey: .streams)
        let maxConcurrentStreams = try container.decodeIfPresent(
            Int.self,
            forKey: .maxConcurrentStreams
        )
        try Self.validate(streams: streams, maxConcurrentStreams: maxConcurrentStreams)
        self.streams = streams
        self.maxConcurrentStreams = maxConcurrentStreams
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(streams, forKey: .streams)
        try container.encodeIfPresent(maxConcurrentStreams, forKey: .maxConcurrentStreams)
    }

    private enum CodingKeys: String, CodingKey {
        case maxConcurrentStreams
        case streams
    }

    private static func validate(streams: [LiveStreamSpec], maxConcurrentStreams: Int?) throws {
        guard !streams.isEmpty else {
            throw LiveStreamVerificationError.configurationFailed("live verification requires at least one stream")
        }
        if let maxConcurrentStreams {
            guard maxConcurrentStreams > 0 else {
                throw LiveStreamVerificationError.configurationFailed("maxConcurrentStreams must be positive")
            }
            guard maxConcurrentStreams <= maximumAllowedConcurrentStreams else {
                throw LiveStreamVerificationError.configurationFailed("maxConcurrentStreams must be \(maximumAllowedConcurrentStreams) or less")
            }
        }

        for stream in streams {
            guard !stream.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LiveStreamVerificationError.configurationFailed("live verification stream id must not be empty")
            }
            guard !stream.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LiveStreamVerificationError.configurationFailed("live verification stream source must not be empty for stream id '\(stream.id)'")
            }
            guard stream.minimumMarkers >= 0 else {
                throw LiveStreamVerificationError.configurationFailed("minimumMarkers must be non-negative for stream id '\(stream.id)'")
            }
            if let timeoutSeconds = stream.timeoutSeconds, timeoutSeconds < 0 {
                throw LiveStreamVerificationError.configurationFailed("timeoutSeconds must be non-negative for stream id '\(stream.id)'")
            }
            do {
                _ = try MonitorFilter(normalizing: stream.filter)
            } catch {
                throw LiveStreamVerificationError.configurationFailed("filter is invalid for stream id '\(stream.id)'")
            }
        }
    }
}

/// Machine-readable live verification outcome category safe for JSON/NDJSON evidence.
public enum LiveStreamVerificationCategory: String, Codable, Equatable, Sendable {
    case passed
    case streamUnavailable = "stream_unavailable"
    case timeout
    case noMarkersObserved = "no_markers_observed"
    case parserAdapterRegression = "parser_adapter_regression"
    case unsupportedOrSkipped = "unsupported_or_skipped"
    case configurationFailure = "configuration_failure"
}

/// Sanitized diagnostic details preserved from SoundingKit monitor errors.
public struct LiveStreamVerificationDiagnostic: Codable, Equatable, Sendable {
    public var phase: String?
    public var streamType: String?
    public var sourceClass: String?
    public var message: String
    public var context: [String: String]

    public init(
        phase: String? = nil,
        streamType: String? = nil,
        sourceClass: String? = nil,
        message: String,
        context: [String: String] = [:]
    ) {
        self.phase = phase
        self.streamType = streamType
        self.sourceClass = sourceClass
        self.message = message
        self.context = context
    }
}

/// Per-stream live verification evidence. This intentionally stores `redactedSource` only.
public struct LiveStreamVerificationResult: Codable, Equatable, Sendable {
    public var id: String
    public var redactedSource: String
    public var streamType: StreamType
    public var resolvedStreamType: StreamType
    public var filter: String
    public var timeoutSeconds: Double?
    public var minimumMarkers: Int
    public var required: Bool
    public var category: LiveStreamVerificationCategory
    public var markerCount: Int
    public var durationMilliseconds: Int
    public var diagnostic: LiveStreamVerificationDiagnostic?

    public init(
        id: String,
        redactedSource: String,
        streamType: StreamType,
        resolvedStreamType: StreamType,
        filter: String,
        timeoutSeconds: Double?,
        minimumMarkers: Int,
        required: Bool,
        category: LiveStreamVerificationCategory,
        markerCount: Int,
        durationMilliseconds: Int,
        diagnostic: LiveStreamVerificationDiagnostic? = nil
    ) {
        self.id = id
        self.redactedSource = redactedSource
        self.streamType = streamType
        self.resolvedStreamType = resolvedStreamType
        self.filter = filter
        self.timeoutSeconds = timeoutSeconds
        self.minimumMarkers = minimumMarkers
        self.required = required
        self.category = category
        self.markerCount = markerCount
        self.durationMilliseconds = durationMilliseconds
        self.diagnostic = diagnostic
    }
}

/// Aggregate live verification evidence for a full config run.
public struct LiveStreamVerificationSummary: Codable, Equatable, Sendable {
    public var results: [LiveStreamVerificationResult]
    public var totalStreams: Int
    public var requiredFailures: Int
    public var optionalFailures: Int
    public var passed: Bool

    public init(results: [LiveStreamVerificationResult]) {
        self.results = results
        self.totalStreams = results.count
        self.requiredFailures = results.filter { $0.required && $0.category != .passed }.count
        self.optionalFailures = results.filter { !$0.required && $0.category != .passed }.count
        self.passed = requiredFailures == 0
    }
}

/// Live verification configuration/output error. Descriptions never echo raw stream sources.
public enum LiveStreamVerificationError: Error, Equatable, CustomStringConvertible, Sendable {
    case configurationFailed(String)
    case outputFailed(String)

    public var description: String {
        switch self {
        case let .configurationFailed(message):
            return "Live verification configuration failed: \(message)."
        case let .outputFailed(message):
            return "Live verification output failed: \(MonitorError.redactedSourceDescription(message))."
        }
    }
}
