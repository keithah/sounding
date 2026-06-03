import Foundation

public struct AppVerifyLiveStreamExecutionRequest: Sendable {
    public var runID: String
    public var runDirectory: URL
    public var streamDirectory: URL
    public var stream: AppVerifyLiveStreamSpec
    public var diagnosticsLogURL: URL
    public var generatedAt: String

    public init(
        runID: String,
        runDirectory: URL,
        streamDirectory: URL,
        stream: AppVerifyLiveStreamSpec,
        diagnosticsLogURL: URL,
        generatedAt: String
    ) {
        self.runID = runID
        self.runDirectory = runDirectory
        self.streamDirectory = streamDirectory
        self.stream = stream
        self.diagnosticsLogURL = diagnosticsLogURL
        self.generatedAt = generatedAt
    }
}

public struct AppVerifyLiveStreamStopRequest: Sendable {
    public var runID: String
    public var runDirectory: URL
    public var streamDirectory: URL
    public var stream: AppVerifyLiveStreamSpec
    public var diagnosticsLogURL: URL
    public var registeredStreamID: Int64?

    public init(
        runID: String,
        runDirectory: URL,
        streamDirectory: URL,
        stream: AppVerifyLiveStreamSpec,
        diagnosticsLogURL: URL,
        registeredStreamID: Int64? = nil
    ) {
        self.runID = runID
        self.runDirectory = runDirectory
        self.streamDirectory = streamDirectory
        self.stream = stream
        self.diagnosticsLogURL = diagnosticsLogURL
        self.registeredStreamID = registeredStreamID
    }
}

public struct AppVerifyLiveStreamExecutionResult: Sendable, Equatable {
    public var registeredStreamID: Int64?
    public var runtimeStarted: Bool
    public var processedChunks: Int
    public var decodedChunks: Int
    public var scheduledBuffers: Int
    public var transcriptCount: Int
    public var metadataCount: Int
    public var diagnosticEvents: [String]
    public var diagnosticsFileWritten: Bool
    public var artifacts: [AppVerifyRedactedArtifact]
    public var fields: [String: String]

    public init(
        registeredStreamID: Int64? = nil,
        runtimeStarted: Bool = true,
        processedChunks: Int = 0,
        decodedChunks: Int = 0,
        scheduledBuffers: Int = 0,
        transcriptCount: Int = 0,
        metadataCount: Int = 0,
        diagnosticEvents: [String] = [],
        diagnosticsFileWritten: Bool = false,
        artifacts: [AppVerifyRedactedArtifact] = [],
        fields: [String: String] = [:]
    ) {
        self.registeredStreamID = registeredStreamID
        self.runtimeStarted = runtimeStarted
        self.processedChunks = max(0, processedChunks)
        self.decodedChunks = max(0, decodedChunks)
        self.scheduledBuffers = max(0, scheduledBuffers)
        self.transcriptCount = max(0, transcriptCount)
        self.metadataCount = max(0, metadataCount)
        self.diagnosticEvents = Array(diagnosticEvents.prefix(32)).map(AppVerifyEvidenceSanitizer.redact)
        self.diagnosticsFileWritten = diagnosticsFileWritten
        self.artifacts = Array(artifacts.prefix(16))
        self.fields = fields.prefix(16).reduce(into: [:]) { partial, pair in
            partial[AppVerifyEvidenceSanitizer.redact(pair.key)] = AppVerifyEvidenceSanitizer.redact(pair.value)
        }
    }
}

public protocol AppVerifyLiveStreamExecuting: Sendable {
    func execute(_ request: AppVerifyLiveStreamExecutionRequest) async throws -> AppVerifyLiveStreamExecutionResult
    func stop(_ request: AppVerifyLiveStreamStopRequest) async throws
}
