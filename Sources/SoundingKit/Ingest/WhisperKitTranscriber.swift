import Foundation
#if canImport(WhisperKit)
@preconcurrency import WhisperKit
#endif

public protocol WhisperTranscriptionEngine {
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
            return "\(provider) temporary audio file failed: \(IngestRedaction.redact(reason))."
        case let .providerFailed(provider, _, reason):
            return "\(provider) failed: \(IngestRedaction.redact(reason))."
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
        setup: ModelCache.Downloader? = nil,
        engineFactory: EngineFactory? = nil
    ) {
        self.modelName = modelName
        self.cache = cache
        self.setup = setup ?? { targetDirectory, progress in
            try await WhisperKitTranscriber.defaultSetup(
                targetDirectory: targetDirectory,
                progress: progress
            )
        }
        self.engineFactory = engineFactory ?? { modelName, modelDirectory in
            try await WhisperKitTranscriber.defaultEngineFactory(
                modelName: modelName,
                modelDirectory: modelDirectory
            )
        }
    }

    public func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
        guard !chunk.audio.isEmpty else { throw MLProviderError.emptyAudio(provider: "whisperkit") }
        let engine = try await ensureEngine()
        let url = try writeTemporaryAudio(chunk, provider: "whisperkit")
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

func writeTemporaryAudio(_ chunk: DecodedAudioChunk, provider: String) throws -> URL {
    let prepared = try providerAudioData(for: chunk, provider: provider)
    let ext = prepared.fileExtension
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SoundingProviderAudio", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try prepared.data.write(to: url, options: .atomic)
        return url
    } catch {
        throw MLProviderError.temporaryFileFailed(provider: provider, reason: String(describing: error))
    }
}

private func providerAudioData(
    for chunk: DecodedAudioChunk,
    provider: String
) throws -> (data: Data, fileExtension: String) {
    if chunk.audioFormat.payloadKind == .linearPCM {
        return (
            try wavData(
                pcm: chunk.audio,
                format: chunk.audioFormat,
                provider: provider
            ),
            "wav"
        )
    }

    let suffix = URL(string: chunk.segmentURI ?? "")?.pathExtension
    return (chunk.audio, (suffix?.isEmpty == false) ? suffix! : "audio")
}

private func wavData(
    pcm: Data,
    format: DecodedAudioFormat,
    provider: String
) throws -> Data {
    guard let sampleRate = format.sampleRate, sampleRate.isFinite, sampleRate > 0,
        let channelCount = format.channelCount, channelCount > 0,
        let bitDepth = format.bitDepth, bitDepth > 0,
        !format.isBigEndian
    else {
        throw MLProviderError.temporaryFileFailed(
            provider: provider,
            reason: "linear PCM format is incomplete for provider WAV staging"
        )
    }

    let audioFormat: UInt16 = format.isFloat ? 3 : 1
    let channelCountValue = UInt16(clamping: channelCount)
    let sampleRateValue = UInt32(clamping: Int(sampleRate.rounded()))
    let bitDepthValue = UInt16(clamping: bitDepth)
    let blockAlign = UInt16(clamping: channelCount * max(1, bitDepth / 8))
    let byteRate = UInt32(clamping: Int(sampleRate.rounded()) * Int(blockAlign))
    let dataByteCount = UInt32(clamping: pcm.count)
    let riffChunkSize = UInt32(clamping: 36 + pcm.count)

    var data = Data()
    data.reserveCapacity(44 + pcm.count)
    data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
    data.appendLittleEndian(riffChunkSize)
    data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
    data.append(contentsOf: [0x66, 0x6d, 0x74, 0x20])
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(audioFormat)
    data.appendLittleEndian(channelCountValue)
    data.appendLittleEndian(sampleRateValue)
    data.appendLittleEndian(byteRate)
    data.appendLittleEndian(blockAlign)
    data.appendLittleEndian(bitDepthValue)
    data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
    data.appendLittleEndian(dataByteCount)
    data.append(pcm)
    return data
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

#if canImport(WhisperKit)
private final class LiveWhisperKitEngine: WhisperTranscriptionEngine {
    private let whisperKit: WhisperKit

    init(modelName: String, modelDirectory: URL) async throws {
        let config = WhisperKitConfig(
            model: nil,
            downloadBase: modelDirectory.deletingLastPathComponent(),
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
                decodeOptions: DecodingOptions(skipSpecialTokens: true, wordTimestamps: true)
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
