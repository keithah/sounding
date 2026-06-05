import Foundation

public struct AppStreamRuntimeRequest: Equatable, Sendable {
    public var streamID: Int64
    public var name: String
    public var source: String
    public var sourceDescription: String
    public var streamType: StreamType
    public var isDiarizationEnabled: Bool
    public var isAudioArchiveEnabled: Bool
    public var transcriptionPolicy: StreamTranscriptionPolicy

    public init(
        streamID: Int64,
        name: String,
        source: String,
        sourceDescription: String,
        streamType: StreamType,
        isDiarizationEnabled: Bool = false,
        isAudioArchiveEnabled: Bool = false,
        transcriptionPolicy: StreamTranscriptionPolicy = .defaultValue
    ) {
        self.streamID = streamID
        self.name = name
        self.source = source
        self.sourceDescription = sourceDescription
        self.streamType = streamType
        self.isDiarizationEnabled = isDiarizationEnabled
        self.isAudioArchiveEnabled = isAudioArchiveEnabled
        self.transcriptionPolicy = transcriptionPolicy
    }
}

public struct AppStreamRuntimeResult: Equatable, Sendable {
    public var streamID: Int64
    public var runID: Int64?
    public var processedChunks: Int
    public var diagnosticCount: Int
    public var playerTimeline: AppPlayerTimelineSnapshot?

    public init(
        streamID: Int64,
        runID: Int64? = nil,
        processedChunks: Int = 0,
        diagnosticCount: Int = 0,
        playerTimeline: AppPlayerTimelineSnapshot? = nil
    ) {
        self.streamID = streamID
        self.runID = runID
        self.processedChunks = processedChunks
        self.diagnosticCount = diagnosticCount
        self.playerTimeline = playerTimeline
    }
}

public protocol AppStreamRuntimeIngesting: Sendable {
    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult
}

public enum AppStreamRuntimeStatusPhase: String, CaseIterable, Codable, Equatable, Sendable {
    case connecting
    case running
    case paused
    case suspended
    case recovering
    case reconnecting
    case stopped
    case error
}

public struct AppStreamRuntimeLifecycleEvidence: Equatable, Sendable {
    public var reason: String
    public var suspendedAt: String?
    public var recoveryStartedAt: String?
    public var recoveredAt: String?
    public var recoveryLatencySeconds: Double?

    public init(
        reason: String,
        suspendedAt: String? = nil,
        recoveryStartedAt: String? = nil,
        recoveredAt: String? = nil,
        recoveryLatencySeconds: Double? = nil
    ) {
        self.reason = IngestRedaction.redact(reason)
        self.suspendedAt = suspendedAt.map(IngestRedaction.redact)
        self.recoveryStartedAt = recoveryStartedAt.map(IngestRedaction.redact)
        self.recoveredAt = recoveredAt.map(IngestRedaction.redact)
        self.recoveryLatencySeconds = recoveryLatencySeconds.map { max(0, $0) }
    }
}

public struct AppStreamRuntimeRecentFailure: Equatable, Sendable {
    public var message: String
    public var occurredAt: String

    public init(message: String, occurredAt: String) {
        self.message = IngestRedaction.redact(message)
        self.occurredAt = occurredAt
    }
}

public struct AppStreamRuntimeStatusUpdate: Equatable, Sendable {
    public var streamID: Int64
    public var phase: AppStreamRuntimeStatusPhase
    public var attempt: Int
    public var maxAttempts: Int
    public var nextRetrySeconds: Int?
    public var nextRetryAt: String?
    public var updatedAt: String
    public var recentFailure: AppStreamRuntimeRecentFailure?
    public var lifecycleEvidence: AppStreamRuntimeLifecycleEvidence?

    public init(
        streamID: Int64,
        phase: AppStreamRuntimeStatusPhase,
        attempt: Int = 0,
        maxAttempts: Int = 0,
        nextRetrySeconds: Int? = nil,
        nextRetryAt: String? = nil,
        updatedAt: String,
        recentFailure: AppStreamRuntimeRecentFailure? = nil,
        lifecycleEvidence: AppStreamRuntimeLifecycleEvidence? = nil
    ) {
        self.streamID = streamID
        self.phase = phase
        self.attempt = max(0, attempt)
        self.maxAttempts = max(0, maxAttempts)
        self.nextRetrySeconds = nextRetrySeconds.map { max(0, $0) }
        self.nextRetryAt = nextRetryAt.map(IngestRedaction.redact)
        self.updatedAt = updatedAt
        self.recentFailure = recentFailure
        self.lifecycleEvidence = lifecycleEvidence
    }
}

public struct AppStreamRuntimeStatusSnapshot: Equatable, Sendable {
    public var streamID: Int64
    public var name: String
    public var streamType: String
    public var sourceDescription: String
    public var phase: AppStreamRuntimeStatusPhase
    public var attempt: Int
    public var maxAttempts: Int
    public var nextRetrySeconds: Int?
    public var nextRetryAt: String?
    public var updatedAt: String
    public var recentFailure: AppStreamRuntimeRecentFailure?
    public var lifecycleEvidence: AppStreamRuntimeLifecycleEvidence?

    public init(
        streamID: Int64,
        name: String,
        streamType: String,
        sourceDescription: String,
        phase: AppStreamRuntimeStatusPhase,
        attempt: Int,
        maxAttempts: Int,
        nextRetrySeconds: Int?,
        nextRetryAt: String?,
        updatedAt: String,
        recentFailure: AppStreamRuntimeRecentFailure?,
        lifecycleEvidence: AppStreamRuntimeLifecycleEvidence? = nil
    ) {
        self.streamID = streamID
        self.name = IngestRedaction.redact(name)
        self.streamType = IngestRedaction.redact(streamType)
        self.sourceDescription = IngestRedaction.sourceDescription(sourceDescription)
        self.phase = phase
        self.attempt = max(0, attempt)
        self.maxAttempts = max(0, maxAttempts)
        self.nextRetrySeconds = nextRetrySeconds.map { max(0, $0) }
        self.nextRetryAt = nextRetryAt.map(IngestRedaction.redact)
        self.updatedAt = updatedAt
        self.recentFailure = recentFailure
        self.lifecycleEvidence = lifecycleEvidence
    }
}

public enum AppStreamRuntimePhase: Equatable, Sendable {
    case connecting
    case running
    case paused
    case suspended
    case recovering
    case reconnecting(nextRetrySeconds: Int?)
    case stopped
    case error(message: String)

    public var statusPhase: AppStreamRuntimeStatusPhase {
        switch self {
        case .connecting:
            return .connecting
        case .running:
            return .running
        case .paused:
            return .paused
        case .suspended:
            return .suspended
        case .recovering:
            return .recovering
        case .reconnecting:
            return .reconnecting
        case .stopped:
            return .stopped
        case .error:
            return .error
        }
    }

    public var appStatus: StreamAppStatus {
        switch self {
        case .connecting:
            return .connecting
        case .running:
            return .running
        case .paused:
            return .paused
        case .suspended:
            return .suspended
        case .recovering:
            return .recovering
        case .reconnecting(let nextRetrySeconds):
            return .reconnecting(nextRetrySeconds: nextRetrySeconds)
        case .stopped:
            return .stopped
        case .error(let message):
            return .error(message: message)
        }
    }
}

public enum AppStreamRuntimeEventKind: Equatable, Sendable {
    case lifecycle
    case playerTelemetry
    case controlFeedback
}

public struct AppStreamRuntimeEvent: Equatable, Sendable {
    public var streamID: Int64
    public var kind: AppStreamRuntimeEventKind
    public var phase: AppStreamRuntimePhase
    public var message: String
    public var result: AppStreamRuntimeResult?
    public var lifecycleEvidence: AppStreamRuntimeLifecycleEvidence?

    public init(
        streamID: Int64,
        kind: AppStreamRuntimeEventKind = .lifecycle,
        phase: AppStreamRuntimePhase,
        message: String,
        result: AppStreamRuntimeResult? = nil,
        lifecycleEvidence: AppStreamRuntimeLifecycleEvidence? = nil
    ) {
        self.streamID = streamID
        self.kind = kind
        self.phase = phase
        self.message = IngestRedaction.redact(message)
        self.result = result
        self.lifecycleEvidence = lifecycleEvidence
    }
}

public struct AppStreamRuntimeRetryPolicy: Sendable {
    public var maximumReconnectAttempts: Int
    public var backoffSeconds: @Sendable (Int) -> Int

    public init(
        maximumReconnectAttempts: Int = 3,
        backoffSeconds: @escaping @Sendable (Int) -> Int = { attempt in min(max(attempt, 1), 30) }
    ) {
        self.maximumReconnectAttempts = max(0, maximumReconnectAttempts)
        self.backoffSeconds = backoffSeconds
    }

    public static let noRetry = AppStreamRuntimeRetryPolicy(maximumReconnectAttempts: 0)
}

public enum AppStreamRuntimeError: Error, Equatable, Sendable, CustomStringConvertible {
    case streamNotFound(Int64)
    case unsupportedStreamType(String)
    case runtimeFailed(String)

    public var description: String {
        switch self {
        case .streamNotFound(let id):
            return "Stream \(id) was not found or is not active."
        case .unsupportedStreamType(let streamType):
            return "Unsupported app runtime stream type \(IngestRedaction.redact(streamType))."
        case .runtimeFailed(let message):
            return IngestRedaction.redact(message)
        }
    }
}

public protocol AppStreamRuntimeControlling: Sendable {
    func events() async -> AsyncStream<AppStreamRuntimeEvent>
    func start(streamID: Int64) async throws
    func restart(streamID: Int64) async throws
    func pause() async
    func pause(streamID: Int64) async
    func resume() async
    func resume(streamID: Int64) async
    func stop() async
    func stop(streamID: Int64) async
    func stopAll() async
    func suspendForSystemSleep(reason: String) async
    func recoverFromSystemWake(reason: String) async
    func setVolume(streamID: Int64, volume: Double) async
    func setMuted(streamID: Int64, isMuted: Bool) async
    func seek(to seconds: Double, streamID: Int64) async
    func seekToLive(streamID: Int64) async
    func scrubBackward(seconds: Double, streamID: Int64) async
    func snapshot() async -> AppStreamRuntimeEvent?
    func snapshot(streamID: Int64) async -> AppStreamRuntimeEvent?
    func snapshots() async -> [AppStreamRuntimeEvent]
}
