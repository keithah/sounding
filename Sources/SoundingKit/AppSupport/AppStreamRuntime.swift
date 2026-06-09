import Foundation

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
    private let statusStore: AppStreamRuntimeStatusStore?
    private let playbackController: (any AppPCMPlaybackAdapting)?
    private let playbackCommands: AppStreamPlaybackCommands
    private let playbackSelection: AppPlaybackStreamSelection?
    private let diagnosticsLog: AppRuntimeDiagnosticsLog
    private let playbackStopTimeoutNanoseconds: UInt64
    private let now: @Sendable () -> Date
    private let timestampFormatter: ISO8601DateFormatter

    private var streamRuns: [Int64: StreamRunState] = [:]
    private var pendingStartTokens: [Int64: UUID] = [:]
    private var suspendedStreams: [Int64: Date] = [:]
    private var currentStreamID: Int64?
    private var suspendedPlaybackOwnerStreamID: Int64?
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
        audioArchiveStore: AudioArchiveStore? = nil,
        playbackController: (any AppPCMPlaybackAdapting)? = nil,
        playbackSelection: AppPlaybackStreamSelection? = nil,
        diagnosticsLog: AppRuntimeDiagnosticsLog = AppRuntimeDiagnosticsLog(),
        playbackStopTimeoutNanoseconds: UInt64 = 2_000_000_000,
        now: @escaping @Sendable () -> Date = { Date() },
        retrySleep: @escaping @Sendable (Int) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds)) * 1_000_000_000)
        }
    ) {
        self.registry = registry
        self.ingester = ingester
        self.retryPolicy = retryPolicy
        self.statusStore = statusStore
        self.playbackTimeline = playbackTimeline
        self.playbackController = playbackController
        self.playbackSelection = playbackSelection
        self.playbackCommands = AppStreamPlaybackCommands(
            volumeStore: volumeStore,
            playbackTimeline: playbackTimeline,
            rollingBuffer: rollingBuffer,
            audioArchiveStore: audioArchiveStore,
            playbackController: playbackController,
            diagnosticsLog: diagnosticsLog
        )
        self.diagnosticsLog = diagnosticsLog
        self.playbackStopTimeoutNanoseconds = playbackStopTimeoutNanoseconds
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
        await stop(streamID: streamID, clearsPendingStart: false, stopsPlayback: true)
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
        await replacePlaybackOwner(with: streamID, phase: "runtime.start")
        try beginRun(streamID: streamID, connectionMessagePrefix: "Connecting")
    }

    public func restart(streamID: Int64) async throws {
        diagnosticsLog.recordEvent(
            "runtime.restart.requested",
            streamID: streamID,
            phase: "runtime.restart",
            fields: ["existingRunCount": String(streamRuns.count)]
        )
        suspendedStreams[streamID] = nil
        let startToken = UUID()
        pendingStartTokens[streamID] = startToken
        await stop(streamID: streamID, clearsPendingStart: false, stopsPlayback: true)
        guard pendingStartTokens[streamID] == startToken else {
            diagnosticsLog.recordEvent(
                "runtime.restart.superseded",
                streamID: streamID,
                phase: "runtime.restart",
                fields: ["existingRunCount": String(streamRuns.count)]
            )
            return
        }
        pendingStartTokens[streamID] = nil
        await replacePlaybackOwner(with: streamID, phase: "runtime.restart")
        try beginRun(streamID: streamID, connectionMessagePrefix: "Restarting")
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
        guard let streamType = reconnect.resolvedStreamType,
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
            isDiarizationEnabled: reconnect.diarizationEnabled,
            isAudioArchiveEnabled: reconnect.audioArchiveEnabled,
            transcriptionPolicy: reconnect.transcriptionPolicy
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

        let supervisor = AppStreamRunSupervisor(
            request: request,
            token: token,
            ingester: ingester,
            retryPolicy: retryPolicy,
            retrySleep: retrySleep,
            recoveryEvidence: recoveryEvidence,
            recoveredLifecycleEvidence: { [weak self] evidence in
                await self?.recoveredLifecycleEvidence(from: evidence)
            },
            publishIfCurrent: { [weak self] streamID, token, event, attempt, nextRetrySeconds, failureMessage in
                await self?.publishIfCurrent(
                    streamID: streamID,
                    token: token,
                    event,
                    attempt: attempt,
                    nextRetrySeconds: nextRetrySeconds,
                    failureMessage: failureMessage
                )
            },
            finishIfCurrent: { [weak self] streamID, token, event, attempt, failureMessage in
                await self?.finishIfCurrent(
                    streamID: streamID,
                    token: token,
                    event: event,
                    attempt: attempt,
                    failureMessage: failureMessage
                )
            }
        )
        let task = supervisor.makeTask()
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
        await stop(streamID: streamID, clearsPendingStart: true, stopsPlayback: true)
    }

    private func stop(
        streamID: Int64,
        clearsPendingStart: Bool,
        stopsPlayback: Bool
    ) async {
        diagnosticsLog.recordEvent(
            "runtime.stop.requested",
            streamID: streamID,
            phase: "runtime.stop",
            fields: [
                "hadRun": String(streamRuns[streamID] != nil),
                "stopsPlayback": String(stopsPlayback),
            ]
        )
        let state = streamRuns.removeValue(forKey: streamID)
        if clearsPendingStart {
            pendingStartTokens[streamID] = nil
        }
        guard state != nil || clearsPendingStart else { return }
        state?.task?.cancel()
        let stoppedToken = state?.token
        let streamOwnsPlayback = currentStreamID == streamID
        if streamOwnsPlayback {
            currentStreamID = nil
            await playbackSelection?.clear(ifStreamID: streamID)
        }
        if stopsPlayback, streamOwnsPlayback, let playbackController, let playbackTimeline {
            await stopPlaybackForRuntimeStop(
                playbackController,
                timeline: playbackTimeline,
                streamID: streamID
            )
        }
        // After the await above, a concurrent start() may have taken over and
        // installed a new run for this streamID (actor reentrancy). Don't
        // overwrite that state: only clear ownership and publish "Stopped" if
        // no replacement run has been created.
        let supersededByNewRun = streamRuns[streamID] != nil && streamRuns[streamID]?.token != stoppedToken
        if !supersededByNewRun {
            publish(
                AppStreamRuntimeEvent(
                    streamID: streamID,
                    phase: .stopped,
                    message: "Stopped stream \(streamID)."
                ),
                attempt: latestAttempt(streamID: streamID)
            )
            persistStoppedStatus(streamID: streamID)
        } else {
            diagnosticsLog.recordEvent(
                "runtime.stop.superseded",
                streamID: streamID,
                phase: "runtime.stop",
                fields: ["reason": "new run took over during stop"]
            )
        }
    }

    public func stopAll() async {
        let streamIDs = Array(streamRuns.keys)
        for streamID in streamIDs {
            await stop(streamID: streamID)
        }
    }

    private func stopPlaybackForRuntimeStop(
        _ playbackController: any AppPCMPlaybackAdapting,
        timeline: AppPlayerTimelineClock,
        streamID: Int64
    ) async {
        diagnosticsLog.recordEvent(
            "runtime.playback.stop.requested",
            streamID: streamID,
            phase: "runtime.stop"
        )
        let timeoutNanoseconds = playbackStopTimeoutNanoseconds
        let completed = await AppPlaybackStopCoordinator.stop(
            playbackController,
            timeline: timeline,
            timeoutNanoseconds: timeoutNanoseconds
        ) { [diagnosticsLog] in
            diagnosticsLog.recordEvent(
                "runtime.playback.stop.timed_out",
                streamID: streamID,
                phase: "runtime.stop",
                fields: ["timeoutNanoseconds": String(timeoutNanoseconds)]
            )
        }
        if completed {
            diagnosticsLog.recordEvent(
                "runtime.playback.stop.completed",
                streamID: streamID,
                phase: "runtime.stop"
            )
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
        suspendedPlaybackOwnerStreamID = currentStreamID
        if currentStreamID != nil, let playbackController, let playbackTimeline {
            await stopPlaybackForRuntimeStop(
                playbackController,
                timeline: playbackTimeline,
                streamID: currentStreamID ?? -1
            )
        }
        currentStreamID = nil
        await playbackSelection?.select(streamID: nil)
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
        var capturedByStreamID = suspendedStreams
        if let statusStore {
            do {
                for status in try statusStore.statuses()
                where shouldRecoverPersistedStatus(status) && streamRuns[status.streamID] == nil
                    && capturedByStreamID[status.streamID] == nil
                {
                    capturedByStreamID[status.streamID] =
                        status.lifecycleEvidence?.suspendedAt.flatMap(timestampFormatter.date(from:))
                        ?? recoveryStartedAt
                }
            } catch {
                diagnosticsLog.recordEvent(
                    "runtime.wake.statusFallback.failed",
                    phase: "runtime.recover",
                    fields: ["error": IngestRedaction.redact(String(describing: error))]
                )
            }
        }
        let captured = capturedByStreamID.sorted { $0.key < $1.key }
        guard !captured.isEmpty else { return }
        suspendedStreams.removeAll()
        let playbackOwnerToRecover = suspendedPlaybackOwnerStreamID
        suspendedPlaybackOwnerStreamID = nil
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
            await recoverStreamAfterWake(
                streamID: streamID,
                evidence: evidence,
                restoresPlaybackOwner: playbackOwnerToRecover == streamID
            )
        }
    }

    private func replacePlaybackOwner(with streamID: Int64, phase: String) async {
        if currentStreamID == streamID {
            await playbackSelection?.select(streamID: streamID)
            await preparePlaybackOwner(streamID: streamID, phase: phase)
            return
        }
        let previousStreamID = currentStreamID
        currentStreamID = streamID
        await playbackSelection?.select(streamID: streamID)
        if let previousStreamID {
            diagnosticsLog.recordEvent(
                "runtime.playback.owner.replaced",
                streamID: streamID,
                phase: phase,
                fields: ["previousStreamID": String(previousStreamID)]
            )
        }
        await preparePlaybackOwner(streamID: streamID, phase: phase)
    }

    private func preparePlaybackOwner(streamID: Int64, phase: String) async {
        guard let playbackController, let playbackTimeline else { return }
        guard let reconnect = try? registry.reconnectSource(id: streamID) else { return }
        do {
            try await playbackController.prepare(
                streamID: streamID,
                sourceDescription: reconnect.sourceDescription,
                timeline: playbackTimeline
            )
            diagnosticsLog.recordEvent(
                "runtime.playback.owner.prepared",
                streamID: streamID,
                streamName: reconnect.name,
                source: reconnect.source,
                sourceDescription: reconnect.sourceDescription,
                phase: phase
            )
        } catch {
            diagnosticsLog.recordFailure(
                streamID: streamID,
                name: reconnect.name,
                source: reconnect.source,
                sourceDescription: reconnect.sourceDescription,
                phase: phase,
                error: error,
                event: "runtime.playback.owner.prepare_failed"
            )
        }
    }

    private func recoverStreamAfterWake(
        streamID: Int64,
        evidence: AppStreamRuntimeLifecycleEvidence,
        restoresPlaybackOwner: Bool
    ) async {
        do {
            if restoresPlaybackOwner {
                await replacePlaybackOwner(with: streamID, phase: "runtime.recover")
            }
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

    private func shouldRecoverPersistedStatus(_ status: AppStreamRuntimeStatusSnapshot) -> Bool {
        switch status.phase {
        case .connecting, .running, .suspended, .recovering, .reconnecting:
            return true
        case .paused, .stopped, .error:
            return false
        }
    }

    public func setVolume(streamID: Int64, volume: Double) async {
        let percent = await playbackCommands.setVolume(streamID: streamID, volume: volume)
        if let existing = latestEvents[streamID] {
            publish(
                AppStreamRuntimeEvent(
                    streamID: streamID,
                    kind: .controlFeedback,
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
        // Mute-as-switch UX: only one stream is audible at a time. Unmuting a stream
        // that isn't the current playback owner makes it the owner and mutes the
        // siblings. Muting the current owner keeps playback ownership and only
        // lowers effective volume so rapid mute/unmute does not re-enter AV
        // prepare while live buffers are still arriving.
        if !isMuted {
            await playbackCommands.setMuted(streamID: streamID, isMuted: false)
            if currentStreamID == streamID {
                await playbackSelection?.select(streamID: streamID)
                diagnosticsLog.recordEvent(
                    "runtime.setMuted.unmute.owner_retained",
                    streamID: streamID,
                    phase: "runtime.setMuted.unmute"
                )
            } else {
                await replacePlaybackOwner(with: streamID, phase: "runtime.setMuted.unmute")
                let replayedLiveBuffer = await playbackCommands.seekToLive(
                    streamID: streamID,
                    replacingScheduledBuffers: false
                )
                diagnosticsLog.recordEvent(
                    replayedLiveBuffer ? "runtime.setMuted.unmute.live_buffer_replayed" : "runtime.setMuted.unmute.live_buffer_unavailable",
                    streamID: streamID,
                    phase: "runtime.setMuted.unmute"
                )
            }
            let siblings = streamRuns.keys.filter { $0 != streamID }.sorted()
            for siblingID in siblings {
                await playbackCommands.setMuted(streamID: siblingID, isMuted: true)
                if let existing = latestEvents[siblingID] {
                    publish(
                        AppStreamRuntimeEvent(
                            streamID: siblingID,
                            kind: .controlFeedback,
                            phase: existing.phase,
                            message: "Stream \(siblingID) muted.",
                            result: existing.result,
                            lifecycleEvidence: existing.lifecycleEvidence
                        ),
                        attempt: latestAttempt(streamID: siblingID)
                    )
                }
            }
        } else {
            await playbackCommands.setMuted(streamID: streamID, isMuted: true)
            if currentStreamID == streamID {
                diagnosticsLog.recordEvent(
                    "runtime.playback.owner.retained_muted",
                    streamID: streamID,
                    phase: "runtime.setMuted.mute",
                    fields: ["stopsPlayback": "false"]
                )
            }
        }
        if let existing = latestEvents[streamID] {
            publish(
                AppStreamRuntimeEvent(
                    streamID: streamID,
                    kind: .controlFeedback,
                    phase: existing.phase,
                    message: isMuted ? "Stream \(streamID) muted." : "Stream \(streamID) unmuted.",
                    result: existing.result,
                    lifecycleEvidence: existing.lifecycleEvidence
                ),
                attempt: latestAttempt(streamID: streamID)
            )
        }
    }

    public func seek(to seconds: Double, streamID: Int64) async {
        guard let playbackTimeline else { return }
        guard await playbackCommands.seek(to: seconds, streamID: streamID) else { return }
        await publishPlayerTimelineEvent(streamID: streamID, playbackTimeline: playbackTimeline)
    }

    public func seekToLive(streamID: Int64) async {
        guard let playbackTimeline else { return }
        guard await playbackCommands.seekToLive(streamID: streamID) else { return }
        await publishPlayerTimelineEvent(streamID: streamID, playbackTimeline: playbackTimeline)
    }

    public func scrubBackward(seconds: Double, streamID: Int64) async {
        guard let playbackTimeline else { return }
        guard await playbackCommands.scrubBackward(seconds: seconds, streamID: streamID) else { return }
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
            kind: event.kind,
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
    ) async {
        guard streamRuns[streamID]?.token == token else { return }
        let eventToPublish = await eventWithCurrentPlayerTimelineForLifecycleIfNeeded(event)
        publish(
            eventToPublish,
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
    ) async {
        guard streamRuns[streamID]?.token == token else { return }
        streamRuns.removeValue(forKey: streamID)
        if currentStreamID == streamID {
            currentStreamID = nil
            await playbackSelection?.clear(ifStreamID: streamID)
        }
        let eventToPublish = await eventWithCurrentPlayerTimelineForLifecycleIfNeeded(event)
        publish(eventToPublish, attempt: attempt, failureMessage: failureMessage)
    }

    private func publishPlayerTimelineEvent(
        streamID: Int64,
        playbackTimeline: AppPlayerTimelineClock
    ) async {
        let snapshot = await playbackTimeline.snapshot()
        publish(
            AppStreamRuntimeEvent(
                streamID: streamID,
                kind: .playerTelemetry,
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

    private func eventWithCurrentPlayerTimelineForLifecycleIfNeeded(
        _ event: AppStreamRuntimeEvent
    ) async -> AppStreamRuntimeEvent {
        guard event.result?.playerTimeline == nil else { return event }
        guard event.phase.statusPhase != .running else { return event }
        return await eventWithCurrentPlayerTimeline(event)
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
