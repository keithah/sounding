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
    public var hideDeterministicUnknownSongs: Bool
    public var transcriptionPolicy: StreamTranscriptionPolicy
    public var refreshedAt: String

    public init(
        streamID: Int64,
        player: AppPlayerTimelineSnapshot? = nil,
        paragraphLimit: Int = 10_000,
        wordLimitPerParagraph: Int = 250,
        metadataLimit: Int = 10_000,
        timelineLimit: Int = 20_000,
        lookbackSeconds: Double? = nil,
        focusedSegmentID: Int64? = nil,
        hideDeterministicUnknownSongs: Bool = false,
        transcriptionPolicy: StreamTranscriptionPolicy = .defaultValue,
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
        self.hideDeterministicUnknownSongs = hideDeterministicUnknownSongs
        self.transcriptionPolicy = transcriptionPolicy
        self.refreshedAt = refreshedAt ?? Self.defaultRefreshTimestamp()
    }

    private static func defaultRefreshTimestamp() -> String {
        SoundingTimestampClock.timestamp()
    }
}

public struct StreamAppTimelineSnapshot: Equatable, Sendable {
    public var streamID: Int64
    public var transcriptParagraphs: [StreamAppTranscriptParagraph]
    public var speakers: [StreamAppSpeakerDisplay]
    public var currentMetadata: StreamAppMetadataItem?
    public var recentMetadata: [StreamAppMetadataItem]
    public var timelineItems: [StreamAppTimelineItem]
    public var timelineRail: StreamAppTimelineRailSnapshot
    public var diagnostics: StreamAppTimelineDiagnostics

    public init(
        streamID: Int64,
        transcriptParagraphs: [StreamAppTranscriptParagraph] = [],
        speakers: [StreamAppSpeakerDisplay] = [],
        currentMetadata: StreamAppMetadataItem? = nil,
        recentMetadata: [StreamAppMetadataItem] = [],
        timelineItems: [StreamAppTimelineItem] = [],
        timelineRail: StreamAppTimelineRailSnapshot = StreamAppTimelineRailSnapshot(
            visibleStartSeconds: 0,
            visibleEndSeconds: 0
        ),
        diagnostics: StreamAppTimelineDiagnostics
    ) {
        self.streamID = streamID
        self.transcriptParagraphs = transcriptParagraphs
        self.speakers = speakers
        self.currentMetadata = currentMetadata
        self.recentMetadata = recentMetadata
        self.timelineItems = timelineItems
        self.timelineRail = timelineRail
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
    public var startTimestamp: String?
    public var endTimestamp: String?
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
        startTimestamp: String? = nil,
        endTimestamp: String? = nil,
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
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
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
    public var startTimestamp: String?
    public var endTimestamp: String?
    public var title: String
    public var artist: String?
    public var subtitle: String?
    public var confidence: Double?
    public var source: String?
    public var isUnknown: Bool

    public init(
        id: String,
        kind: StreamAppMetadataKind,
        startSeconds: Double,
        endSeconds: Double? = nil,
        startTimestamp: String? = nil,
        endTimestamp: String? = nil,
        title: String,
        artist: String? = nil,
        subtitle: String? = nil,
        confidence: Double? = nil,
        source: String? = nil,
        isUnknown: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.title = title
        self.artist = artist
        self.subtitle = subtitle
        self.confidence = confidence
        self.source = source
        self.isUnknown = isUnknown
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
    public var startTimestamp: String?
    public var endTimestamp: String?
    public var title: String
    public var subtitle: String?
    public var speakerDisplay: StreamAppSpeakerDisplay?
    public var isSeekable: Bool

    public init(
        id: String,
        kind: StreamAppTimelineItemKind,
        startSeconds: Double,
        endSeconds: Double? = nil,
        startTimestamp: String? = nil,
        endTimestamp: String? = nil,
        title: String,
        subtitle: String? = nil,
        speakerDisplay: StreamAppSpeakerDisplay? = nil,
        isSeekable: Bool
    ) {
        self.id = id
        self.kind = kind
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.title = title
        self.subtitle = subtitle
        self.speakerDisplay = speakerDisplay
        self.isSeekable = isSeekable
    }
}

public enum StreamAppTimelineMarkerSource: String, Equatable, Sendable {
    case timedID3
    case scte35
    case unknown
}

public struct StreamAppTimelineRailSpan: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var startSeconds: Double
    public var endSeconds: Double
    public var normalizedStart: Double
    public var normalizedEnd: Double
    public var colorToken: String
    public var isSeekable: Bool

    public init(
        id: String,
        title: String,
        subtitle: String?,
        startSeconds: Double,
        endSeconds: Double,
        normalizedStart: Double,
        normalizedEnd: Double,
        colorToken: String,
        isSeekable: Bool
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.normalizedStart = normalizedStart
        self.normalizedEnd = normalizedEnd
        self.colorToken = colorToken
        self.isSeekable = isSeekable
    }
}

public struct StreamAppTimelineRailMarker: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var source: StreamAppTimelineMarkerSource
    public var seconds: Double
    public var normalizedPosition: Double
    public var colorToken: String
    public var isSeekable: Bool

    public init(
        id: String,
        title: String,
        source: StreamAppTimelineMarkerSource,
        seconds: Double,
        normalizedPosition: Double,
        colorToken: String,
        isSeekable: Bool
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.seconds = seconds
        self.normalizedPosition = normalizedPosition
        self.colorToken = colorToken
        self.isSeekable = isSeekable
    }
}

public struct StreamAppTimelineRailSnapshot: Equatable, Sendable {
    public var visibleStartSeconds: Double
    public var visibleEndSeconds: Double
    public var spans: [StreamAppTimelineRailSpan]
    public var markers: [StreamAppTimelineRailMarker]

    public init(
        visibleStartSeconds: Double,
        visibleEndSeconds: Double,
        spans: [StreamAppTimelineRailSpan] = [],
        markers: [StreamAppTimelineRailMarker] = []
    ) {
        self.visibleStartSeconds = visibleStartSeconds
        self.visibleEndSeconds = visibleEndSeconds
        self.spans = spans
        self.markers = markers
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
