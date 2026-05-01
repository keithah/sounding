import Foundation
#if canImport(WhisperKit)
@preconcurrency import WhisperKit
#endif

public protocol WhisperTranscriptionEngine: Sendable {
    func transcribeAudio(at url: URL, chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft]
}

public enum MLProviderError: Error, Equatable, CustomStringConvertible, IngestDiagnosticError, Sendable {
    case emptyAudio(provider: String)
    case temporaryFileFailed(provider: String, reason: String)
    case providerFailed(provider: String, phase: IngestDiagnosticPhase, reason: String)

    public var ingestDiagnosticPhase: IngestDiagnosticPhase {
        switch self {
        case .emptyAudio:
            return .decode
        case .temporaryFileFailed:
            return .modelSetup
        case .providerFailed(_, let phase, _):
            return phase
        }
    }

    public var ingestDiagnosticReason: String {
        switch self {
        case .emptyAudio:
            return "empty-audio"
        case .temporaryFileFailed:
            return "temporary-audio-file-failed"
        case .providerFailed:
            return "provider-failed"
        }
    }

    public var description: String {
        switch self {
        case let .emptyAudio(provider):
            return "\(provider) received empty audio."
        case let .temporaryFileFailed(provider, reason):
            return "\(provider) temporary audio file failed: \(MonitorError.redactedSourceDescription(reason))."
        case let .providerFailed(provider, _, reason):
            return "\(provider) failed: \(MonitorError.redactedSourceDescription(reason))."
        }
    }
}

public actor WhisperKitTranscriber: MLTranscription {
    public typealias EngineFactory = @Sendable (_ modelName: String, _ modelDirectory: URL) async throws -> any WhisperTranscriptionEngine

    private let modelName: String
    private let cache: ModelCache
    private let setup: ModelCache.Downloader
    private let engineFactory: EngineFactory
    private var engine: (any WhisperTranscriptionEngine)?

    public init(
        modelName: String = "tiny",
        cache: ModelCache = ModelCache(),
        setup: @escaping ModelCache.Downloader = { targetDirectory, progress in
            try await WhisperKitTranscriber.defaultSetup(targetDirectory: targetDirectory, progress: progress)
        },
        engineFactory: @escaping EngineFactory = { modelName, modelDirectory in
            try await WhisperKitTranscriber.defaultEngineFactory(modelName: modelName, modelDirectory: modelDirectory)
        }
    ) {
        self.modelName = modelName
        self.cache = cache
        self.setup = setup
        self.engineFactory = engineFactory
    }

    public func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
        guard !chunk.audio.isEmpty else { throw MLProviderError.emptyAudio(provider: "whisperkit") }
        let engine = try await ensureEngine()
        let url = try writeTemporaryAudio(chunk.audio, provider: "whisperkit", segmentURI: chunk.segmentURI)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await engine.transcribeAudio(at: url, chunk: chunk)
    }

    private func ensureEngine() async throws -> any WhisperTranscriptionEngine {
        if let engine { return engine }
        let modelDirectory = try await cache.prepare(provider: "whisperkit", modelName: modelName, downloader: setup)
        let created = try await engineFactory(modelName, modelDirectory)
        engine = created
        return created
    }

    public nonisolated static func defaultSetup(targetDirectory: URL, progress: @escaping ModelCache.DownloadProgressHandler) async throws -> URL {
#if canImport(WhisperKit)
        let prepared = try await WhisperKit.download(
            variant: targetDirectory.lastPathComponent,
            downloadBase: targetDirectory.deletingLastPathComponent(),
            progressCallback: { modelProgress in
                progress(modelProgress.fractionCompleted)
            }
        )
        return prepared
#else
        throw ModelCacheError.setupFailed(provider: "whisperkit", model: targetDirectory.lastPathComponent, reason: "WhisperKit is unavailable on this platform.")
#endif
    }

    public nonisolated static func defaultEngineFactory(modelName: String, modelDirectory: URL) async throws -> any WhisperTranscriptionEngine {
#if canImport(WhisperKit)
        return try await LiveWhisperKitEngine(modelName: modelName, modelDirectory: modelDirectory)
#else
        throw ModelCacheError.setupFailed(provider: "whisperkit", model: modelName, reason: "WhisperKit is unavailable on this platform.")
#endif
    }
}

func writeTemporaryAudio(_ data: Data, provider: String, segmentURI: String?) throws -> URL {
    let suffix = URL(string: segmentURI ?? "")?.pathExtension
    let ext = (suffix?.isEmpty == false) ? suffix! : "audio"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SoundingProviderAudio", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: url, options: .atomic)
        return url
    } catch {
        throw MLProviderError.temporaryFileFailed(provider: provider, reason: String(describing: error))
    }
}

#if canImport(WhisperKit)
private final class LiveWhisperKitEngine: WhisperTranscriptionEngine, @unchecked Sendable {
    private let whisperKit: WhisperKit

    init(modelName: String, modelDirectory: URL) async throws {
        let config = WhisperKitConfig(
            model: modelName,
            modelFolder: modelDirectory.path,
            verbose: false,
            load: true,
            download: false
        )
        self.whisperKit = try await WhisperKit(config)
    }

    func transcribeAudio(at url: URL, chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
        do {
            let results = try await whisperKit.transcribe(
                audioPath: url.path,
                decodeOptions: DecodingOptions(wordTimestamps: true)
            )
            var sequence = 0
            return results.flatMap { result in
                result.segments.map { segment in
                    defer { sequence += 1 }
                    return TranscriptSegmentDraft(
                        sequence: sequence,
                        startSeconds: Double(segment.start) + chunk.startSeconds,
                        endSeconds: Double(segment.end) + chunk.startSeconds,
                        text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        confidence: confidence(from: segment),
                        words: words(from: segment, chunkStart: chunk.startSeconds)
                    )
                }
            }
        } catch let error as IngestDiagnosticError {
            throw error
        } catch {
            throw MLProviderError.providerFailed(provider: "whisperkit", phase: .transcribe, reason: String(describing: error))
        }
    }

    private func confidence(from segment: TranscriptionSegment) -> Double? {
        guard segment.avgLogprob.isFinite else { return nil }
        return min(1.0, max(0.0, Double(exp(segment.avgLogprob))))
    }

    private func words(from segment: TranscriptionSegment, chunkStart: Double) -> [TranscriptWordDraft] {
        (segment.words ?? []).enumerated().map { offset, word in
            TranscriptWordDraft(
                sequence: offset,
                startSeconds: Double(word.start) + chunkStart,
                endSeconds: Double(word.end) + chunkStart,
                text: word.word.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: Double(word.probability)
            )
        }
    }
}
#endif
