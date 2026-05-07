import Foundation

/// Options passed to audio decoders by the bounded ingest pipeline.
public struct AudioDecodeRequest: Equatable, Sendable {
    public var source: String
    public var streamType: StreamType
    public var durationSeconds: Double?
    public var maxChunks: Int?
    public var minimumHLSMediaSequence: Int?
    public var hlsTimelineStartSeconds: Double?

    public init(
        source: String,
        streamType: StreamType,
        durationSeconds: Double? = nil,
        maxChunks: Int? = nil,
        minimumHLSMediaSequence: Int? = nil,
        hlsTimelineStartSeconds: Double? = nil
    ) {
        self.source = source
        self.streamType = streamType
        self.durationSeconds = durationSeconds
        self.maxChunks = maxChunks
        self.minimumHLSMediaSequence = minimumHLSMediaSequence
        self.hlsTimelineStartSeconds = hlsTimelineStartSeconds
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

public enum DecodedAudioPayloadKind: String, Equatable, Sendable {
    case unknown
    case linearPCM
    case containerBytes
}

/// Format metadata for decoded audio bytes. This lives at the ingest boundary so app playback
/// can tell truly decoded PCM from validated container/segment bytes without guessing.
public struct DecodedAudioFormat: Equatable, Sendable {
    public var sampleRate: Double?
    public var channelCount: Int?
    public var bitDepth: Int?
    public var payloadKind: DecodedAudioPayloadKind
    public var isFloat: Bool
    public var isInterleaved: Bool
    public var isBigEndian: Bool

    public init(
        sampleRate: Double? = nil,
        channelCount: Int? = nil,
        bitDepth: Int? = nil,
        payloadKind: DecodedAudioPayloadKind = .unknown,
        isFloat: Bool = false,
        isInterleaved: Bool = true,
        isBigEndian: Bool = false
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.payloadKind = payloadKind
        self.isFloat = isFloat
        self.isInterleaved = isInterleaved
        self.isBigEndian = isBigEndian
    }

    public static let unknown = DecodedAudioFormat()
    public static let containerBytes = DecodedAudioFormat(payloadKind: .containerBytes)

    public static func linearPCM(
        sampleRate: Double,
        channelCount: Int,
        bitDepth: Int = 16,
        isFloat: Bool = false,
        isInterleaved: Bool = true,
        isBigEndian: Bool = false
    ) -> DecodedAudioFormat {
        DecodedAudioFormat(
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitDepth: bitDepth,
            payloadKind: .linearPCM,
            isFloat: isFloat,
            isInterleaved: isInterleaved,
            isBigEndian: isBigEndian
        )
    }
}

/// One decoded audio unit ready for transcription, diarization, and marker persistence.
public struct DecodedAudioChunk: Equatable, Sendable {
    public var sequence: Int
    public var segmentURI: String?
    public var hlsIdentity: HLSDecodedAudioChunkIdentity?
    public var audio: Data
    public var audioFormat: DecodedAudioFormat
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
        audioFormat: DecodedAudioFormat = .containerBytes,
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
        self.audioFormat = audioFormat
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
