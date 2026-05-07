/// Speech-to-text contract used by the bounded ingest pipeline.
public protocol MLTranscription: Sendable {
    func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft]
}

/// Speaker diarization contract used by the bounded ingest pipeline.
public protocol SpeakerDiarization: Sendable {
    func diarize(_ chunk: DecodedAudioChunk, transcriptSegments: [TranscriptSegmentDraft]) async throws -> [SpeakerTurnDraft]
}

public struct NoOpSpeakerDiarizer: SpeakerDiarization {
    public init() {}

    public func diarize(
        _ chunk: DecodedAudioChunk,
        transcriptSegments: [TranscriptSegmentDraft]
    ) async throws -> [SpeakerTurnDraft] {
        []
    }
}
