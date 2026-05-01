/// Public value models used by the bounded ingest pipeline and persistence writer.
///
/// These models deliberately carry already-redacted diagnostic/source strings. The
/// persistence layer stores them with GRDB bindings but does not attempt to infer
/// sensitive substrings from arbitrary caller-provided text.
public enum IngestRunStatus: String, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

public enum IngestDiagnosticPhase: String, Sendable {
    case sourceOpen
    case decode
    case transcribe
    case diarize
    case persist
    case modelSetup
}

public enum IngestDiagnosticSeverity: String, Sendable {
    case info
    case warning
    case error
}

public struct TranscriptWordDraft: Equatable, Sendable {
    public var sequence: Int
    public var speakerLabel: String?
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var confidence: Double?

    public init(
        sequence: Int,
        speakerLabel: String? = nil,
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        confidence: Double? = nil
    ) {
        self.sequence = sequence
        self.speakerLabel = speakerLabel
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.confidence = confidence
    }
}

public struct TranscriptSegmentDraft: Equatable, Sendable {
    public var sequence: Int
    public var speakerLabel: String?
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var confidence: Double?
    public var words: [TranscriptWordDraft]

    public init(
        sequence: Int,
        speakerLabel: String? = nil,
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        confidence: Double? = nil,
        words: [TranscriptWordDraft] = []
    ) {
        self.sequence = sequence
        self.speakerLabel = speakerLabel
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.confidence = confidence
        self.words = words
    }
}

public struct SpeakerTurnDraft: Equatable, Sendable {
    public var speakerLabel: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var confidence: Double?

    public init(
        speakerLabel: String,
        startSeconds: Double,
        endSeconds: Double,
        confidence: Double? = nil
    ) {
        self.speakerLabel = speakerLabel
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.confidence = confidence
    }
}

public struct IngestDiagnosticDraft: Equatable, Sendable {
    public var streamID: Int64?
    public var phase: IngestDiagnosticPhase
    public var severity: IngestDiagnosticSeverity
    public var reason: String
    public var source: String?
    public var sourceClass: String
    public var streamType: String
    public var context: [String: JSONValue]?
    public var createdAt: String

    public init(
        streamID: Int64? = nil,
        phase: IngestDiagnosticPhase,
        severity: IngestDiagnosticSeverity,
        reason: String,
        source: String? = nil,
        sourceClass: String,
        streamType: String,
        context: [String: JSONValue]? = nil,
        createdAt: String
    ) {
        self.streamID = streamID
        self.phase = phase
        self.severity = severity
        self.reason = reason
        self.source = source
        self.sourceClass = sourceClass
        self.streamType = streamType
        self.context = context
        self.createdAt = createdAt
    }
}

public struct IngestChunkTimeline: Equatable, Sendable {
    public var runID: Int64
    public var chunkID: Int64
    public var segments: [TranscriptSegmentDraft]
    public var speakerTurns: [SpeakerTurnDraft]
    public var adMarkers: [AdMarker]
    public var diagnostics: [IngestDiagnosticDraft]
    public var createdAt: String

    public init(
        runID: Int64,
        chunkID: Int64,
        segments: [TranscriptSegmentDraft] = [],
        speakerTurns: [SpeakerTurnDraft] = [],
        adMarkers: [AdMarker] = [],
        diagnostics: [IngestDiagnosticDraft] = [],
        createdAt: String
    ) {
        self.runID = runID
        self.chunkID = chunkID
        self.segments = segments
        self.speakerTurns = speakerTurns
        self.adMarkers = adMarkers
        self.diagnostics = diagnostics
        self.createdAt = createdAt
    }
}
