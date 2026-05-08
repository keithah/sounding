import Foundation

public struct AppStreamRuntimeRequest: Equatable, Sendable {
    public var streamID: Int64
    public var name: String
    public var source: String
    public var sourceDescription: String
    public var streamType: StreamType
    public var isDiarizationEnabled: Bool

    public init(
        streamID: Int64,
        name: String,
        source: String,
        sourceDescription: String,
        streamType: StreamType,
        isDiarizationEnabled: Bool = false
    ) {
        self.streamID = streamID
        self.name = name
        self.source = source
        self.sourceDescription = sourceDescription
        self.streamType = streamType
        self.isDiarizationEnabled = isDiarizationEnabled
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

public struct StreamIngestAppRuntimeRunner: AppStreamRuntimeIngesting {
    private let database: SoundingDatabase
    private let decoder: any AudioDecoding
    private let transcriber: any MLTranscription
    private let diarizer: any SpeakerDiarization
    private let diarizerFactory: @Sendable (Bool) -> any SpeakerDiarization
    private let fingerprinter: any AudioFingerprinting
    private let fingerprintEnricher: any AudioFingerprintEnriching
    private let now: StreamIngestPipeline.TimestampProvider
    private let player: (any AppPCMPlaybackAdapting)?
    private let timeline: AppPlayerTimelineClock
    private let rollingBuffer: RollingPCMBuffer?
    private let diagnosticsLog: AppRuntimeDiagnosticsLog
    private let keepPlaybackRunningAfterIngestCompletes: Bool
    private let livePollIntervalNanoseconds: UInt64

    public init(
        database: SoundingDatabase,
        decoder: any AudioDecoding,
        transcriber: any MLTranscription,
        diarizer: any SpeakerDiarization,
        fingerprinter: any AudioFingerprinting = NoOpAudioFingerprinter(),
        fingerprintEnricher: any AudioFingerprintEnriching = NoOpAudioFingerprintEnricher(),
        player: (any AppPCMPlaybackAdapting)? = nil,
        timeline: AppPlayerTimelineClock = AppPlayerTimelineClock(),
        rollingBuffer: RollingPCMBuffer? = nil,
        diagnosticsLog: AppRuntimeDiagnosticsLog = AppRuntimeDiagnosticsLog(),
        keepPlaybackRunningAfterIngestCompletes: Bool = false,
        livePollIntervalNanoseconds: UInt64 = 2_000_000_000,
        diarizerFactory: (@Sendable (Bool) -> any SpeakerDiarization)? = nil,
        now: @escaping StreamIngestPipeline.TimestampProvider = {
            ISO8601DateFormatter().string(from: Date())
        }
    ) {
        self.database = database
        self.decoder = decoder
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.diarizerFactory = diarizerFactory ?? { _ in diarizer }
        self.fingerprinter = fingerprinter
        self.fingerprintEnricher = fingerprintEnricher
        self.player = player
        self.timeline = timeline
        self.rollingBuffer = rollingBuffer
        self.diagnosticsLog = diagnosticsLog
        self.keepPlaybackRunningAfterIngestCompletes = keepPlaybackRunningAfterIngestCompletes
        self.livePollIntervalNanoseconds = livePollIntervalNanoseconds
        self.now = now
    }

    public func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        diagnosticsLog.recordEvent(
            "runner.run.started",
            streamID: request.streamID,
            streamName: request.name,
            source: request.source,
            sourceDescription: request.sourceDescription,
            phase: "runner.start",
            fields: [
                "streamType": request.streamType.rawValue,
                "hasPlayer": String(player != nil),
                "keepPlaybackRunningAfterIngestCompletes": String(keepPlaybackRunningAfterIngestCompletes),
                "isDiarizationEnabled": String(request.isDiarizationEnabled),
            ]
        )
        let runtimeDecoder: any AudioDecoding
        if let player {
            if let rollingBuffer {
                await rollingBuffer.start(streamID: request.streamID)
                await timeline.updateRollingBuffer(await rollingBuffer.snapshot())
            }
            try await player.prepare(
                streamID: request.streamID,
                sourceDescription: request.sourceDescription,
                timeline: timeline
            )
            diagnosticsLog.recordEvent(
                "runner.playback.prepared",
                streamID: request.streamID,
                streamName: request.name,
                source: request.source,
                sourceDescription: request.sourceDescription,
                phase: "runner.playback"
            )
            runtimeDecoder = SinglePathPCMDecoder(
                streamID: request.streamID,
                upstream: decoder,
                player: player,
                timeline: timeline,
                rollingBuffer: rollingBuffer,
                database: database
            )
        } else {
            runtimeDecoder = decoder
        }
        let runtimeDiarizer = diarizerFactory(request.isDiarizationEnabled)

        do {
            if player != nil && keepPlaybackRunningAfterIngestCompletes {
                var totalProcessedChunks = 0
                var totalDiagnostics = 0
                var lastRunID: Int64?
                while !Task.isCancelled {
                    let result = try await runIngestPass(
                        request,
                        decoder: runtimeDecoder,
                        diarizer: runtimeDiarizer
                    )
                    lastRunID = result.runID
                    totalProcessedChunks += result.processedChunks
                    totalDiagnostics += result.diagnostics.count
                    diagnosticsLog.recordEvent(
                        "runner.ingest.poll.completed",
                        streamID: request.streamID,
                        streamName: request.name,
                        source: request.source,
                        sourceDescription: request.sourceDescription,
                        phase: "runner.ingest",
                        fields: [
                            "runID": String(result.runID),
                            "processedChunks": String(result.processedChunks),
                            "diagnosticCount": String(result.diagnostics.count),
                            "totalProcessedChunks": String(totalProcessedChunks),
                            "totalDiagnosticCount": String(totalDiagnostics),
                        ]
                    )
                    if result.processedChunks == 0 {
                        try await Task.sleep(nanoseconds: livePollIntervalNanoseconds)
                    }
                }
                return AppStreamRuntimeResult(
                    streamID: request.streamID,
                    runID: lastRunID,
                    processedChunks: totalProcessedChunks,
                    diagnosticCount: totalDiagnostics,
                    playerTimeline: await timeline.snapshot()
                )
            }

            let result = try await runIngestPass(
                request,
                decoder: runtimeDecoder,
                diarizer: runtimeDiarizer
            )
            if let player {
                diagnosticsLog.recordEvent(
                    "runner.playback.auto-stop",
                    streamID: request.streamID,
                    streamName: request.name,
                    source: request.source,
                    sourceDescription: request.sourceDescription,
                    phase: "runner.stop"
                )
                await player.stop(timeline: timeline)
            }
            let playerTimeline = await timeline.snapshot()
            if let rollingBuffer {
                await timeline.updateRollingBuffer(await rollingBuffer.cleanup())
            }
            return AppStreamRuntimeResult(
                streamID: result.streamID,
                runID: result.runID,
                processedChunks: result.processedChunks,
                diagnosticCount: result.diagnostics.count,
                playerTimeline: playerTimeline
            )
        } catch is CancellationError {
            diagnosticsLog.recordEvent(
                "runner.cancelled",
                streamID: request.streamID,
                streamName: request.name,
                source: request.source,
                sourceDescription: request.sourceDescription,
                phase: "runner.cancel"
            )
            if let player {
                await player.stop(timeline: timeline)
            }
            if let rollingBuffer {
                await timeline.updateRollingBuffer(await rollingBuffer.cleanup())
            }
            throw CancellationError()
        } catch {
            diagnosticsLog.recordFailure(
                streamID: request.streamID,
                name: request.name,
                source: request.source,
                sourceDescription: request.sourceDescription,
                phase: diagnosticPhase(for: error),
                error: error
            )
            if let player {
                await player.stop(timeline: timeline)
                await timeline.updatePlayerState(
                    .failed(message: String(describing: error)),
                    message: "Runtime playback failed: \(error).")
            }
            if let rollingBuffer {
                await timeline.updateRollingBuffer(await rollingBuffer.cleanup())
            }
            throw error
        }
    }

    private func runIngestPass(
        _ request: AppStreamRuntimeRequest,
        decoder runtimeDecoder: any AudioDecoding,
        diarizer runtimeDiarizer: any SpeakerDiarization
    ) async throws -> StreamIngestResult {
        let result = try await StreamIngestPipeline(
            database: database,
            decoder: runtimeDecoder,
            transcriber: transcriber,
            diarizer: runtimeDiarizer,
            fingerprinter: fingerprinter,
            fingerprintEnricher: fingerprintEnricher,
            now: now
        ).run(
            streamID: request.streamID,
            source: request.source,
            streamType: request.streamType,
            maxChunks: request.streamType == .hls ? 1 : nil
        )
        diagnosticsLog.recordEvent(
            "runner.ingest.completed",
            streamID: request.streamID,
            streamName: request.name,
            source: request.source,
            sourceDescription: request.sourceDescription,
            phase: "runner.ingest",
            fields: [
                "runID": String(result.runID),
                "processedChunks": String(result.processedChunks),
                "diagnosticCount": String(result.diagnostics.count),
            ]
        )
        return result
    }

    private func diagnosticPhase(for error: any Error) -> String {
        if let diagnostic = error as? IngestDiagnosticError {
            return diagnostic.ingestDiagnosticPhase.rawValue
        }
        if error is AppPlayerAdapterError {
            return "playback"
        }
        return "runtime"
    }
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

public struct AppStreamRuntimeEvent: Equatable, Sendable {
    public var streamID: Int64
    public var phase: AppStreamRuntimePhase
    public var message: String
    public var result: AppStreamRuntimeResult?
    public var lifecycleEvidence: AppStreamRuntimeLifecycleEvidence?

    public init(
        streamID: Int64,
        phase: AppStreamRuntimePhase,
        message: String,
        result: AppStreamRuntimeResult? = nil,
        lifecycleEvidence: AppStreamRuntimeLifecycleEvidence? = nil
    ) {
        self.streamID = streamID
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
    func seek(to seconds: Double) async
    func seekToLive() async
    func scrubBackward(seconds: Double) async
    func snapshot() async -> AppStreamRuntimeEvent?
    func snapshot(streamID: Int64) async -> AppStreamRuntimeEvent?
    func snapshots() async -> [AppStreamRuntimeEvent]
}

public actor AppStreamRuntimeService: AppStreamRuntimeControlling {
    private struct StreamRunState: Sendable {
        var task: Task<Void, Never>?
        var token: UUID
    }

    private let registry: StreamRegistry
    private let ingester: any AppStreamRuntimeIngesting
    private let retryPolicy: AppStreamRuntimeRetryPolicy
    private let retrySleep: @Sendable (Int) async throws -> Void
    private let playbackTimeline: AppPlayerTimelineClock?
    private let rollingBuffer: RollingPCMBuffer?
    private let statusStore: AppStreamRuntimeStatusStore?
    private let volumeStore: AppPlaybackVolumeStore?
    private let playbackController: (any AppPCMPlaybackAdapting)?
    private let diagnosticsLog: AppRuntimeDiagnosticsLog
    private let now: @Sendable () -> Date
    private let timestampFormatter: ISO8601DateFormatter

    private var streamRuns: [Int64: StreamRunState] = [:]
    private var pendingStartTokens: [Int64: UUID] = [:]
    private var suspendedStreams: [Int64: Date] = [:]
    private var currentStreamID: Int64?
    private var latestEvents: [Int64: AppStreamRuntimeEvent] = [:]
    private var latestEvent: AppStreamRuntimeEvent?
    private var eventContinuations: [UUID: AsyncStream<AppStreamRuntimeEvent>.Continuation] = [:]

    public init(
        registry: StreamRegistry,
        ingester: any AppStreamRuntimeIngesting,
        retryPolicy: AppStreamRuntimeRetryPolicy = AppStreamRuntimeRetryPolicy(),
        statusStore: AppStreamRuntimeStatusStore? = nil,
        volumeStore: AppPlaybackVolumeStore? = nil,
        playbackTimeline: AppPlayerTimelineClock? = nil,
        rollingBuffer: RollingPCMBuffer? = nil,
        playbackController: (any AppPCMPlaybackAdapting)? = nil,
        diagnosticsLog: AppRuntimeDiagnosticsLog = AppRuntimeDiagnosticsLog(),
        now: @escaping @Sendable () -> Date = { Date() },
        retrySleep: @escaping @Sendable (Int) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds)) * 1_000_000_000)
        }
    ) {
        self.registry = registry
        self.ingester = ingester
        self.retryPolicy = retryPolicy
        self.statusStore = statusStore
        self.volumeStore = volumeStore
        self.playbackTimeline = playbackTimeline
        self.rollingBuffer = rollingBuffer
        self.playbackController = playbackController
        self.diagnosticsLog = diagnosticsLog
        self.now = now
        self.retrySleep = retrySleep
        self.timestampFormatter = ISO8601DateFormatter()
        self.timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func events() -> AsyncStream<AppStreamRuntimeEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            if let latestEvent {
                continuation.yield(latestEvent)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func start(streamID: Int64) async throws {
        diagnosticsLog.recordEvent(
            "runtime.start.requested",
            streamID: streamID,
            phase: "runtime.start",
            fields: ["existingRunCount": String(streamRuns.count)]
        )
        suspendedStreams[streamID] = nil
        let startToken = UUID()
        pendingStartTokens[streamID] = startToken
        await stop(streamID: streamID, clearsPendingStart: false)
        guard pendingStartTokens[streamID] == startToken else {
            diagnosticsLog.recordEvent(
                "runtime.start.superseded",
                streamID: streamID,
                phase: "runtime.start",
                fields: ["existingRunCount": String(streamRuns.count)]
            )
            return
        }
        pendingStartTokens[streamID] = nil
        try beginRun(streamID: streamID, connectionMessagePrefix: "Connecting")
    }

    private func beginRun(
        streamID: Int64,
        connectionMessagePrefix: String,
        recoveryEvidence: AppStreamRuntimeLifecycleEvidence? = nil
    ) throws {
        guard let reconnect = try registry.reconnectSource(id: streamID) else {
            let error = AppStreamRuntimeError.streamNotFound(streamID)
            publish(
                AppStreamRuntimeEvent(
                    streamID: streamID,
                    phase: .error(message: error.description),
                    message: error.description
                ),
                attempt: 0,
                failureMessage: error.description
            )
            throw error
        }
        guard let streamType = StreamType(rawValue: reconnect.streamType),
            streamType == .hls || streamType == .icecast || streamType == .icy
        else {
            let error = AppStreamRuntimeError.unsupportedStreamType(reconnect.streamType)
            publish(
                AppStreamRuntimeEvent(
                    streamID: streamID,
                    phase: .error(message: error.description),
                    message: error.description
                ),
                attempt: 0,
                failureMessage: error.description
            )
            throw error
        }

        let request = AppStreamRuntimeRequest(
            streamID: reconnect.streamID,
            name: reconnect.name,
            source: reconnect.source,
            sourceDescription: reconnect.sourceDescription,
            streamType: streamType,
            isDiarizationEnabled: reconnect.diarizationEnabled
        )
        let token = UUID()
        diagnosticsLog.recordEvent(
            "runtime.run.created",
            streamID: streamID,
            streamName: reconnect.name,
            source: reconnect.source,
            sourceDescription: reconnect.sourceDescription,
            phase: "runtime.beginRun",
            fields: [
                "streamType": streamType.rawValue,
                "token": token.uuidString,
                "connectionMessagePrefix": connectionMessagePrefix,
            ]
        )
        currentStreamID = streamID
        streamRuns[streamID] = StreamRunState(task: nil, token: token)
        publish(
            AppStreamRuntimeEvent(
                streamID: streamID,
                phase: .connecting,
                message: "\(connectionMessagePrefix) \(reconnect.name) via \(reconnect.sourceDescription).",
                lifecycleEvidence: recoveryEvidence
            ),
            attempt: 0
        )

        let ingester = self.ingester
        let retryPolicy = self.retryPolicy
        let retrySleep = self.retrySleep
        let task = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                let runningLifecycleEvidence = await self?.recoveredLifecycleEvidence(from: recoveryEvidence)
                await self?.publishIfCurrent(
                    streamID: streamID,
                    token: token,
                    AppStreamRuntimeEvent(
                        streamID: streamID,
                        phase: .running,
                        message: "Running \(request.name) from \(request.sourceDescription).",
                        lifecycleEvidence: runningLifecycleEvidence
                    ),
                    attempt: attempt
                )
                do {
                    let result = try await ingester.run(request)
                    await self?.finishIfCurrent(
                        streamID: streamID,
                        token: token,
                        event: AppStreamRuntimeEvent(
                            streamID: streamID,
                            phase: .stopped,
                            message: "Stopped \(request.name) after \(result.processedChunks) chunk(s).",
                            result: result
                        ),
                        attempt: attempt
                    )
                    return
                } catch is CancellationError {
                    await self?.finishIfCurrent(
                        streamID: streamID,
                        token: token,
                        event: AppStreamRuntimeEvent(
                            streamID: streamID,
                            phase: .stopped,
                            message: "Stopped \(request.name)."
                        ),
                        attempt: attempt
                    )
                    return
                } catch {
                    let redacted = IngestRedaction.redact(String(describing: error))
                    if attempt < retryPolicy.maximumReconnectAttempts {
                        attempt += 1
                        let seconds = max(0, retryPolicy.backoffSeconds(attempt))
                        await self?.publishIfCurrent(
                            streamID: streamID,
                            token: token,
                            AppStreamRuntimeEvent(
                                streamID: streamID,
                                phase: .reconnecting(nextRetrySeconds: seconds),
                                message: "Runtime failed for \(request.name): \(redacted). Reconnecting in \(seconds) second(s).",
                                lifecycleEvidence: recoveryEvidence
                            ),
                            attempt: attempt,
                            nextRetrySeconds: seconds,
                            failureMessage: redacted
                        )
                        do {
                            try await retrySleep(seconds)
                        } catch {
                            await self?.finishIfCurrent(
                                streamID: streamID,
                                token: token,
                                event: AppStreamRuntimeEvent(
                                    streamID: streamID,
                                    phase: .stopped,
                                    message: "Stopped \(request.name).",
                                    lifecycleEvidence: recoveryEvidence
                                ),
                                attempt: attempt
                            )
                            return
                        }
                        await self?.publishIfCurrent(
                            streamID: streamID,
                            token: token,
                            AppStreamRuntimeEvent(
                                streamID: streamID,
                                phase: .connecting,
                                message: "Reconnecting \(request.name).",
                                lifecycleEvidence: recoveryEvidence
                            ),
                            attempt: attempt
                        )
                    } else {
                        await self?.finishIfCurrent(
                            streamID: streamID,
                            token: token,
                            event: AppStreamRuntimeEvent(
                                streamID: streamID,
                                phase: .error(message: redacted),
                                message: "Runtime failed for \(request.name): \(redacted).",
                                lifecycleEvidence: recoveryEvidence
                            ),
                            attempt: attempt,
                            failureMessage: redacted
                        )
                        return
                    }
                }
            }
        }
        streamRuns[streamID]?.task = task
    }

    public func pause() async {
        guard let streamID = currentStreamID else { return }
        await pause(streamID: streamID)
    }

    public func pause(streamID: Int64) async {
        guard streamRuns[streamID] != nil else { return }
        diagnosticsLog.recordEvent(
            "runtime.pause.requested",
            streamID: streamID,
            phase: "runtime.pause"
        )
        if let playbackController, let playbackTimeline {
            await playbackController.pause(timeline: playbackTimeline)
        }
        publish(
            AppStreamRuntimeEvent(
                streamID: streamID,
                phase: .paused,
                message: "Paused stream \(streamID)."
            ),
            attempt: latestAttempt(streamID: streamID)
        )
    }

    public func resume() async {
        guard let streamID = currentStreamID else { return }
        await resume(streamID: streamID)
    }

    public func resume(streamID: Int64) async {
        guard streamRuns[streamID] != nil else { return }
        diagnosticsLog.recordEvent(
            "runtime.resume.requested",
            streamID: streamID,
            phase: "runtime.resume"
        )
        if let playbackController, let playbackTimeline {
            await playbackController.resume(timeline: playbackTimeline)
        }
        publish(
            AppStreamRuntimeEvent(
                streamID: streamID,
                phase: .running,
                message: "Resumed stream \(streamID)."
            ),
            attempt: latestAttempt(streamID: streamID)
        )
    }

    public func stop() async {
        guard let streamID = currentStreamID else { return }
        await stop(streamID: streamID)
    }

    public func stop(streamID: Int64) async {
        await stop(streamID: streamID, clearsPendingStart: true)
    }

    private func stop(streamID: Int64, clearsPendingStart: Bool) async {
        diagnosticsLog.recordEvent(
            "runtime.stop.requested",
            streamID: streamID,
            phase: "runtime.stop",
            fields: ["hadRun": String(streamRuns[streamID] != nil)]
        )
        let state = streamRuns.removeValue(forKey: streamID)
        if clearsPendingStart {
            pendingStartTokens[streamID] = nil
        }
        state?.task?.cancel()
        if let playbackController, let playbackTimeline {
            await playbackController.stop(timeline: playbackTimeline)
        }
        if currentStreamID == streamID {
            currentStreamID = streamRuns.keys.sorted().first
        }
        guard state != nil || clearsPendingStart else { return }
        publish(
            AppStreamRuntimeEvent(
                streamID: streamID,
                phase: .stopped,
                message: "Stopped stream \(streamID)."
            ),
            attempt: latestAttempt(streamID: streamID)
        )
        persistStoppedStatus(streamID: streamID)
    }

    public func stopAll() async {
        let streamIDs = Array(streamRuns.keys)
        for streamID in streamIDs {
            await stop(streamID: streamID)
        }
    }

    public func suspendForSystemSleep(reason: String) async {
        let suspendedAt = now()
        let streamIDs = streamRuns.keys.sorted()
        guard !streamIDs.isEmpty else { return }
        let states = streamIDs.compactMap { streamID -> (Int64, StreamRunState)? in
            guard let state = streamRuns.removeValue(forKey: streamID) else { return nil }
            return (streamID, state)
        }
        currentStreamID = streamRuns.keys.sorted().first
        for (streamID, state) in states {
            suspendedStreams[streamID] = suspendedAt
            state.task?.cancel()
            let evidence = AppStreamRuntimeLifecycleEvidence(
                reason: reason,
                suspendedAt: timestamp(for: suspendedAt)
            )
            publish(
                AppStreamRuntimeEvent(
                    streamID: streamID,
                    phase: .suspended,
                    message: "Suspended stream \(streamID) for system sleep: \(reason).",
                    lifecycleEvidence: evidence
                ),
                attempt: latestAttempt(streamID: streamID)
            )
        }
    }

    public func recoverFromSystemWake(reason: String) async {
        let recoveryStartedAt = now()
        let captured = suspendedStreams.sorted { $0.key < $1.key }
        guard !captured.isEmpty else { return }
        suspendedStreams.removeAll()
        for (streamID, suspendedAt) in captured {
            let latency = recoveryStartedAt.timeIntervalSince(suspendedAt)
            let evidence = AppStreamRuntimeLifecycleEvidence(
                reason: reason,
                suspendedAt: timestamp(for: suspendedAt),
                recoveryStartedAt: timestamp(for: recoveryStartedAt),
                recoveryLatencySeconds: latency
            )
            publish(
                AppStreamRuntimeEvent(
                    streamID: streamID,
                    phase: .recovering,
                    message: "Recovering stream \(streamID) after system wake: \(reason).",
                    lifecycleEvidence: evidence
                ),
                attempt: latestAttempt(streamID: streamID)
            )
            do {
                try beginRun(
                    streamID: streamID,
                    connectionMessagePrefix: "Recovering",
                    recoveryEvidence: evidence
                )
            } catch {
                let redacted = IngestRedaction.redact(String(describing: error))
                publish(
                    AppStreamRuntimeEvent(
                        streamID: streamID,
                        phase: .error(message: redacted),
                        message: "Recovery failed for stream \(streamID): \(redacted).",
                        lifecycleEvidence: evidence
                    ),
                    attempt: latestAttempt(streamID: streamID),
                    failureMessage: redacted
                )
            }
        }
    }

    public func setVolume(streamID: Int64, volume: Double) async {
        diagnosticsLog.recordEvent(
            "runtime.volume.requested",
            streamID: streamID,
            phase: "runtime.volume",
            fields: ["volume": String(format: "%.3f", min(max(volume, 0), 1))]
        )
        await volumeStore?.setVolume(streamID: streamID, volume: volume)
        await playbackController?.applyPlaybackVolume(streamID: streamID)
        let percent = Int((min(max(volume, 0), 1) * 100).rounded())
        if let existing = latestEvents[streamID] {
            publish(
                AppStreamRuntimeEvent(
                    streamID: streamID,
                    phase: existing.phase,
                    message: "Volume for stream \(streamID) set to \(percent)%.",
                    result: existing.result,
                    lifecycleEvidence: existing.lifecycleEvidence
                ),
                attempt: latestAttempt(streamID: streamID)
            )
        }
    }

    public func setMuted(streamID: Int64, isMuted: Bool) async {
        diagnosticsLog.recordEvent(
            "runtime.mute.requested",
            streamID: streamID,
            phase: "runtime.volume",
            fields: ["isMuted": String(isMuted)]
        )
        await volumeStore?.setMuted(streamID: streamID, isMuted: isMuted)
        await playbackController?.applyPlaybackVolume(streamID: streamID)
        if let existing = latestEvents[streamID] {
            publish(
                AppStreamRuntimeEvent(
                    streamID: streamID,
                    phase: existing.phase,
                    message: isMuted ? "Stream \(streamID) muted." : "Stream \(streamID) unmuted.",
                    result: existing.result,
                    lifecycleEvidence: existing.lifecycleEvidence
                ),
                attempt: latestAttempt(streamID: streamID)
            )
        }
    }

    public func seek(to seconds: Double) async {
        guard let streamID = currentStreamID, let rollingBuffer, let playbackTimeline else {
            return
        }
        let result: RollingBufferSeekResult
        if seconds.isFinite && seconds >= 0 {
            result = await rollingBuffer.seek(to: seconds)
        } else {
            result = .unavailable(
                requestedSeconds: seconds,
                bufferedRange: await rollingBuffer.snapshot().bufferedRange
            )
        }
        await playSeekResult(result, streamID: streamID, playbackTimeline: playbackTimeline)
    }

    public func seekToLive() async {
        guard let streamID = currentStreamID, let rollingBuffer, let playbackTimeline else {
            return
        }
        let result = await rollingBuffer.seekToLive()
        await playSeekResult(result, streamID: streamID, playbackTimeline: playbackTimeline)
    }

    public func scrubBackward(seconds: Double) async {
        guard let streamID = currentStreamID, let rollingBuffer, let playbackTimeline else {
            return
        }
        let timeline = await playbackTimeline.snapshot()
        let requested = max(0, timeline.liveEdgeSeconds - max(0, seconds))
        let result = await rollingBuffer.seek(to: requested)
        await playSeekResult(result, streamID: streamID, playbackTimeline: playbackTimeline)
    }

    private func playSeekResult(
        _ result: RollingBufferSeekResult,
        streamID: Int64,
        playbackTimeline: AppPlayerTimelineClock
    ) async {
        if case .available(let frame) = result, let playbackController {
            diagnosticsLog.recordEvent(
                "runtime.seek.playback.requested",
                streamID: streamID,
                phase: "runtime.seek",
                fields: [
                    "frameSequence": String(frame.sequence),
                    "startSeconds": String(format: "%.3f", frame.startSeconds),
                    "endSeconds": String(format: "%.3f", frame.endSeconds),
                ]
            )
            do {
                try await playbackController.playReplacingScheduledBuffers(
                    [frame],
                    timeline: playbackTimeline
                )
            } catch {
                diagnosticsLog.recordEvent(
                    "runtime.seek.playback.failed",
                    streamID: streamID,
                    phase: "runtime.seek",
                    fields: ["error": IngestRedaction.redact(String(describing: error))]
                )
                await playbackTimeline.applySeekResult(result)
            }
        } else {
            await playbackTimeline.applySeekResult(result)
        }
        await publishPlayerTimelineEvent(streamID: streamID, playbackTimeline: playbackTimeline)
    }

    public func snapshot() async -> AppStreamRuntimeEvent? {
        guard let latestEvent else { return nil }
        return await eventWithCurrentPlayerTimeline(latestEvent)
    }

    public func snapshot(streamID: Int64) async -> AppStreamRuntimeEvent? {
        guard let event = latestEvents[streamID] else { return nil }
        return await eventWithCurrentPlayerTimeline(event)
    }

    public func snapshots() async -> [AppStreamRuntimeEvent] {
        var events: [AppStreamRuntimeEvent] = []
        for event in latestEvents.values.sorted(by: { $0.streamID < $1.streamID }) {
            events.append(await eventWithCurrentPlayerTimeline(event))
        }
        return events
    }

    private func eventWithCurrentPlayerTimeline(
        _ event: AppStreamRuntimeEvent
    ) async -> AppStreamRuntimeEvent {
        guard let playbackTimeline else { return event }
        let snapshot = await playbackTimeline.snapshot()
        guard snapshot.streamID == event.streamID else { return event }
        let existingResult = event.result
        return AppStreamRuntimeEvent(
            streamID: event.streamID,
            phase: event.phase,
            message: snapshot.lastMessage,
            result: AppStreamRuntimeResult(
                streamID: event.streamID,
                runID: existingResult?.runID,
                processedChunks: existingResult?.processedChunks ?? 0,
                diagnosticCount: existingResult?.diagnosticCount ?? 0,
                playerTimeline: snapshot
            ),
            lifecycleEvidence: event.lifecycleEvidence
        )
    }

    private func recoveredLifecycleEvidence(
        from evidence: AppStreamRuntimeLifecycleEvidence?
    ) -> AppStreamRuntimeLifecycleEvidence? {
        evidence.map {
            AppStreamRuntimeLifecycleEvidence(
                reason: $0.reason,
                suspendedAt: $0.suspendedAt,
                recoveryStartedAt: $0.recoveryStartedAt,
                recoveredAt: timestamp(),
                recoveryLatencySeconds: $0.recoveryLatencySeconds
            )
        }
    }

    private func publish(
        _ event: AppStreamRuntimeEvent,
        attempt: Int,
        nextRetrySeconds: Int? = nil,
        failureMessage: String? = nil
    ) {
        diagnosticsLog.recordEvent(
            "runtime.event.published",
            streamID: event.streamID,
            phase: event.phase.statusPhase.rawValue,
            message: event.message,
            fields: [
                "attempt": String(attempt),
                "nextRetrySeconds": nextRetrySeconds.map(String.init) ?? "nil",
                "hasFailureMessage": String(failureMessage != nil),
                "hasResult": String(event.result != nil),
            ]
        )
        latestEvents[event.streamID] = event
        latestEvent = event
        persistStatus(
            event: event,
            attempt: attempt,
            nextRetrySeconds: nextRetrySeconds,
            failureMessage: failureMessage
        )
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func publishIfCurrent(
        streamID: Int64,
        token: UUID,
        _ event: AppStreamRuntimeEvent,
        attempt: Int,
        nextRetrySeconds: Int? = nil,
        failureMessage: String? = nil
    ) {
        guard streamRuns[streamID]?.token == token else { return }
        publish(
            event,
            attempt: attempt,
            nextRetrySeconds: nextRetrySeconds,
            failureMessage: failureMessage
        )
    }

    private func finishIfCurrent(
        streamID: Int64,
        token: UUID,
        event: AppStreamRuntimeEvent,
        attempt: Int,
        failureMessage: String? = nil
    ) {
        guard streamRuns[streamID]?.token == token else { return }
        streamRuns.removeValue(forKey: streamID)
        if currentStreamID == streamID {
            currentStreamID = streamRuns.keys.sorted().first
        }
        publish(event, attempt: attempt, failureMessage: failureMessage)
    }

    private func publishPlayerTimelineEvent(
        streamID: Int64,
        playbackTimeline: AppPlayerTimelineClock
    ) async {
        let snapshot = await playbackTimeline.snapshot()
        publish(
            AppStreamRuntimeEvent(
                streamID: streamID,
                phase: latestEvents[streamID]?.phase ?? .running,
                message: snapshot.lastMessage,
                result: AppStreamRuntimeResult(
                    streamID: streamID,
                    playerTimeline: snapshot
                )
            ),
            attempt: latestAttempt(streamID: streamID)
        )
    }

    private func persistStatus(
        event: AppStreamRuntimeEvent,
        attempt: Int,
        nextRetrySeconds: Int?,
        failureMessage: String?
    ) {
        guard let statusStore else { return }
        let updatedAt = timestamp()
        let failure = failureMessage.map {
            AppStreamRuntimeRecentFailure(message: $0, occurredAt: updatedAt)
        }
        let nextRetryAt = nextRetrySeconds.map { seconds in
            timestamp(for: now().addingTimeInterval(TimeInterval(max(0, seconds))))
        }
        do {
            try statusStore.upsert(
                AppStreamRuntimeStatusUpdate(
                    streamID: event.streamID,
                    phase: event.phase.statusPhase,
                    attempt: attempt,
                    maxAttempts: retryPolicy.maximumReconnectAttempts,
                    nextRetrySeconds: nextRetrySeconds,
                    nextRetryAt: nextRetryAt,
                    updatedAt: updatedAt,
                    recentFailure: failure,
                    lifecycleEvidence: event.lifecycleEvidence
                )
            )
        } catch {
            // Missing or removed streams may not have a status row to update; keep the
            // redacted in-memory event visible without letting one store write affect siblings.
        }
    }

    private func persistStoppedStatus(streamID: Int64) {
        guard let statusStore else { return }
        let attempt = latestAttempt(streamID: streamID)
        do {
            try statusStore.upsert(
                AppStreamRuntimeStatusUpdate(
                    streamID: streamID,
                    phase: .stopped,
                    attempt: attempt,
                    maxAttempts: retryPolicy.maximumReconnectAttempts,
                    updatedAt: timestamp()
                )
            )
        } catch {
            // Keep Stop best-effort: removed streams can race with status persistence.
        }
    }

    private func latestAttempt(streamID: Int64) -> Int {
        guard let statusStore, let snapshot = try? statusStore.status(streamID: streamID) else {
            return 0
        }
        return snapshot.attempt
    }

    private func timestamp() -> String {
        timestamp(for: now())
    }

    private func timestamp(for date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    private func removeContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }
}
