import Foundation
#if canImport(ChromaSwift)
import ChromaSwift
#endif

/// Context passed to audio fingerprinters for chunk-scoped song timeline extraction.
public struct AudioFingerprintRequest: Equatable, Sendable {
    public var source: String
    public var streamType: StreamType
    public var streamID: Int64
    public var runID: Int64

    public init(
        source: String,
        streamType: StreamType,
        streamID: Int64,
        runID: Int64
    ) {
        self.source = source
        self.streamType = streamType
        self.streamID = streamID
        self.runID = runID
    }
}

/// Fingerprint output ready for transactional ingest persistence.
public struct AudioFingerprintResult: Equatable, Sendable {
    public var fingerprints: [AudioFingerprintDraft]
    public var songPlays: [SongPlayDraft]

    public init(
        fingerprints: [AudioFingerprintDraft] = [],
        songPlays: [SongPlayDraft] = []
    ) {
        self.fingerprints = fingerprints
        self.songPlays = songPlays
    }
}

/// SoundingKit-owned fingerprinting seam.
///
/// S01 deliberately avoids shelling out to Chromaprint or calling network lookup services. Real
/// implementations can be added behind this protocol later while tests and deterministic CLI ingest
/// use a local implementation.
public protocol AudioFingerprinting: Sendable {
    func fingerprint(
        _ chunk: DecodedAudioChunk,
        request: AudioFingerprintRequest
    ) async throws -> AudioFingerprintResult
}

/// Default production-safe placeholder that preserves the ingest path without fabricating song rows.
public struct NoOpAudioFingerprinter: AudioFingerprinting {
    public init() {}

    public func fingerprint(
        _ chunk: DecodedAudioChunk,
        request: AudioFingerprintRequest
    ) async throws -> AudioFingerprintResult {
        AudioFingerprintResult()
    }
}

#if canImport(ChromaSwift)
/// Chromaprint fingerprinter that emits AcoustID-compatible `.test2` fingerprints.
public struct ChromaSwiftAudioFingerprinter: AudioFingerprinting {
    public static let algorithm = "chromaprint"
    public static let algorithmVersion = "test2"

    public init() {}

    public func fingerprint(
        _ chunk: DecodedAudioChunk,
        request: AudioFingerprintRequest
    ) async throws -> AudioFingerprintResult {
        guard !chunk.audio.isEmpty, chunk.byteCount > 0,
            chunk.audioFormat.payloadKind == .linearPCM
        else {
            return AudioFingerprintResult()
        }

        let url = try writeTemporaryAudio(chunk, provider: "chromaprint")
        defer { try? FileManager.default.removeItem(at: url) }

        let fingerprint = try AudioFingerprint(from: url, algorithm: .test2, maxSampleDuration: nil)
        guard !fingerprint.base64.isEmpty, !fingerprint.hash.isEmpty else {
            return AudioFingerprintResult()
        }

        let hash = fingerprint.hash
        let unknownSong = UnresolvedSongDraft(
            songKey: "fingerprint:\(hash)",
            displayName: "Unknown song (\(String(hash.prefix(8))))",
            isUnknown: true
        )
        return AudioFingerprintResult(
            fingerprints: [
                AudioFingerprintDraft(
                    algorithm: Self.algorithm,
                    algorithmVersion: Self.algorithmVersion,
                    fingerprint: fingerprint.base64,
                    fingerprintHash: hash,
                    startSeconds: chunk.startSeconds,
                    endSeconds: chunk.endSeconds,
                    confidence: nil
                )
            ],
            songPlays: [
                SongPlayDraft(
                    song: unknownSong,
                    startSeconds: chunk.startSeconds,
                    endSeconds: chunk.endSeconds,
                    confidence: nil,
                    source: Self.algorithm
                )
            ]
        )
    }
}
#else
public struct ChromaSwiftAudioFingerprinter: AudioFingerprinting {
    public init() {}

    public func fingerprint(
        _ chunk: DecodedAudioChunk,
        request: AudioFingerprintRequest
    ) async throws -> AudioFingerprintResult {
        AudioFingerprintResult()
    }
}
#endif

/// Deterministic local fingerprinter for tests and fixture-backed CLI proof runs.
///
/// The fingerprint is a stable FNV-1a digest of chunk bytes. Song identity is intentionally derived
/// from that digest so adjacent identical audio chunks merge while changed audio splits plays.
public struct DeterministicAudioFingerprinter: AudioFingerprinting {
    public static let algorithm = "sounding-deterministic"
    public static let algorithmVersion = "1"

    public init() {}

    public func fingerprint(
        _ chunk: DecodedAudioChunk,
        request: AudioFingerprintRequest
    ) async throws -> AudioFingerprintResult {
        guard !chunk.audio.isEmpty, chunk.byteCount > 0 else {
            return AudioFingerprintResult()
        }

        let hash = Self.stableHashHex(for: chunk.audio)
        let fingerprint = "deterministic:\(hash)"
        let song = UnresolvedSongDraft(
            songKey: "fingerprint:\(hash)",
            title: nil,
            artist: nil,
            album: nil,
            isrc: nil,
            displayName: "Unknown song (\(String(hash.prefix(8))))",
            isUnknown: true
        )

        return AudioFingerprintResult(
            fingerprints: [
                AudioFingerprintDraft(
                    algorithm: Self.algorithm,
                    algorithmVersion: Self.algorithmVersion,
                    fingerprint: fingerprint,
                    fingerprintHash: hash,
                    startSeconds: chunk.startSeconds,
                    endSeconds: chunk.endSeconds,
                    confidence: 1.0
                )
            ],
            songPlays: [
                SongPlayDraft(
                    song: song,
                    startSeconds: chunk.startSeconds,
                    endSeconds: chunk.endSeconds,
                    confidence: 1.0,
                    source: "deterministic_fingerprint"
                )
            ]
        )
    }

    private static func stableHashHex(for data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
