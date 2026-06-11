import Foundation

public enum StreamIngestAppRuntimeMode: Equatable, Sendable {
    case singlePass
    case livePolling(maxChunksPerPass: Int)

    var maxChunksPerPass: Int? {
        switch self {
        case .singlePass:
            return nil
        case .livePolling(let maxChunksPerPass):
            return max(1, maxChunksPerPass)
        }
    }

    var isLivePolling: Bool {
        if case .livePolling = self { return true }
        return false
    }
}

public enum StreamIngestAppRuntimeRunnerError: Error, CustomStringConvertible, Equatable, Sendable {
    case livePollTimedOut(seconds: Double)

    public var description: String {
        switch self {
        case .livePollTimedOut(let seconds):
            return "Live ingest poll timed out after \(String(format: "%.1f", seconds))s."
        }
    }
}

public struct StreamIngestAppRuntimeRunner: AppStreamRuntimeIngesting {
    private let database: SoundingDatabase
    private let decoder: any AudioDecoding
    private let transcriber: any MLTranscription
    private let diarizer: any SpeakerDiarization
    private let diarizerFactory: @Sendable (Bool) -> any SpeakerDiarization
    private let fingerprinter: any AudioFingerprinting
    private let audioContentClassifier: (any AudioContentClassifying)?
    private let minimumMusicProbabilityForFingerprinting: Double
    private let fingerprintEnricher: any AudioFingerprintEnriching
    private let now: StreamIngestPipeline.TimestampProvider
    private let player: (any AppPCMPlaybackAdapting)?
    private let timeline: AppPlayerTimelineClock
    private let rollingBuffer: RollingPCMBuffer?
    private let playbackSelection: AppPlaybackStreamSelection?
    private let audioArchiveStore: AudioArchiveStore?
    private let diagnosticsLog: AppRuntimeDiagnosticsLog
    private let ingestMode: StreamIngestAppRuntimeMode
    private let livePollIntervalNanoseconds: UInt64
    private let hlsEmptyPollIntervalNanoseconds: UInt64
    private let livePollTimeoutNanoseconds: UInt64
    private let playbackStopTimeoutNanoseconds: UInt64

    public init(
        database: SoundingDatabase,
        decoder: any AudioDecoding,
        transcriber: any MLTranscription,
        diarizer: any SpeakerDiarization,
        fingerprinter: any AudioFingerprinting = NoOpAudioFingerprinter(),
        audioContentClassifier: (any AudioContentClassifying)? = nil,
        minimumMusicProbabilityForFingerprinting: Double = 0.80,
        fingerprintEnricher: any AudioFingerprintEnriching = NoOpAudioFingerprintEnricher(),
        player: (any AppPCMPlaybackAdapting)? = nil,
        timeline: AppPlayerTimelineClock = AppPlayerTimelineClock(),
        rollingBuffer: RollingPCMBuffer? = nil,
        playbackSelection: AppPlaybackStreamSelection? = nil,
        audioArchiveStore: AudioArchiveStore? = nil,
        diagnosticsLog: AppRuntimeDiagnosticsLog = AppRuntimeDiagnosticsLog(),
        ingestMode: StreamIngestAppRuntimeMode = .singlePass,
        livePollIntervalNanoseconds: UInt64 = 2_000_000_000,
        hlsEmptyPollIntervalNanoseconds: UInt64 = 500_000_000,
        livePollTimeoutNanoseconds: UInt64 = 45_000_000_000,
        playbackStopTimeoutNanoseconds: UInt64 = 2_000_000_000,
        diarizerFactory: (@Sendable (Bool) -> any SpeakerDiarization)? = nil,
        now: @escaping StreamIngestPipeline.TimestampProvider = { SoundingTimestampClock.timestamp() }
    ) {
        self.database = database
        self.decoder = decoder
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.diarizerFactory = diarizerFactory ?? { _ in diarizer }
        self.fingerprinter = fingerprinter
        self.audioContentClassifier = audioContentClassifier
        self.minimumMusicProbabilityForFingerprinting = minimumMusicProbabilityForFingerprinting
        self.fingerprintEnricher = fingerprintEnricher
        self.player = player
        self.timeline = timeline
        self.rollingBuffer = rollingBuffer
        self.playbackSelection = playbackSelection
        self.audioArchiveStore = audioArchiveStore
        self.diagnosticsLog = diagnosticsLog
        self.ingestMode = ingestMode
        self.livePollIntervalNanoseconds = livePollIntervalNanoseconds
        self.hlsEmptyPollIntervalNanoseconds = hlsEmptyPollIntervalNanoseconds
        self.livePollTimeoutNanoseconds = livePollTimeoutNanoseconds
        self.playbackStopTimeoutNanoseconds = playbackStopTimeoutNanoseconds
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
                "ingestMode": String(describing: ingestMode),
                "isDiarizationEnabled": String(request.isDiarizationEnabled),
                "isAudioArchiveEnabled": String(request.isAudioArchiveEnabled),
                "transcriptionPolicy": request.transcriptionPolicy.rawValue,
            ]
        )
        let runtimeDecoder: any AudioDecoding
        if let player {
            if let rollingBuffer {
                await rollingBuffer.start(streamID: request.streamID)
                await timeline.updateRollingBuffer(await rollingBuffer.snapshot())
            }
            let streamOwnsPlayback = if let playbackSelection {
                await playbackSelection.isSelected(streamID: request.streamID)
            } else {
                true
            }
            if streamOwnsPlayback {
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
            } else {
                diagnosticsLog.recordEvent(
                    "runner.playback.prepare.skipped",
                    streamID: request.streamID,
                    streamName: request.name,
                    source: request.source,
                    sourceDescription: request.sourceDescription,
                    phase: "runner.playback",
                    fields: ["reason": "stream is not selected for playback"]
                )
            }
            runtimeDecoder = SinglePathPCMDecoder(
                streamID: request.streamID,
                upstream: decoder,
                player: player,
                timeline: timeline,
                rollingBuffer: rollingBuffer,
                playbackSelection: playbackSelection,
                database: database
            )
        } else {
            runtimeDecoder = decoder
        }
        let runtimeDiarizer = diarizerFactory(request.isDiarizationEnabled)

        do {
            if player != nil && ingestMode.isLivePolling {
                var totalProcessedChunks = 0
                var totalDiagnostics = 0
                var lastRunID: Int64?
                while !Task.isCancelled {
                    let result = try await runLiveIngestPassWithTimeout(
                        request,
                        decoder: runtimeDecoder,
                        diarizer: runtimeDiarizer,
                        maxChunks: ingestMode.maxChunksPerPass
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
                        try await Task.sleep(nanoseconds: emptyPollIntervalNanoseconds(for: request))
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
                diarizer: runtimeDiarizer,
                maxChunks: ingestMode.maxChunksPerPass
            )
            if let player, !ingestMode.isLivePolling {
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
            if let player, !ingestMode.isLivePolling {
                await stopPlaybackDuringCleanup(
                    player,
                    request: request,
                    reason: "cancelled"
                )
            } else if player != nil {
                recordLivePlaybackStopSkipped(request: request, reason: "cancelled")
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
            if let player, !ingestMode.isLivePolling {
                await stopPlaybackDuringCleanup(
                    player,
                    request: request,
                    reason: "failed"
                )
                await timeline.updatePlayerState(
                    .failed(message: String(describing: error)),
                    message: "Runtime playback failed: \(error).")
            } else if player != nil {
                if await streamOwnsPlayback(request.streamID) {
                    await stopPlaybackDuringCleanup(
                        player!,
                        request: request,
                        reason: "failed"
                    )
                    await timeline.updatePlayerState(
                        .failed(message: String(describing: error)),
                        message: "Runtime playback failed: \(error).")
                } else {
                    recordLivePlaybackStopSkipped(request: request, reason: "failed-non-owner")
                }
            }
            if let rollingBuffer {
                await timeline.updateRollingBuffer(await rollingBuffer.cleanup())
            }
            throw error
        }
    }

    private func emptyPollIntervalNanoseconds(for request: AppStreamRuntimeRequest) -> UInt64 {
        request.streamType == .hls
            ? hlsEmptyPollIntervalNanoseconds
            : livePollIntervalNanoseconds
    }

    private func stopPlaybackDuringCleanup(
        _ player: any AppPCMPlaybackAdapting,
        request: AppStreamRuntimeRequest,
        reason: String
    ) async {
        diagnosticsLog.recordEvent(
            "runner.playback.stop.requested",
            streamID: request.streamID,
            streamName: request.name,
            source: request.source,
            sourceDescription: request.sourceDescription,
            phase: "runner.stop",
            fields: ["reason": reason]
        )
        let timeoutNanoseconds = playbackStopTimeoutNanoseconds
        let completed = await AppPlaybackStopCoordinator.stop(
            player,
            timeline: timeline,
            timeoutNanoseconds: timeoutNanoseconds
        ) { [diagnosticsLog] in
            diagnosticsLog.recordEvent(
                "runner.playback.stop.timed_out",
                streamID: request.streamID,
                streamName: request.name,
                source: request.source,
                sourceDescription: request.sourceDescription,
                phase: "runner.stop",
                fields: [
                    "reason": reason,
                    "timeoutNanoseconds": String(timeoutNanoseconds),
                ]
            )
        }
        if completed {
            diagnosticsLog.recordEvent(
                "runner.playback.stop.completed",
                streamID: request.streamID,
                streamName: request.name,
                source: request.source,
                sourceDescription: request.sourceDescription,
                phase: "runner.stop",
                fields: ["reason": reason]
            )
        }
    }

    private func recordLivePlaybackStopSkipped(
        request: AppStreamRuntimeRequest,
        reason: String
    ) {
        diagnosticsLog.recordEvent(
            "runner.playback.stop.skipped",
            streamID: request.streamID,
            streamName: request.name,
            source: request.source,
            sourceDescription: request.sourceDescription,
            phase: "runner.stop",
            fields: [
                "reason": reason,
                "mode": "livePolling",
            ]
        )
    }

    private func streamOwnsPlayback(_ streamID: Int64) async -> Bool {
        guard let playbackSelection else { return true }
        return await playbackSelection.isSelected(streamID: streamID)
    }

    private func runIngestPass(
        _ request: AppStreamRuntimeRequest,
        decoder runtimeDecoder: any AudioDecoding,
        diarizer runtimeDiarizer: any SpeakerDiarization,
        maxChunks: Int?
    ) async throws -> StreamIngestResult {
        let result = try await StreamIngestPipeline(
            database: database,
            decoder: runtimeDecoder,
            transcriber: transcriber,
            diarizer: runtimeDiarizer,
            fingerprinter: fingerprinter,
            audioContentClassifier: audioContentClassifier,
            minimumMusicProbabilityForFingerprinting: minimumMusicProbabilityForFingerprinting,
            fingerprintEnricher: fingerprintEnricher,
            audioArchiveStore: audioArchiveStore,
            audioArchiveEnabled: request.isAudioArchiveEnabled,
            transcriptionPolicy: request.transcriptionPolicy,
            now: now
        ).run(
            streamID: request.streamID,
            source: request.source,
            streamType: request.streamType,
            maxChunks: maxChunks
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

    private func runLiveIngestPassWithTimeout(
        _ request: AppStreamRuntimeRequest,
        decoder runtimeDecoder: any AudioDecoding,
        diarizer runtimeDiarizer: any SpeakerDiarization,
        maxChunks: Int?
    ) async throws -> StreamIngestResult {
        let timeoutNanoseconds = livePollTimeoutNanoseconds
        return try await withThrowingTaskGroup(of: StreamIngestResult.self) { group in
            group.addTask {
                try await runIngestPass(
                    request,
                    decoder: runtimeDecoder,
                    diarizer: runtimeDiarizer,
                    maxChunks: maxChunks
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw StreamIngestAppRuntimeRunnerError.livePollTimedOut(
                    seconds: Double(timeoutNanoseconds) / 1_000_000_000
                )
            }

            guard let result = try await group.next() else {
                group.cancelAll()
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
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
