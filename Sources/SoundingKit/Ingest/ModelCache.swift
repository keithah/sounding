import Foundation

/// Redacted, agent-readable model lifecycle event emitted by `ModelCache`.
public struct ModelCacheProgress: Equatable, Sendable {
    public enum Event: String, Sendable {
        case cacheHit
        case downloadStarted
        case downloadProgress
        case downloadCompleted
    }

    public var provider: String
    public var model: String
    public var event: Event
    public var fractionCompleted: Double?

    public init(provider: String, model: String, event: Event, fractionCompleted: Double? = nil) {
        self.provider = provider
        self.model = model
        self.event = event
        self.fractionCompleted = fractionCompleted
    }
}

public enum ModelCacheError: Error, Equatable, CustomStringConvertible, IngestDiagnosticError, Sendable {
    case invalidModelName(String)
    case setupFailed(provider: String, model: String, reason: String)

    public var ingestDiagnosticPhase: IngestDiagnosticPhase { .modelSetup }

    public var ingestDiagnosticReason: String {
        switch self {
        case .invalidModelName:
            return "invalid-model-name"
        case .setupFailed:
            return "model-setup-failed"
        }
    }

    public var description: String {
        switch self {
        case let .invalidModelName(model):
            return "Invalid model name: \(Self.redacted(model))."
        case let .setupFailed(provider, model, reason):
            return "Model setup failed for \(Self.redacted(provider))/\(Self.redacted(model)): \(Self.redacted(reason))."
        }
    }

    static func redacted(_ value: String) -> String {
        MonitorError.redactedSourceDescription(value)
    }
}

/// Small actor that centralizes first-use model setup, cache reuse, and redacted lifecycle progress.
public actor ModelCache {
    public typealias ProgressHandler = @Sendable (ModelCacheProgress) -> Void
    public typealias DownloadProgressHandler = @Sendable (Double?) -> Void
    public typealias Downloader = @Sendable (_ targetDirectory: URL, _ progress: @escaping DownloadProgressHandler) async throws -> URL

    private let rootDirectory: URL
    private let progressHandler: ProgressHandler?
    private let fileManager: FileManager

    public init(rootDirectory: URL? = nil, progressHandler: ProgressHandler? = nil, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
        self.progressHandler = progressHandler
        self.fileManager = fileManager
    }

    public static func defaultRootDirectory() -> URL {
        if let explicit = ProcessInfo.processInfo.environment["SOUNDING_MODEL_CACHE"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Sounding", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Prepares a provider/model cache folder. Progress events intentionally include provider/model only, never raw paths.
    @discardableResult
    public func prepare(provider: String, modelName: String, downloader: Downloader) async throws -> URL {
        let safeProvider = try Self.safeComponent(provider)
        let safeModel = try Self.safeComponent(modelName)
        let targetDirectory = rootDirectory
            .appendingPathComponent(safeProvider, isDirectory: true)
            .appendingPathComponent(safeModel, isDirectory: true)
        let marker = targetDirectory.appendingPathComponent(".sounding-model-cache")

        if fileManager.fileExists(atPath: marker.path) {
            emit(provider: safeProvider, model: safeModel, event: .cacheHit)
            return targetDirectory
        }

        do {
            try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            emit(provider: safeProvider, model: safeModel, event: .downloadStarted)
            let preparedDirectory = try await downloader(targetDirectory) { [weak self] fraction in
                Task { await self?.emit(provider: safeProvider, model: safeModel, event: .downloadProgress, fractionCompleted: fraction) }
            }
            try fileManager.createDirectory(at: preparedDirectory, withIntermediateDirectories: true)
            try Data("prepared\n".utf8).write(to: preparedDirectory.appendingPathComponent(".sounding-model-cache"), options: .atomic)
            emit(provider: safeProvider, model: safeModel, event: .downloadCompleted)
            return preparedDirectory
        } catch let error as ModelCacheError {
            throw error
        } catch {
            throw ModelCacheError.setupFailed(
                provider: safeProvider,
                model: safeModel,
                reason: MonitorError.redactedSourceDescription(String(describing: error))
            )
        }
    }

    public nonisolated static func safeComponent(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModelCacheError.invalidModelName(value) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil,
              trimmed != ".",
              trimmed != ".." else {
            throw ModelCacheError.invalidModelName(value)
        }
        return trimmed
    }

    private func emit(provider: String, model: String, event: ModelCacheProgress.Event, fractionCompleted: Double? = nil) {
        progressHandler?(ModelCacheProgress(provider: provider, model: model, event: event, fractionCompleted: fractionCompleted))
    }
}
