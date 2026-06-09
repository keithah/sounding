import Foundation

#if canImport(AVFoundation)
    import AVFoundation
#endif

public final class AVFoundationAppPCMPlayerAdapter: AppPCMPlaybackAdapting, @unchecked Sendable {
    #if canImport(AVFoundation)
        private let engine = AVAudioEngine()
        private let playerNode = AVAudioPlayerNode()
        private let volumeMixerNode = AVAudioMixerNode()
        private var didAttachPlayerNode = false
        private let engineStarter: (@Sendable () throws -> Void)?
        private let bufferScheduler: (@Sendable ([AVAudioPCMBuffer]) throws -> Void)?
        private let playerStarter: (@Sendable () -> Void)?
        private let engineStopper: (@Sendable () -> Void)?
        private let volumeStore: AppPlaybackVolumeStore
        private let diagnosticsLog: AppRuntimeDiagnosticsLog
        private let bufferFactory = AVFoundationPCMBufferFactory()
        private let playerQueue = DispatchQueue(label: "Sounding.AVFoundationAppPCMPlayerAdapter")
        private let currentStreamLock = NSLock()
        private var currentStreamID: Int64?
        private let scheduledBuffersLock = NSLock()
        private var scheduledBuffers: [AVAudioPCMBuffer] = []
        private var scheduledBufferDurations: [ObjectIdentifier: Double] = [:]
        private var volumeObserverTask: Task<Void, Never>?
    #endif

    public init(
        volumeStore: AppPlaybackVolumeStore = AppPlaybackVolumeStore(),
        diagnosticsLog: AppRuntimeDiagnosticsLog = AppRuntimeDiagnosticsLog()
    ) {
        #if canImport(AVFoundation)
            self.engineStarter = nil
            self.bufferScheduler = nil
            self.playerStarter = nil
            self.engineStopper = nil
            self.volumeStore = volumeStore
            self.diagnosticsLog = diagnosticsLog
            startVolumeObservation()
        #endif
    }

    public static func verificationAdapter(
        volumeStore: AppPlaybackVolumeStore = AppPlaybackVolumeStore(),
        diagnosticsLog: AppRuntimeDiagnosticsLog = AppRuntimeDiagnosticsLog()
    ) -> AVFoundationAppPCMPlayerAdapter {
        #if canImport(AVFoundation)
            AVFoundationAppPCMPlayerAdapter(
                engineStarter: {},
                bufferScheduler: { _ in },
                playerStarter: {},
                engineStopper: {},
                volumeStore: volumeStore,
                diagnosticsLog: diagnosticsLog
            )
        #else
            AVFoundationAppPCMPlayerAdapter(
                volumeStore: volumeStore,
                diagnosticsLog: diagnosticsLog
            )
        #endif
    }

    #if canImport(AVFoundation)
        init(
            engineStarter: (@Sendable () throws -> Void)?,
            bufferScheduler: (@Sendable ([AVAudioPCMBuffer]) throws -> Void)?,
            playerStarter: (@Sendable () -> Void)? = nil,
            engineStopper: (@Sendable () -> Void)? = nil,
            volumeStore: AppPlaybackVolumeStore = AppPlaybackVolumeStore(),
            diagnosticsLog: AppRuntimeDiagnosticsLog = AppRuntimeDiagnosticsLog()
        ) {
            self.engineStarter = engineStarter
            self.bufferScheduler = bufferScheduler
            self.playerStarter = playerStarter
            self.engineStopper = engineStopper
            self.volumeStore = volumeStore
            self.diagnosticsLog = diagnosticsLog
            startVolumeObservation()
        }
    #endif

    public func prepare(
        streamID: Int64, sourceDescription: String, timeline: AppPlayerTimelineClock
    ) async throws {
        #if canImport(AVFoundation)
            diagnosticsLog.recordEvent(
                "playback.prepare.requested",
                streamID: streamID,
                sourceDescription: sourceDescription,
                phase: "playback.prepare",
                fields: ["engineRunning": String(engine.isRunning)]
            )
            let volumeSnapshot = await volumeStore.snapshot(streamID: streamID)
            do {
                try await runOnPlayerQueue {
                    self.setCurrentStreamID(streamID)
                    self.playerNode.stop()
                    self.clearScheduledBuffers()
                    self.applyEffectiveVolume(volumeSnapshot.effectiveVolume)
                    self.recordVolumeApplied(
                        streamID: streamID,
                        snapshot: volumeSnapshot,
                        source: "prepare"
                    )
                    self.diagnosticsLog.recordEvent(
                        "playback.queue.flushed",
                        streamID: streamID,
                        sourceDescription: sourceDescription,
                        phase: "playback.prepare",
                        fields: ["reason": "prepare"]
                    )
                    try self.startAudioEngineIfNeeded()
                    self.diagnosticsLog.recordEvent(
                        "playback.prepare.succeeded",
                        streamID: streamID,
                        sourceDescription: sourceDescription,
                        phase: "playback.prepare",
                        fields: ["engineRunning": String(self.engine.isRunning)]
                    )
                }
            } catch {
                await publishFailure(
                    "Audio device unavailable: \(error).",
                    timeline: timeline
                )
                throw AppPlayerAdapterError.audioDeviceUnavailable(
                    "Audio device unavailable: \(error).")
            }
        #endif
        await timeline.reset(
            streamID: streamID, message: "Prepared playback for \(sourceDescription).")
    }

    public func play(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock) async throws {
        try await play(frames, timeline: timeline, replacingScheduledBuffers: false)
    }

    public func playReplacingScheduledBuffers(
        _ frames: [SharedPCMFrame],
        timeline: AppPlayerTimelineClock
    ) async throws {
        try await play(frames, timeline: timeline, replacingScheduledBuffers: true)
    }

    private func play(
        _ frames: [SharedPCMFrame],
        timeline: AppPlayerTimelineClock,
        replacingScheduledBuffers: Bool
    ) async throws {
        guard !frames.isEmpty else { return }

        do {
            #if canImport(AVFoundation)
                let streamID = frames.first?.streamID
                diagnosticsLog.recordEvent(
                    "playback.play.requested",
                    streamID: streamID,
                    phase: "playback.play",
                    fields: [
                        "frameCount": String(frames.count),
                        "byteCount": String(frames.reduce(0) { $0 + $1.byteCount }),
                        "payloadKinds": Array(Set(frames.map { $0.format.payloadKind.rawValue })).sorted().joined(separator: ","),
                    ]
                )
                let volumeSnapshot: AppPlaybackVolumeSnapshot?
                if let streamID {
                    volumeSnapshot = await volumeStore.snapshot(streamID: streamID)
                } else {
                    volumeSnapshot = nil
                }
                try await runOnPlayerQueue {
                    if let streamID {
                        self.setCurrentStreamID(streamID)
                    }
                    if let streamID, let volumeSnapshot {
                        self.applyEffectiveVolume(volumeSnapshot.effectiveVolume)
                        self.recordVolumeApplied(
                            streamID: streamID,
                            snapshot: volumeSnapshot,
                            source: "play"
                        )
                    }
                    if replacingScheduledBuffers {
                        self.playerNode.stop()
                        self.clearScheduledBuffers()
                        self.diagnosticsLog.recordEvent(
                            "playback.queue.flushed",
                            streamID: streamID,
                            phase: "playback.seek",
                            fields: ["reason": "seek"]
                        )
                    }
                    let frameDurations = frames.map { max(0, $0.endSeconds - $0.startSeconds) }
                    let buffers = try frames.map(self.bufferFactory.makePCMBuffer)
                    try self.startAudioEngineIfNeeded()
                    if self.bufferScheduler != nil {
                        try self.schedule(
                            buffers,
                            durations: frameDurations,
                            timeline: timeline,
                            streamID: streamID
                        )
                    } else {
                        let outputFormat = self.engine.outputNode.inputFormat(forBus: 0)
                        let playbackBuffers = try buffers.map {
                            try self.bufferFactory.convert($0, to: outputFormat)
                        }
                        self.diagnosticsLog.recordEvent(
                            "playback.buffers.converted",
                            streamID: streamID,
                            phase: "playback.play",
                            fields: [
                                "sourceBufferCount": String(buffers.count),
                                "playbackBufferCount": String(playbackBuffers.count),
                                "outputSampleRate": String(outputFormat.sampleRate),
                                "outputChannels": String(outputFormat.channelCount),
                            ]
                        )
                        try self.schedule(
                            playbackBuffers,
                            durations: frameDurations,
                            timeline: timeline,
                            streamID: streamID
                        )
                    }
                    self.startPlayerNodeIfNeeded()
                    let scheduledSnapshot = self.scheduledBufferSnapshot()
                    self.diagnosticsLog.recordEvent(
                        "playback.play.scheduled",
                        streamID: streamID,
                        phase: "playback.play",
                        fields: [
                            "engineRunning": String(self.engine.isRunning),
                            "playerIsPlaying": String(self.playerNode.isPlaying),
                            "retainedBufferCount": String(scheduledSnapshot.count),
                            "retainedBufferSeconds": String(
                                format: "%.3f", scheduledSnapshot.seconds),
                        ]
                    )
                }
            #else
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "AVFoundation playback is unavailable on this platform.")
            #endif
        } catch let error as AppPlayerAdapterError {
            clearScheduledBuffersIfAvailable()
            let redactedError = error.redacted
            await publishFailure(redactedError.description, timeline: timeline)
            throw redactedError
        } catch {
            clearScheduledBuffersIfAvailable()
            let failure = AppPlayerAdapterError.schedulingFailed(
                "Player scheduling failed: \(error).")
            await publishFailure(failure.description, timeline: timeline)
            throw failure
        }

        await timeline.recordDecodedFrames(frames)
        if let last = frames.max(by: { $0.endSeconds < $1.endSeconds }) {
            await timeline.updatePlayerState(
                .playing,
                positionSeconds: last.startSeconds,
                message: "Playing shared PCM frame \(last.sequence)."
            )
        }
    }

    public func pause(timeline: AppPlayerTimelineClock) async {
        #if canImport(AVFoundation)
            await runOnPlayerQueue {
                self.playerNode.pause()
                self.diagnosticsLog.recordEvent(
                    "playback.pause.applied",
                    streamID: self.currentStreamIDValue(),
                    phase: "playback.pause",
                    fields: ["playerIsPlaying": String(self.playerNode.isPlaying)]
                )
            }
        #endif
        await timeline.updatePlayerState(.paused, message: "Playback paused.")
    }

    public func resume(timeline: AppPlayerTimelineClock) async {
        #if canImport(AVFoundation)
            await runOnPlayerQueue {
                self.startPlayerNodeIfNeeded()
                self.diagnosticsLog.recordEvent(
                    "playback.resume.applied",
                    streamID: self.currentStreamIDValue(),
                    phase: "playback.resume",
                    fields: ["playerIsPlaying": String(self.playerNode.isPlaying)]
                )
            }
        #endif
        await timeline.updatePlayerState(.playing, message: "Playback resumed.")
    }

    public func stop(timeline: AppPlayerTimelineClock) async {
        #if canImport(AVFoundation)
            await runOnPlayerQueue {
                let streamID = self.currentStreamIDValue()
                let retainedBeforeStop = self.scheduledBufferSnapshot()
                self.playerNode.stop()
                self.clearScheduledBuffers()
                self.setCurrentStreamID(nil)
                self.engineStopper?()
                self.diagnosticsLog.recordEvent(
                    "playback.stop.applied",
                    streamID: streamID,
                    phase: "playback.stop",
                    fields: [
                        "retainedBuffersBeforeStop": String(retainedBeforeStop.count),
                        "retainedBufferSecondsBeforeStop": String(
                            format: "%.3f", retainedBeforeStop.seconds),
                        "engineRunning": String(self.engine.isRunning),
                        "playerIsPlaying": String(self.playerNode.isPlaying),
                    ]
                )
            }
        #endif
        await timeline.updatePlayerState(.stopped, message: "Playback stopped.")
    }

    public func applyPlaybackVolume(streamID: Int64) async {
        #if canImport(AVFoundation)
            let snapshot = await volumeStore.snapshot(streamID: streamID)
            await runOnPlayerQueue {
                guard self.currentStreamIDValue() == streamID else {
                    self.diagnosticsLog.recordEvent(
                        "playback.volume.skipped",
                        streamID: streamID,
                        phase: "playback.volume",
                        fields: [
                            "currentStreamID": self.currentStreamIDValue().map(String.init) ?? "nil",
                            "source": "control",
                        ]
                    )
                    return
                }
                self.applyEffectiveVolume(snapshot.effectiveVolume)
                self.recordVolumeApplied(streamID: streamID, snapshot: snapshot, source: "control")
            }
        #endif
    }

    private func publishFailure(_ message: String, timeline: AppPlayerTimelineClock) async {
        await timeline.updatePlayerState(
            .failed(message: message),
            message: message
        )
    }

    private func clearScheduledBuffersIfAvailable() {
        #if canImport(AVFoundation)
            clearScheduledBuffers()
        #endif
    }

    #if canImport(AVFoundation)
        private func startAudioEngineIfNeeded() throws {
            if let engineStarter {
                try engineStarter()
                return
            }
            if !didAttachPlayerNode {
                engine.attach(playerNode)
                engine.attach(volumeMixerNode)
                let outputFormat = engine.outputNode.inputFormat(forBus: 0)
                engine.connect(playerNode, to: volumeMixerNode, format: outputFormat)
                engine.connect(volumeMixerNode, to: engine.outputNode, format: outputFormat)
                didAttachPlayerNode = true
            }
            if !engine.isRunning {
                try engine.start()
            }
        }

        private func schedule(
            _ buffers: [AVAudioPCMBuffer],
            durations: [Double],
            timeline: AppPlayerTimelineClock,
            streamID: Int64?
        ) throws {
            if let bufferScheduler {
                retainScheduledBuffers(buffers, durations: durations)
                do {
                    try bufferScheduler(buffers)
                } catch {
                    clearScheduledBuffers()
                    throw error
                }
                return
            }
            for (index, buffer) in buffers.enumerated() {
                retainScheduledBuffer(buffer, duration: scheduledDuration(at: index, in: durations))
                playerNode.scheduleBuffer(
                    buffer,
                    completionCallbackType: .dataRendered
                ) { [weak self, weak buffer, timeline] _ in
                    guard let buffer else { return }
                    guard let self else { return }
                    let remaining = self.releaseScheduledBuffer(buffer)
                    guard remaining.count == 0 else { return }
                    let currentStreamID = self.currentStreamIDValue()
                    guard currentStreamID == streamID else { return }
                    self.diagnosticsLog.recordEvent(
                        "playback.queue.drained",
                        streamID: currentStreamID,
                        phase: "playback.play",
                        fields: [
                            "engineRunning": String(self.engine.isRunning),
                            "playerIsPlaying": String(self.playerNode.isPlaying),
                            "retainedBufferSeconds": String(format: "%.3f", remaining.seconds),
                        ]
                    )
                    Task {
                        await timeline.updatePlayerState(
                            .buffering,
                            message: "Playback queue drained; waiting for fresh live audio."
                        )
                    }
                }
            }
        }

        private func startPlayerNodeIfNeeded() {
            if let playerStarter {
                playerStarter()
                return
            }
            if !playerNode.isPlaying {
                playerNode.play()
            }
        }

        private func startVolumeObservation() {
            volumeObserverTask = Task { [weak self, volumeStore] in
                let changes = await volumeStore.changes()
                for await snapshot in changes {
                    guard let self else { return }
                    await self.runOnPlayerQueue {
                        guard self.currentStreamIDValue() == snapshot.streamID else { return }
                        self.applyEffectiveVolume(snapshot.effectiveVolume)
                        self.recordVolumeApplied(
                            streamID: snapshot.streamID,
                            snapshot: snapshot,
                            source: "observer"
                        )
                    }
                }
            }
        }

        private func setCurrentStreamID(_ streamID: Int64?) {
            currentStreamLock.lock()
            currentStreamID = streamID
            currentStreamLock.unlock()
        }

        private func currentStreamIDValue() -> Int64? {
            currentStreamLock.lock()
            defer { currentStreamLock.unlock() }
            return currentStreamID
        }

        private func retainScheduledBuffers(_ buffers: [AVAudioPCMBuffer], durations: [Double]) {
            scheduledBuffersLock.lock()
            scheduledBuffers.append(contentsOf: buffers)
            for (index, buffer) in buffers.enumerated() {
                scheduledBufferDurations[ObjectIdentifier(buffer)] = max(
                    0,
                    scheduledDuration(at: index, in: durations)
                )
            }
            scheduledBuffersLock.unlock()
        }

        private func retainScheduledBuffer(_ buffer: AVAudioPCMBuffer, duration: Double) {
            scheduledBuffersLock.lock()
            scheduledBuffers.append(buffer)
            scheduledBufferDurations[ObjectIdentifier(buffer)] = max(0, duration)
            scheduledBuffersLock.unlock()
        }

        private func releaseScheduledBuffer(_ buffer: AVAudioPCMBuffer) -> (
            count: Int, seconds: Double
        ) {
            scheduledBuffersLock.lock()
            if let index = scheduledBuffers.firstIndex(where: { $0 === buffer }) {
                scheduledBuffers.remove(at: index)
            }
            scheduledBufferDurations.removeValue(forKey: ObjectIdentifier(buffer))
            let remaining = scheduledBuffers.count
            let seconds = scheduledBufferDurations.values.reduce(0, +)
            scheduledBuffersLock.unlock()
            return (remaining, seconds)
        }

        private func clearScheduledBuffers() {
            scheduledBuffersLock.lock()
            scheduledBuffers.removeAll(keepingCapacity: false)
            scheduledBufferDurations.removeAll(keepingCapacity: false)
            scheduledBuffersLock.unlock()
        }

        private func scheduledBufferSnapshot() -> (count: Int, seconds: Double) {
            scheduledBuffersLock.lock()
            defer { scheduledBuffersLock.unlock() }
            return (scheduledBuffers.count, scheduledBufferDurations.values.reduce(0, +))
        }

        private func scheduledDuration(at index: Int, in durations: [Double]) -> Double {
            guard durations.indices.contains(index) else { return 0 }
            return durations[index]
        }

        private func recordVolumeApplied(
            streamID: Int64,
            snapshot: AppPlaybackVolumeSnapshot,
            source: String
        ) {
            diagnosticsLog.recordEvent(
                "playback.volume.applied",
                streamID: streamID,
                phase: "playback.volume",
                fields: [
                    "volume": String(format: "%.3f", snapshot.volume),
                    "isMuted": String(snapshot.isMuted),
                    "effectiveVolume": String(format: "%.3f", snapshot.effectiveVolume),
                    "source": source,
                ]
            )
        }

        private func applyEffectiveVolume(_ effectiveVolume: Float) {
            playerNode.volume = 1
            volumeMixerNode.outputVolume = effectiveVolume
        }

        private func runOnPlayerQueue(_ operation: @escaping () -> Void) async {
            await withCheckedContinuation { continuation in
                playerQueue.async {
                    operation()
                    continuation.resume()
                }
            }
        }

        private func runOnPlayerQueue<T>(_ operation: @escaping () throws -> T) async throws -> T {
            try await withCheckedThrowingContinuation { continuation in
                playerQueue.async {
                    do {
                        continuation.resume(returning: try operation())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        var nodeVolumeSnapshotForTesting: (player: Float, mixer: Float) {
            (playerNode.volume, volumeMixerNode.outputVolume)
        }

    #endif
}
