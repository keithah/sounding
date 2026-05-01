import Foundation

public struct StreamAppTimelineRequest: Equatable, Sendable {
    public var streamID: Int64
    public var player: AppPlayerTimelineSnapshot?
    public var paragraphLimit: Int
    public var wordLimitPerParagraph: Int
    public var metadataLimit: Int
    public var timelineLimit: Int
    public var lookbackSeconds: Double?
    public var focusedSegmentID: Int64?
    public var refreshedAt: String

    public init(
        streamID: Int64,
        player: AppPlayerTimelineSnapshot? = nil,
        paragraphLimit: Int = 50,
        wordLimitPerParagraph: Int = 40,
        metadataLimit: Int = 10,
        timelineLimit: Int = 100,
        lookbackSeconds: Double? = 300,
        focusedSegmentID: Int64? = nil,
        refreshedAt: String? = nil
    ) {
        self.streamID = streamID
        self.player = player
        self.paragraphLimit = paragraphLimit
        self.wordLimitPerParagraph = wordLimitPerParagraph
        self.metadataLimit = metadataLimit
        self.timelineLimit = timelineLimit
        self.lookbackSeconds = lookbackSeconds
        self.focusedSegmentID = focusedSegmentID
        self.refreshedAt = refreshedAt ?? Self.defaultRefreshTimestamp()
    }

    private static func defaultRefreshTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

public struct StreamAppTimelineSnapshot: Equatable, Sendable {
    public var streamID: Int64
    public var transcriptParagraphs: [StreamAppTranscriptParagraph]
    public var speakers: [StreamAppSpeakerDisplay]
    public var currentMetadata: StreamAppMetadataItem?
    public var recentMetadata: [StreamAppMetadataItem]
    public var timelineItems: [StreamAppTimelineItem]
    public var diagnostics: StreamAppTimelineDiagnostics

    public init(
        streamID: Int64,
        transcriptParagraphs: [StreamAppTranscriptParagraph] = [],
        speakers: [StreamAppSpeakerDisplay] = [],
        currentMetadata: StreamAppMetadataItem? = nil,
        recentMetadata: [StreamAppMetadataItem] = [],
        timelineItems: [StreamAppTimelineItem] = [],
        diagnostics: StreamAppTimelineDiagnostics
    ) {
        self.streamID = streamID
        self.transcriptParagraphs = transcriptParagraphs
        self.speakers = speakers
        self.currentMetadata = currentMetadata
        self.recentMetadata = recentMetadata
        self.timelineItems = timelineItems
        self.diagnostics = diagnostics
    }
}

public struct StreamAppTranscriptParagraph: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var streamID: Int64
    public var runID: Int64
    public var chunkID: Int64
    public var sequence: Int
    public var speakerDisplay: StreamAppSpeakerDisplay
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var confidence: Double?
    public var words: [StreamAppTranscriptWord]

    public init(
        id: Int64,
        streamID: Int64,
        runID: Int64,
        chunkID: Int64,
        sequence: Int,
        speakerDisplay: StreamAppSpeakerDisplay,
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        confidence: Double?,
        words: [StreamAppTranscriptWord] = []
    ) {
        self.id = id
        self.streamID = streamID
        self.runID = runID
        self.chunkID = chunkID
        self.sequence = sequence
        self.speakerDisplay = speakerDisplay
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.confidence = confidence
        self.words = words
    }
}

public struct StreamAppTranscriptWord: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var segmentID: Int64
    public var sequence: Int
    public var speakerDisplay: StreamAppSpeakerDisplay
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var confidence: Double?

    public init(
        id: Int64,
        segmentID: Int64,
        sequence: Int,
        speakerDisplay: StreamAppSpeakerDisplay,
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        confidence: Double?
    ) {
        self.id = id
        self.segmentID = segmentID
        self.sequence = sequence
        self.speakerDisplay = speakerDisplay
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.confidence = confidence
    }
}

public struct StreamAppSpeakerDisplay: Equatable, Identifiable, Sendable {
    public var rawLabel: String
    public var displayLabel: String
    public var colorToken: String
    public var updatedAt: String?

    public var id: String { rawLabel }

    public init(rawLabel: String, displayLabel: String, colorToken: String, updatedAt: String? = nil) {
        self.rawLabel = rawLabel
        self.displayLabel = displayLabel
        self.colorToken = colorToken
        self.updatedAt = updatedAt
    }
}

public enum StreamAppMetadataKind: String, Equatable, Sendable {
    case song
    case event
}

public struct StreamAppMetadataItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: StreamAppMetadataKind
    public var startSeconds: Double
    public var endSeconds: Double?
    public var title: String
    public var subtitle: String?
    public var confidence: Double?

    public init(
        id: String,
        kind: StreamAppMetadataKind,
        startSeconds: Double,
        endSeconds: Double? = nil,
        title: String,
        subtitle: String? = nil,
        confidence: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.title = title
        self.subtitle = subtitle
        self.confidence = confidence
    }
}

public enum StreamAppTimelineItemKind: String, Equatable, Sendable {
    case transcript
    case song
    case event
}

public struct StreamAppTimelineItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: StreamAppTimelineItemKind
    public var startSeconds: Double
    public var endSeconds: Double?
    public var title: String
    public var subtitle: String?
    public var speakerDisplay: StreamAppSpeakerDisplay?
    public var isSeekable: Bool

    public init(
        id: String,
        kind: StreamAppTimelineItemKind,
        startSeconds: Double,
        endSeconds: Double? = nil,
        title: String,
        subtitle: String? = nil,
        speakerDisplay: StreamAppSpeakerDisplay? = nil,
        isSeekable: Bool
    ) {
        self.id = id
        self.kind = kind
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.title = title
        self.subtitle = subtitle
        self.speakerDisplay = speakerDisplay
        self.isSeekable = isSeekable
    }
}

public struct StreamAppTimelineDiagnostics: Equatable, Sendable {
    public var latestSegmentEndSeconds: Double?
    public var playerPositionSeconds: Double?
    public var playerLiveEdgeSeconds: Double?
    public var lagSeconds: Double?
    public var focusedSegmentID: Int64?
    public var refreshedAt: String
    public var validationErrors: [String]
    public var bufferedSeekUnavailableMessage: String?

    public init(
        latestSegmentEndSeconds: Double? = nil,
        playerPositionSeconds: Double? = nil,
        playerLiveEdgeSeconds: Double? = nil,
        lagSeconds: Double? = nil,
        focusedSegmentID: Int64? = nil,
        refreshedAt: String,
        validationErrors: [String] = [],
        bufferedSeekUnavailableMessage: String? = nil
    ) {
        self.latestSegmentEndSeconds = latestSegmentEndSeconds
        self.playerPositionSeconds = playerPositionSeconds
        self.playerLiveEdgeSeconds = playerLiveEdgeSeconds
        self.lagSeconds = lagSeconds
        self.focusedSegmentID = focusedSegmentID
        self.refreshedAt = refreshedAt
        self.validationErrors = validationErrors.map(IngestRedaction.redact)
        self.bufferedSeekUnavailableMessage = bufferedSeekUnavailableMessage.map(IngestRedaction.redact)
    }
}
