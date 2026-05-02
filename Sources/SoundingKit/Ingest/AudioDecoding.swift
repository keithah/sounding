import Foundation

/// Options passed to audio decoders by the bounded ingest pipeline.
public struct AudioDecodeRequest: Equatable, Sendable {
    public var source: String
    public var streamType: StreamType
    public var durationSeconds: Double?
    public var maxChunks: Int?

    public init(
        source: String,
        streamType: StreamType,
        durationSeconds: Double? = nil,
        maxChunks: Int? = nil
    ) {
        self.source = source
        self.streamType = streamType
        self.durationSeconds = durationSeconds
        self.maxChunks = maxChunks
    }
}

/// HLS-specific segment identity carried across the decode boundary for reconnect/resume and
/// persistence-level deduplication. Values must be safe to persist: `segmentIdentity` should be a
/// redacted, stable segment description rather than a raw URI or local path.
public struct HLSDecodedAudioChunkIdentity: Equatable, Sendable {
    public var mediaSequence: Int
    public var segmentIdentity: String
    public var manifestPosition: Int?

    public init(
        mediaSequence: Int,
        segmentIdentity: String,
        manifestPosition: Int? = nil
    ) {
        self.mediaSequence = mediaSequence
        self.segmentIdentity = segmentIdentity
        self.manifestPosition = manifestPosition
    }
}

/// One decoded audio unit ready for transcription, diarization, and marker persistence.
public struct DecodedAudioChunk: Equatable, Sendable {
    public var sequence: Int
    public var segmentURI: String?
    public var hlsIdentity: HLSDecodedAudioChunkIdentity?
    public var audio: Data
    public var byteCount: Int
    public var startSeconds: Double
    public var endSeconds: Double
    public var startedAt: String
    public var endedAt: String?
    public var adMarkers: [AdMarker]

    public init(
        sequence: Int,
        segmentURI: String? = nil,
        hlsIdentity: HLSDecodedAudioChunkIdentity? = nil,
        audio: Data,
        byteCount: Int? = nil,
        startSeconds: Double,
        endSeconds: Double,
        startedAt: String,
        endedAt: String? = nil,
        adMarkers: [AdMarker] = []
    ) {
        self.sequence = sequence
        self.segmentURI = segmentURI
        self.hlsIdentity = hlsIdentity
        self.audio = audio
        self.byteCount = byteCount ?? audio.count
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.adMarkers = adMarkers
    }
}

/// Optional error metadata used by the ingest pipeline to persist phase-specific diagnostics.
public protocol IngestDiagnosticError: Error {
    var ingestDiagnosticPhase: IngestDiagnosticPhase { get }
    var ingestDiagnosticReason: String { get }
}

/// Backward-compatible alias for decoder-specific diagnostic errors.
public typealias AudioDecodingDiagnosticError = IngestDiagnosticError

/// SoundingKit-owned decoding seam. Real AVFoundation/network implementations plug in later;
/// tests can use deterministic fakes without global mutable factories.
public protocol AudioDecoding: Sendable {
    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk]
}
