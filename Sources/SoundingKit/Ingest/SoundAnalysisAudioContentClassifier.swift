import Foundation

#if canImport(AVFoundation) && canImport(SoundAnalysis)
import AVFoundation
import SoundAnalysis

/// Apple SoundAnalysis-backed audio content classifier for linear PCM ingest chunks.
public struct SoundAnalysisAudioContentClassifier: AudioContentClassifying {
    private let windowDurationSeconds: Double
    private let overlapFactor: Double
    private let bufferFactory: AVFoundationPCMBufferFactory

    public init(
        windowDurationSeconds: Double = 5.0,
        overlapFactor: Double = 0.5
    ) {
        self.windowDurationSeconds = windowDurationSeconds
        self.overlapFactor = overlapFactor
        self.bufferFactory = AVFoundationPCMBufferFactory()
    }

    public func classify(
        _ chunk: DecodedAudioChunk,
        request: AudioContentClassificationRequest
    ) async throws -> AudioContentClassification? {
        guard chunk.audioFormat.payloadKind == .linearPCM, chunk.byteCount > 0 else {
            return nil
        }

        let buffer = try bufferFactory.makePCMBuffer(
            from: SharedPCMFrame(streamID: request.streamID, chunk: chunk)
        )
        let observer = SoundAnalysisClassificationObserver()
        let analyzer = SNAudioStreamAnalyzer(format: buffer.format)
        let soundRequest = try SNClassifySoundRequest(classifierIdentifier: .version1)
        soundRequest.overlapFactor = overlapFactor
        soundRequest.windowDuration = CMTime(seconds: windowDurationSeconds, preferredTimescale: 1_000)

        try analyzer.add(soundRequest, withObserver: observer)
        analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(chunk.startSeconds * buffer.format.sampleRate))
        analyzer.completeAnalysis()
        return try await observer.classification()
    }
}

private final class SoundAnalysisClassificationObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var classifications: [SNClassification] = []
    private var continuation: CheckedContinuation<AudioContentClassification?, Error>?
    private var terminalResult: Result<AudioContentClassification?, Error>?

    func classification() async throws -> AudioContentClassification? {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let terminalResult {
                    continuation.resume(with: terminalResult)
                } else {
                    self.continuation = continuation
                }
            }
        }
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        lock.withLock {
            classifications.append(contentsOf: result.classifications)
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        finish(.failure(error))
    }

    func requestDidComplete(_ request: SNRequest) {
        finish(.success(Self.aggregate(classifications)))
    }

    private func finish(_ result: Result<AudioContentClassification?, Error>) {
        let pending: CheckedContinuation<AudioContentClassification?, Error>? = lock.withLock {
            guard terminalResult == nil else { return nil }
            terminalResult = result
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(with: result)
    }

    private static func aggregate(_ classifications: [SNClassification]) -> AudioContentClassification? {
        guard !classifications.isEmpty else { return nil }
        var musicProbability = 0.0
        var speechProbability = 0.0
        var best = classifications[0]

        for classification in classifications {
            if classification.confidence > best.confidence {
                best = classification
            }
            let identifier = classification.identifier.lowercased()
            if isMusicIdentifier(identifier) {
                musicProbability = max(musicProbability, classification.confidence)
            }
            if isSpeechIdentifier(identifier) {
                speechProbability = max(speechProbability, classification.confidence)
            }
        }

        return AudioContentClassification(
            musicProbability: musicProbability,
            speechProbability: speechProbability,
            label: best.identifier
        )
    }

    private static func isMusicIdentifier(_ identifier: String) -> Bool {
        identifier == "music"
            || identifier.contains("music")
            || identifier.contains("song")
            || identifier.contains("singing")
    }

    private static func isSpeechIdentifier(_ identifier: String) -> Bool {
        identifier == "speech"
            || identifier.contains("speech")
            || identifier.contains("conversation")
            || identifier.contains("narration")
    }
}
#endif
