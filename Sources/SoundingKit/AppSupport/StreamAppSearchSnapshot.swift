import Foundation

public struct StreamAppSearchRequest: Equatable, Sendable {
    public var phrase: String
    public var streamIDs: [Int64]?
    public var speakerLabels: [String]?
    public var runStartedAtFrom: String?
    public var runStartedAtThrough: String?
    public var limit: Int
    public var contextSegments: Int
    public var player: AppPlayerTimelineSnapshot?
    public var refreshedAt: String

    public init(
        phrase: String,
        streamIDs: [Int64]? = nil,
        speakerLabels: [String]? = nil,
        runStartedAtFrom: String? = nil,
        runStartedAtThrough: String? = nil,
        limit: Int = 20,
        contextSegments: Int = 1,
        player: AppPlayerTimelineSnapshot? = nil,
        refreshedAt: String? = nil
    ) {
        self.phrase = phrase
        self.streamIDs = streamIDs
        self.speakerLabels = speakerLabels
        self.runStartedAtFrom = runStartedAtFrom
        self.runStartedAtThrough = runStartedAtThrough
        self.limit = limit
        self.contextSegments = contextSegments
        self.player = player
        self.refreshedAt = refreshedAt ?? Self.defaultRefreshTimestamp()
    }

    public static func defaultRefreshTimestamp() -> String {
        SoundingTimestampClock.timestamp()
    }
}

public struct StreamAppSearchSnapshot: Equatable, Sendable {
    public var request: StreamAppSearchRequest
    public var results: [StreamAppSearchResult]
    public var diagnostics: StreamAppSearchDiagnostics

    public init(
        request: StreamAppSearchRequest,
        results: [StreamAppSearchResult] = [],
        diagnostics: StreamAppSearchDiagnostics
    ) {
        self.request = request
        self.results = results
        self.diagnostics = diagnostics
    }
}

public struct StreamAppSearchResult: Equatable, Identifiable, Sendable {
    public var id: String
    public var streamID: Int64
    public var streamName: String?
    public var streamType: String
    public var sourceDescription: String
    public var runID: Int64
    public var runStartedAt: String?
    public var chunkID: Int64
    public var segmentID: Int64
    public var sequence: Int
    public var rawSpeakerLabel: String?
    public var speakerDisplay: StreamAppSpeakerDisplay
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var confidence: Double?
    public var occurrenceCount: Int
    public var context: [StreamAppSearchContext]
    public var words: [StreamAppTranscriptWord]
    public var isSeekable: Bool
    public var seekUnavailableMessage: String?

    public init(
        id: String,
        streamID: Int64,
        streamName: String?,
        streamType: String,
        sourceDescription: String,
        runID: Int64,
        runStartedAt: String?,
        chunkID: Int64,
        segmentID: Int64,
        sequence: Int,
        rawSpeakerLabel: String?,
        speakerDisplay: StreamAppSpeakerDisplay,
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        confidence: Double?,
        occurrenceCount: Int,
        context: [StreamAppSearchContext] = [],
        words: [StreamAppTranscriptWord] = [],
        isSeekable: Bool,
        seekUnavailableMessage: String? = nil
    ) {
        self.id = id
        self.streamID = streamID
        self.streamName = streamName
        self.streamType = streamType
        self.sourceDescription = IngestRedaction.sourceDescription(sourceDescription)
        self.runID = runID
        self.runStartedAt = runStartedAt
        self.chunkID = chunkID
        self.segmentID = segmentID
        self.sequence = sequence
        self.rawSpeakerLabel = rawSpeakerLabel
        self.speakerDisplay = speakerDisplay
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.confidence = confidence
        self.occurrenceCount = occurrenceCount
        self.context = context
        self.words = words
        self.isSeekable = isSeekable
        self.seekUnavailableMessage = seekUnavailableMessage.map(IngestRedaction.redact)
    }
}

public struct StreamAppSearchContext: Equatable, Identifiable, Sendable {
    public var id: String
    public var role: TranscriptQuery.ContextRole
    public var segmentID: Int64
    public var sequence: Int
    public var rawSpeakerLabel: String?
    public var speakerDisplay: StreamAppSpeakerDisplay
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String

    public init(
        id: String,
        role: TranscriptQuery.ContextRole,
        segmentID: Int64,
        sequence: Int,
        rawSpeakerLabel: String?,
        speakerDisplay: StreamAppSpeakerDisplay,
        startSeconds: Double,
        endSeconds: Double,
        text: String
    ) {
        self.id = id
        self.role = role
        self.segmentID = segmentID
        self.sequence = sequence
        self.rawSpeakerLabel = rawSpeakerLabel
        self.speakerDisplay = speakerDisplay
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }
}

public enum StreamAppSearchStatus: Equatable, Sendable {
    case ready
    case results
    case empty
    case failed

    public var title: String {
        switch self {
        case .ready: return "Search ready"
        case .results: return "Search results available"
        case .empty: return "No transcript results"
        case .failed: return "Search failed"
        }
    }
}

public struct StreamAppSearchDiagnostics: Equatable, Sendable {
    public var status: StreamAppSearchStatus
    public var statusMessage: String
    public var resultCount: Int
    public var refreshedAt: String
    public var validationErrors: [String]
    public var databaseErrorMessage: String?
    public var unseekableResultCount: Int
    public var bufferedSeekUnavailableMessages: [String]

    public init(
        status: StreamAppSearchStatus,
        statusMessage: String,
        resultCount: Int,
        refreshedAt: String,
        validationErrors: [String] = [],
        databaseErrorMessage: String? = nil,
        unseekableResultCount: Int = 0,
        bufferedSeekUnavailableMessages: [String] = []
    ) {
        self.status = status
        self.statusMessage = IngestRedaction.redact(statusMessage)
        self.resultCount = resultCount
        self.refreshedAt = refreshedAt
        self.validationErrors = validationErrors.map(IngestRedaction.redact)
        self.databaseErrorMessage = databaseErrorMessage.map(IngestRedaction.redact)
        self.unseekableResultCount = unseekableResultCount
        self.bufferedSeekUnavailableMessages = bufferedSeekUnavailableMessages.map(
            IngestRedaction.redact)
    }
}
