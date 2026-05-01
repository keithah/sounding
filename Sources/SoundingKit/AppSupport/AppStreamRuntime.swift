import Foundation

public struct AppStreamRuntimeRequest: Equatable, Sendable {
    public var streamID: Int64
    public var name: String
    public var source: String
    public var sourceDescription: String
    public var streamType: StreamType

    public init(
        streamID: Int64,
        name: String,
        source: String,
        sourceDescription: String,
        streamType: StreamType
    ) {
        self.streamID = streamID
        self.name = name
        self.source = source
        self.sourceDescription = sourceDescription
        self.streamType = streamType
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
    private let fingerprinter: any AudioFingerprinting
    private let fingerprintEnricher: any AudioFingerprintEnriching
    private let now: StreamIngestPipeline.TimestampProvider
    private let player: (any AppPCMPlaybackAdapting)?
    private let timeline: AppPlayerTimelineClock
    private let rollingBuffer: RollingPCMBuffer?

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
        now: @escaping StreamIngestPipeline.TimestampProvider = {
            ISO8601DateFormatter().string(from: Date())
        }
    ) {
        self.database = database
        self.decoder = decoder
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.fingerprinter = fingerprinter
        self.fingerprintEnricher = fingerprintEnricher
        self.player = player
        self.timeline = timeline
        self.rollingBuffer = rollingBuffer
        self.now = now
    }

    public func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
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
            runtimeDecoder = SinglePathPCMDecoder(
                streamID: request.streamID,
                upstream: decoder,
                player: player,
                timeline: timeline,
                rollingBuffer: rollingBuffer
            )
        } else {
            runtimeDecoder = decoder
        }

        do {
            let result = try await StreamIngestPipeline(
                database: database,
                decoder: runtimeDecoder,
                transcriber: transcriber,
                diarizer: diarizer,
                fingerprinter: fingerprinter,
                fingerprintEnricher: fingerprintEnricher,
                now: now
            ).run(
                streamID: request.streamID,
                source: request.source,
                streamType: request.streamType
            )
            if let player {
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
        } catch {
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
}

public enum AppStreamRuntimeStatusPhase: String, CaseIterable, Codable, Equatable, Sendable {
    case connecting
    case running
    case paused
    case reconnecting
    case stopped
    case error
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

    public init(
        streamID: Int64,
        phase: AppStreamRuntimeStatusPhase,
        attempt: Int = 0,
        maxAttempts: Int = 0,
        nextRetrySeconds: Int? = nil,
        nextRetryAt: String? = nil,
        updatedAt: String,
        recentFailure: AppStreamRuntimeRecentFailure? = nil
    ) {
        self.streamID = streamID
        self.phase = phase
        self.attempt = max(0, attempt)
        self.maxAttempts = max(0, maxAttempts)
        self.nextRetrySeconds = nextRetrySeconds.map { max(0, $0) }
        self.nextRetryAt = nextRetryAt.map(IngestRedaction.redact)
        self.updatedAt = updatedAt
        self.recentFailure = recentFailure
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
        recentFailure: AppStreamRuntimeRecentFailure?
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
    }
}

public enum AppStreamRuntimePhase: Equatable, Sendable {
    case connecting
    case running
    case paused
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

    public init(
        streamID: Int64,
        phase: AppStreamRuntimePhase,
        message: String,
        result: AppStreamRuntimeResult? = nil
    ) {
        self.streamID = streamID
        self.phase = phase
        self.message = IngestRedaction.redact(message)
        self.result = result
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
    func resume() async
    func stop() async
    func seek(to seconds: Double) async
    func seekToLive() async
    func scrubBackward(seconds: Double) async
    func snapshot() async -> AppStreamRuntimeEvent?
}

public actor AppStreamRuntimeService: AppStreamRuntimeControlling {
    private let registry: StreamRegistry
    private let ingester: any AppStreamRuntimeIngesting
    private let retryPolicy: AppStreamRuntimeRetryPolicy
    private let retrySleep: @Sendable (Int) async throws -> Void
    private let playbackTimeline: AppPlayerTimelineClock?
    private let rollingBuffer: RollingPCMBuffer?

    private var currentTask: Task<Void, Never>?
    private var currentToken: UUID?
    private var currentStreamID: Int64?
    private var latestEvent: AppStreamRuntimeEvent?
    private var eventContinuations: [UUID: AsyncStream<AppStreamRuntimeEvent>.Continuation] = [:]

    public init(
        registry: StreamRegistry,
        ingester: any AppStreamRuntimeIngesting,
        retryPolicy: AppStreamRuntimeRetryPolicy = AppStreamRuntimeRetryPolicy(),
        playbackTimeline: AppPlayerTimelineClock? = nil,
        rollingBuffer: RollingPCMBuffer? = nil,
        retrySleep: @escaping @Sendable (Int) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds)) * 1_000_000_000)
        }
    ) {
        self.registry = registry
        self.ingester = ingester
        self.retryPolicy = retryPolicy
        self.playbackTimeline = playbackTimeline
        self.rollingBuffer = rollingBuffer
        self.retrySleep = retrySleep
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
        stop()

        guard let reconnect = try registry.reconnectSource(id: streamID) else {
            let event = AppStreamRuntimeEvent(
                streamID: streamID,
                phase: .error(message: AppStreamRuntimeError.streamNotFound(streamID).description),
                message: "Stream \(streamID) was not found or is not active."
            )
            publish(event)
            throw AppStreamRuntimeError.streamNotFound(streamID)
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
                )
            )
            throw error
        }

        let request = AppStreamRuntimeRequest(
            streamID: reconnect.streamID,
            name: reconnect.name,
            source: reconnect.source,
            sourceDescription: reconnect.sourceDescription,
            streamType: streamType
        )
        let token = UUID()
        currentToken = token
        currentStreamID = streamID
        publish(
            AppStreamRuntimeEvent(
                streamID: streamID,
                phase: .connecting,
                message: "Connecting \(reconnect.name) via \(reconnect.sourceDescription)."
            )
        )

        let ingester = self.ingester
        let retryPolicy = self.retryPolicy
        let retrySleep = self.retrySleep
        currentTask = Task {
            var attempt = 0
            while !Task.isCancelled {
                do {
                    publishIfCurrent(
                        token: token,
                        AppStreamRuntimeEvent(
                            streamID: streamID,
                            phase: .running,
                            message: "Running \(request.name) from \(request.sourceDescription)."
                        )
                    )
                    let result = try await ingester.run(request)
                    finishIfCurrent(
                        token: token,
                        event: AppStreamRuntimeEvent(
                            streamID: streamID,
                            phase: .stopped,
                            message:
                                "Stopped \(request.name) after \(result.processedChunks) chunk(s).",
                            result: result
                        )
                    )
                    return
                } catch is CancellationError {
                    finishIfCurrent(
                        token: token,
                        event: AppStreamRuntimeEvent(
                            streamID: streamID,
                            phase: .stopped,
                            message: "Stopped \(request.name)."
                        )
                    )
                    return
                } catch {
                    let redacted = IngestRedaction.redact(String(describing: error))
                    if attempt < retryPolicy.maximumReconnectAttempts {
                        attempt += 1
                        let seconds = retryPolicy.backoffSeconds(attempt)
                        publishIfCurrent(
                            token: token,
                            AppStreamRuntimeEvent(
                                streamID: streamID,
                                phase: .reconnecting(nextRetrySeconds: seconds),
                                message:
                                    "Runtime failed for \(request.name): \(redacted). Reconnecting in \(seconds) second(s)."
                            )
                        )
                        do {
                            try await retrySleep(seconds)
                        } catch {
                            finishIfCurrent(
                                token: token,
                                event: AppStreamRuntimeEvent(
                                    streamID: streamID,
                                    phase: .stopped,
                                    message: "Stopped \(request.name)."
                                )
                            )
                            return
                        }
                        publishIfCurrent(
                            token: token,
                            AppStreamRuntimeEvent(
                                streamID: streamID,
                                phase: .connecting,
                                message: "Reconnecting \(request.name)."
                            )
                        )
                    } else {
                        finishIfCurrent(
                            token: token,
                            event: AppStreamRuntimeEvent(
                                streamID: streamID,
                                phase: .error(message: redacted),
                                message: "Runtime failed for \(request.name): \(redacted)."
                            )
                        )
                        return
                    }
                }
            }
        }
    }

    public func pause() {
        guard let streamID = currentStreamID, currentTask != nil else { return }
        publish(
            AppStreamRuntimeEvent(
                streamID: streamID,
                phase: .paused,
                message: "Paused stream \(streamID)."
            )
        )
    }

    public func resume() {
        guard let streamID = currentStreamID, currentTask != nil else { return }
        publish(
            AppStreamRuntimeEvent(
                streamID: streamID,
                phase: .running,
                message: "Resumed stream \(streamID)."
            )
        )
    }

    public func stop() {
        currentTask?.cancel()
        currentTask = nil
        currentToken = nil
        guard let streamID = currentStreamID else { return }
        currentStreamID = nil
        publish(
            AppStreamRuntimeEvent(
                streamID: streamID,
                phase: .stopped,
                message: "Stopped stream \(streamID)."
            )
        )
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
        await playbackTimeline.applySeekResult(result)
        await publishPlayerTimelineEvent(streamID: streamID, playbackTimeline: playbackTimeline)
    }

    public func seekToLive() async {
        guard let streamID = currentStreamID, let rollingBuffer, let playbackTimeline else {
            return
        }
        let result = await rollingBuffer.seekToLive()
        await playbackTimeline.applySeekResult(result)
        await publishPlayerTimelineEvent(streamID: streamID, playbackTimeline: playbackTimeline)
    }

    public func scrubBackward(seconds: Double) async {
        guard let streamID = currentStreamID, let rollingBuffer, let playbackTimeline else {
            return
        }
        let timeline = await playbackTimeline.snapshot()
        let requested = max(0, timeline.liveEdgeSeconds - max(0, seconds))
        let result = await rollingBuffer.seek(to: requested)
        await playbackTimeline.applySeekResult(result)
        await publishPlayerTimelineEvent(streamID: streamID, playbackTimeline: playbackTimeline)
    }

    public func snapshot() -> AppStreamRuntimeEvent? {
        latestEvent
    }

    private func publish(_ event: AppStreamRuntimeEvent) {
        latestEvent = event
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func publishIfCurrent(token: UUID, _ event: AppStreamRuntimeEvent) {
        guard currentToken == token else { return }
        publish(event)
    }

    private func finishIfCurrent(token: UUID, event: AppStreamRuntimeEvent) {
        guard currentToken == token else { return }
        currentTask = nil
        currentToken = nil
        currentStreamID = nil
        publish(event)
    }

    private func publishPlayerTimelineEvent(
        streamID: Int64,
        playbackTimeline: AppPlayerTimelineClock
    ) async {
        let snapshot = await playbackTimeline.snapshot()
        publish(
            AppStreamRuntimeEvent(
                streamID: streamID,
                phase: latestEvent?.phase ?? .running,
                message: snapshot.lastMessage,
                result: AppStreamRuntimeResult(
                    streamID: streamID,
                    playerTimeline: snapshot
                )
            )
        )
    }

    private func removeContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }
}
