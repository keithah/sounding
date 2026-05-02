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
    case fingerprint
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

public struct AudioFingerprintDraft: Equatable, Sendable {
    public var algorithm: String
    public var algorithmVersion: String
    public var fingerprint: String
    public var fingerprintHash: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var confidence: Double?

    public init(
        algorithm: String,
        algorithmVersion: String,
        fingerprint: String,
        fingerprintHash: String,
        startSeconds: Double,
        endSeconds: Double,
        confidence: Double? = nil
    ) {
        self.algorithm = algorithm
        self.algorithmVersion = algorithmVersion
        self.fingerprint = fingerprint
        self.fingerprintHash = fingerprintHash
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.confidence = confidence
    }
}

public struct UnresolvedSongDraft: Equatable, Sendable {
    public static let unidentifiedKey = "unknown:unidentified"
    public static let unidentifiedDisplayName = "Unknown song"

    public var songKey: String
    public var title: String?
    public var artist: String?
    public var album: String?
    public var isrc: String?
    public var displayName: String
    public var isUnknown: Bool

    public init(
        songKey: String,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        isrc: String? = nil,
        displayName: String,
        isUnknown: Bool = false
    ) {
        self.songKey = songKey
        self.title = title
        self.artist = artist
        self.album = album
        self.isrc = isrc
        self.displayName = displayName
        self.isUnknown = isUnknown
    }

    public static func unidentified(displayName: String = unidentifiedDisplayName) -> UnresolvedSongDraft {
        UnresolvedSongDraft(
            songKey: unidentifiedKey,
            displayName: displayName,
            isUnknown: true
        )
    }
}

public struct SongPlayDraft: Equatable, Sendable {
    public var song: UnresolvedSongDraft
    public var startSeconds: Double
    public var endSeconds: Double
    public var confidence: Double?
    public var source: String?

    public init(
        song: UnresolvedSongDraft,
        startSeconds: Double,
        endSeconds: Double,
        confidence: Double? = nil,
        source: String? = nil
    ) {
        self.song = song
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.confidence = confidence
        self.source = source
    }
}

public struct HLSSegmentClaim: Equatable, Sendable {
    public var streamID: Int64
    public var runID: Int64?
    public var mediaSequence: Int
    public var segmentIdentity: String
    public var claimedAt: String

    public init(
        streamID: Int64,
        runID: Int64? = nil,
        mediaSequence: Int,
        segmentIdentity: String,
        claimedAt: String
    ) {
        self.streamID = streamID
        self.runID = runID
        self.mediaSequence = mediaSequence
        self.segmentIdentity = segmentIdentity
        self.claimedAt = claimedAt
    }
}

public struct HLSSegmentClaimDiagnostic: Equatable, Sendable {
    public var severity: IngestDiagnosticSeverity
    public var reason: String
    public var context: [String: JSONValue]

    public init(
        severity: IngestDiagnosticSeverity,
        reason: String,
        context: [String: JSONValue]
    ) {
        self.severity = severity
        self.reason = reason
        self.context = context
    }
}

public enum HLSSegmentClaimResult: Equatable, Sendable {
    case noClaim
    case claimed(diagnostics: [HLSSegmentClaimDiagnostic])
    case duplicate(existingRunID: Int64?, existingChunkID: Int64?, diagnostic: HLSSegmentClaimDiagnostic)
    case conflict(existingRunID: Int64?, existingChunkID: Int64?, diagnostic: HLSSegmentClaimDiagnostic)
}

public struct IngestChunkTimeline: Equatable, Sendable {
    public var runID: Int64
    public var chunkID: Int64
    public var segments: [TranscriptSegmentDraft]
    public var speakerTurns: [SpeakerTurnDraft]
    public var adMarkers: [AdMarker]
    public var diagnostics: [IngestDiagnosticDraft]
    public var fingerprints: [AudioFingerprintDraft]
    public var songPlays: [SongPlayDraft]
    public var createdAt: String

    public init(
        runID: Int64,
        chunkID: Int64,
        segments: [TranscriptSegmentDraft] = [],
        speakerTurns: [SpeakerTurnDraft] = [],
        adMarkers: [AdMarker] = [],
        diagnostics: [IngestDiagnosticDraft] = [],
        fingerprints: [AudioFingerprintDraft] = [],
        songPlays: [SongPlayDraft] = [],
        createdAt: String
    ) {
        self.runID = runID
        self.chunkID = chunkID
        self.segments = segments
        self.speakerTurns = speakerTurns
        self.adMarkers = adMarkers
        self.diagnostics = diagnostics
        self.fingerprints = fingerprints
        self.songPlays = songPlays
        self.createdAt = createdAt
    }
}
