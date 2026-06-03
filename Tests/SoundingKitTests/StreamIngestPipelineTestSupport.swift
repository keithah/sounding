import Foundation
import GRDB
import XCTest

@testable import SoundingKit

class StreamIngestPipelineTestCase: XCTestCase {
    static func chunk(sequence: Int, audio: Data = Data([0x01, 0x02, 0x03]))
        -> DecodedAudioChunk
    {
        DecodedAudioChunk(
            sequence: sequence,
            segmentURI:
                "https://user:pass@example.test/segment-\(String(format: "%03d", sequence)).ts?token=secret#frag",
            audio: audio,
            startSeconds: Double(sequence) * 2.0,
            endSeconds: Double(sequence + 1) * 2.0,
            startedAt: "2026-04-30T12:00:0\(sequence)Z",
            endedAt: "2026-04-30T12:00:0\(sequence + 1)Z",
            adMarkers: [
                AdMarker(
                    type: "SCTE35",
                    classification: .adStart,
                    source: "hls_segment",
                    pts: 1.0,
                    segment: "https://user:pass@example.test/segment-\(sequence).ts?token=secret",
                    rawBase64: "AAAAAQ==",
                    timestamp: "2026-04-30T12:00:0\(sequence)Z"
                )
            ]
        )
    }

    static func hlsChunk(sequence: Int, mediaSequence: Int) -> DecodedAudioChunk {
        DecodedAudioChunk(
            sequence: sequence,
            segmentURI:
                "https://user:pass@example.test/segment-\(String(format: "%03d", mediaSequence)).ts?token=secret#frag",
            hlsIdentity: HLSDecodedAudioChunkIdentity(
                mediaSequence: mediaSequence,
                segmentIdentity:
                    "https://user:pass@example.test/segment-\(String(format: "%03d", mediaSequence)).ts?token=secret#frag",
                manifestPosition: sequence
            ),
            audio: Data([UInt8(mediaSequence), 0x02, 0x03]),
            startSeconds: Double(mediaSequence) * 2.0,
            endSeconds: Double(mediaSequence + 1) * 2.0,
            startedAt: "2026-05-01T10:00:\(String(format: "%02d", mediaSequence))Z",
            endedAt: "2026-05-01T10:00:\(String(format: "%02d", mediaSequence + 1))Z",
            adMarkers: [
                AdMarker(
                    type: "SCTE35",
                    classification: .adStart,
                    source: "hls_segment",
                    pts: Double(mediaSequence),
                    segment: "https://user:pass@example.test/segment-\(mediaSequence).ts?token=secret",
                    rawBase64: "AAAAAQ==",
                    timestamp: "2026-05-01T10:00:\(String(format: "%02d", mediaSequence))Z"
                )
            ]
        )
    }

    static func segment(
        text: String,
        speakerLabel: String = "speaker-1",
        startSeconds: Double = 0,
        endSeconds: Double = 1.2,
        words wordTexts: [String]? = nil
    ) -> TranscriptSegmentDraft {
        let words = wordTexts ?? text.split(separator: " ").map(String.init)
        let duration = max((endSeconds - startSeconds) / Double(max(words.count, 1)), 0.1)
        return TranscriptSegmentDraft(
            sequence: 0,
            speakerLabel: speakerLabel,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            text: text,
            confidence: 0.9,
            words: words.enumerated().map { index, word in
                TranscriptWordDraft(
                    sequence: index,
                    speakerLabel: speakerLabel,
                    startSeconds: startSeconds + (Double(index) * duration),
                    endSeconds: startSeconds + (Double(index + 1) * duration),
                    text: word,
                    confidence: 0.9
                )
            }
        )
    }
    static func assertNoForbiddenLiterals(
        in text: String,
        forbidden literals: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for literal in literals where !literal.isEmpty {
            XCTAssertFalse(
                text.contains(literal),
                "Expected redacted text to omit forbidden literal '\(literal)', got: \(text)",
                file: file,
                line: line
            )
        }
    }
}

actor PipelineRecordingCollaboratorProbe {
    private var transcribed: [Int] = []
    private var diarized: [Int] = []
    private var fingerprinted: [Int] = []

    func recordTranscribed(_ chunk: DecodedAudioChunk) {
        transcribed.append(chunk.hlsIdentity?.mediaSequence ?? chunk.sequence)
    }

    func recordDiarized(_ chunk: DecodedAudioChunk) {
        diarized.append(chunk.hlsIdentity?.mediaSequence ?? chunk.sequence)
    }

    func recordFingerprinted(_ chunk: DecodedAudioChunk) {
        fingerprinted.append(chunk.hlsIdentity?.mediaSequence ?? chunk.sequence)
    }

    func transcribedMediaSequences() -> [Int] { transcribed }
    func diarizedMediaSequences() -> [Int] { diarized }
    func fingerprintedMediaSequences() -> [Int] { fingerprinted }
}

struct PipelineFakeDecoder: AudioDecoding {
    var chunks: [DecodedAudioChunk]
    var error: Error?

    init(chunks: [DecodedAudioChunk] = [], error: Error? = nil) {
        self.chunks = chunks
        self.error = error
    }

    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        if let error {
            throw error
        }
        return chunks
    }
}

struct PipelineFakeTranscriber: MLTranscription {
    var segmentsBySequence: [Int: [TranscriptSegmentDraft]]
    var errorBySequence: [Int: Error]
    var errorByMediaSequence: [Int: Error]
    var probe: PipelineRecordingCollaboratorProbe?

    init(
        segmentsBySequence: [Int: [TranscriptSegmentDraft]] = [:],
        errorBySequence: [Int: Error] = [:],
        errorByMediaSequence: [Int: Error] = [:],
        probe: PipelineRecordingCollaboratorProbe? = nil
    ) {
        self.segmentsBySequence = segmentsBySequence
        self.errorBySequence = errorBySequence
        self.errorByMediaSequence = errorByMediaSequence
        self.probe = probe
    }

    func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
        await probe?.recordTranscribed(chunk)
        if let mediaSequence = chunk.hlsIdentity?.mediaSequence,
            let error = errorByMediaSequence[mediaSequence]
        {
            throw error
        }
        if let error = errorBySequence[chunk.sequence] {
            throw error
        }
        return segmentsBySequence[chunk.sequence] ?? []
    }
}

struct PipelineFakeDiarizer: SpeakerDiarization {
    var turnsBySequence: [Int: [SpeakerTurnDraft]]
    var errorBySequence: [Int: Error]
    var errorByMediaSequence: [Int: Error]
    var probe: PipelineRecordingCollaboratorProbe?

    init(
        turnsBySequence: [Int: [SpeakerTurnDraft]] = [:],
        errorBySequence: [Int: Error] = [:],
        errorByMediaSequence: [Int: Error] = [:],
        probe: PipelineRecordingCollaboratorProbe? = nil
    ) {
        self.turnsBySequence = turnsBySequence
        self.errorBySequence = errorBySequence
        self.errorByMediaSequence = errorByMediaSequence
        self.probe = probe
    }

    func diarize(_ chunk: DecodedAudioChunk, transcriptSegments: [TranscriptSegmentDraft])
        async throws -> [SpeakerTurnDraft]
    {
        await probe?.recordDiarized(chunk)
        if let mediaSequence = chunk.hlsIdentity?.mediaSequence,
            let error = errorByMediaSequence[mediaSequence]
        {
            throw error
        }
        if let error = errorBySequence[chunk.sequence] {
            throw error
        }
        return turnsBySequence[chunk.sequence] ?? []
    }
}

struct PipelineRecordingFingerprinter: AudioFingerprinting {
    var errorByMediaSequence: [Int: Error]
    var probe: PipelineRecordingCollaboratorProbe?

    init(
        errorByMediaSequence: [Int: Error] = [:],
        probe: PipelineRecordingCollaboratorProbe? = nil
    ) {
        self.errorByMediaSequence = errorByMediaSequence
        self.probe = probe
    }

    func fingerprint(
        _ chunk: DecodedAudioChunk,
        request: AudioFingerprintRequest
    ) async throws -> AudioFingerprintResult {
        await probe?.recordFingerprinted(chunk)
        if let mediaSequence = chunk.hlsIdentity?.mediaSequence,
            let error = errorByMediaSequence[mediaSequence]
        {
            throw error
        }
        let mediaSequence = chunk.hlsIdentity?.mediaSequence ?? chunk.sequence
        let hash = "recording-\(mediaSequence)"
        return AudioFingerprintResult(
            fingerprints: [
                AudioFingerprintDraft(
                    algorithm: "recording",
                    algorithmVersion: "1",
                    fingerprint: "recording:\(mediaSequence)",
                    fingerprintHash: hash,
                    startSeconds: chunk.startSeconds,
                    endSeconds: chunk.endSeconds,
                    confidence: 1.0
                )
            ],
            songPlays: [
                SongPlayDraft(
                    song: UnresolvedSongDraft(
                        songKey: "recording:\(mediaSequence)",
                        displayName: "Recording \(mediaSequence)",
                        isUnknown: true
                    ),
                    startSeconds: chunk.startSeconds,
                    endSeconds: chunk.endSeconds,
                    confidence: 1.0,
                    source: "recording"
                )
            ]
        )
    }
}

struct PipelineFakeIngestError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

struct PipelineFakeDiagnosticError: Error, CustomStringConvertible, IngestDiagnosticError {
    var ingestDiagnosticPhase: IngestDiagnosticPhase
    var ingestDiagnosticReason: String
    var description: String

    init(phase: IngestDiagnosticPhase, reason: String, description: String) {
        self.ingestDiagnosticPhase = phase
        self.ingestDiagnosticReason = reason
        self.description = description
    }
}

struct PipelineGateDecoder: AudioDecoding {
    let gate: PipelineDecodeGate

    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        await gate.chunksAfterResume()
    }
}

actor PipelineDecodeGate {
    private let chunks: [DecodedAudioChunk]
    private var requested = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    init(chunks: [DecodedAudioChunk]) {
        self.chunks = chunks
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func chunksAfterResume() async -> [DecodedAudioChunk] {
        requested = true
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            resumeWaiter = continuation
        }
        return chunks
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}
