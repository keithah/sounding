import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

public protocol FluidDiarizationEngine: Sendable {
    func diarizeAudio(at url: URL, chunk: DecodedAudioChunk, transcriptSegments: [TranscriptSegmentDraft]) async throws -> [SpeakerTurnDraft]
}

public actor FluidAudioDiarizer: SpeakerDiarization {
    public typealias EngineFactory = @Sendable (_ modelName: String, _ modelDirectory: URL) async throws -> any FluidDiarizationEngine

    private let modelName: String
    private let cache: ModelCache
    private let setup: ModelCache.Downloader
    private let engineFactory: EngineFactory
    private var engine: (any FluidDiarizationEngine)?

    public init(
        modelName: String = "offline-diarizer",
        cache: ModelCache = ModelCache(),
        setup: @escaping ModelCache.Downloader = { targetDirectory, progress in
            try await FluidAudioDiarizer.defaultSetup(targetDirectory: targetDirectory, progress: progress)
        },
        engineFactory: @escaping EngineFactory = { modelName, modelDirectory in
            try await FluidAudioDiarizer.defaultEngineFactory(modelName: modelName, modelDirectory: modelDirectory)
        }
    ) {
        self.modelName = modelName
        self.cache = cache
        self.setup = setup
        self.engineFactory = engineFactory
    }

    public func diarize(_ chunk: DecodedAudioChunk, transcriptSegments: [TranscriptSegmentDraft]) async throws -> [SpeakerTurnDraft] {
        guard !chunk.audio.isEmpty else { throw MLProviderError.emptyAudio(provider: "fluidaudio") }
        let engine = try await ensureEngine()
        let url = try writeTemporaryAudio(chunk.audio, provider: "fluidaudio", segmentURI: chunk.segmentURI)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await engine.diarizeAudio(at: url, chunk: chunk, transcriptSegments: transcriptSegments)
    }

    private func ensureEngine() async throws -> any FluidDiarizationEngine {
        if let engine { return engine }
        let modelDirectory = try await cache.prepare(provider: "fluidaudio", modelName: modelName, downloader: setup)
        let created = try await engineFactory(modelName, modelDirectory)
        engine = created
        return created
    }

    public nonisolated static func defaultSetup(targetDirectory: URL, progress: @escaping ModelCache.DownloadProgressHandler) async throws -> URL {
#if canImport(FluidAudio)
        if #available(macOS 14.0, iOS 17.0, *) {
            let manager = OfflineDiarizerManager()
            progress(0)
            try await manager.prepareModels(directory: targetDirectory)
            progress(1)
            return targetDirectory
        }
        throw ModelCacheError.setupFailed(provider: "fluidaudio", model: targetDirectory.lastPathComponent, reason: "FluidAudio requires macOS 14 or newer.")
#else
        throw ModelCacheError.setupFailed(provider: "fluidaudio", model: targetDirectory.lastPathComponent, reason: "FluidAudio is unavailable on this platform.")
#endif
    }

    public nonisolated static func defaultEngineFactory(modelName: String, modelDirectory: URL) async throws -> any FluidDiarizationEngine {
#if canImport(FluidAudio)
        if #available(macOS 14.0, iOS 17.0, *) {
            return try await LiveFluidAudioEngine(modelDirectory: modelDirectory)
        }
        throw ModelCacheError.setupFailed(provider: "fluidaudio", model: modelName, reason: "FluidAudio requires macOS 14 or newer.")
#else
        throw ModelCacheError.setupFailed(provider: "fluidaudio", model: modelName, reason: "FluidAudio is unavailable on this platform.")
#endif
    }
}

#if canImport(FluidAudio)
@available(macOS 14.0, iOS 17.0, *)
private final class LiveFluidAudioEngine: FluidDiarizationEngine, @unchecked Sendable {
    private let manager: OfflineDiarizerManager

    init(modelDirectory: URL) async throws {
        self.manager = OfflineDiarizerManager()
        try await manager.prepareModels(directory: modelDirectory)
    }

    func diarizeAudio(at url: URL, chunk: DecodedAudioChunk, transcriptSegments: [TranscriptSegmentDraft]) async throws -> [SpeakerTurnDraft] {
        do {
            let result = try await manager.process(url)
            return result.segments.enumerated().compactMap { index, segment in
                let start = Double(segment.startTimeSeconds) + chunk.startSeconds
                let end = Double(segment.endTimeSeconds) + chunk.startSeconds
                guard end >= start else { return nil }
                return SpeakerTurnDraft(
                    speakerLabel: normalizedSpeakerLabel(segment.speakerId, fallback: index),
                    startSeconds: start,
                    endSeconds: end,
                    confidence: Double(segment.qualityScore)
                )
            }
        } catch let error as IngestDiagnosticError {
            throw error
        } catch {
            throw MLProviderError.providerFailed(provider: "fluidaudio", phase: .diarize, reason: String(describing: error))
        }
    }

    private func normalizedSpeakerLabel(_ speakerID: String, fallback: Int) -> String {
        let trimmed = speakerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "speaker-\(fallback + 1)" }
        if trimmed.lowercased().hasPrefix("speaker") { return trimmed }
        return "speaker-\(trimmed)"
    }
}
#endif
