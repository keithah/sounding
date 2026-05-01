/// ML provider adapters that route work through a shared non-reentrant `InferenceQueue`.
///
/// These wrappers intentionally do not catch provider errors: preserving the original error value lets
/// `StreamIngestPipeline` keep its existing modelSetup/transcribe/diarize diagnostic classification.
public struct QueuedTranscriber: MLTranscription {
    private let base: any MLTranscription
    private let queue: InferenceQueue

    public init(_ base: any MLTranscription, queue: InferenceQueue) {
        self.base = base
        self.queue = queue
    }

    public func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
        try await queue.run("transcribe") {
            try await base.transcribe(chunk)
        }
    }
}

public struct QueuedDiarizer: SpeakerDiarization {
    private let base: any SpeakerDiarization
    private let queue: InferenceQueue

    public init(_ base: any SpeakerDiarization, queue: InferenceQueue) {
        self.base = base
        self.queue = queue
    }

    public func diarize(
        _ chunk: DecodedAudioChunk,
        transcriptSegments: [TranscriptSegmentDraft]
    ) async throws -> [SpeakerTurnDraft] {
        try await queue.run("diarize") {
            try await base.diarize(chunk, transcriptSegments: transcriptSegments)
        }
    }
}
