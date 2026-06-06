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
        private let currentStreamLock = NSLock()
        private var currentStreamID: Int64?
        private let scheduledBuffersLock = NSLock()
        private var scheduledBuffers: [AVAudioPCMBuffer] = []
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
            setCurrentStreamID(streamID)
            diagnosticsLog.recordEvent(
                "playback.prepare.requested",
                streamID: streamID,
                sourceDescription: sourceDescription,
                phase: "playback.prepare",
                fields: ["engineRunning": String(engine.isRunning)]
            )
            // Do NOT call playerNode.stop() here. The runtime's replacePlaybackOwner
            // already invokes player.stop() on the previous owner before this prepare.
            // A second concurrent playerNode.stop() races with the first one inside
            // AVFoundation and the calling task blocks indefinitely.
            clearScheduledBuffers()
            await applyVolume(streamID: streamID)
            do {
                try startAudioEngineIfNeeded()
                diagnosticsLog.recordEvent(
                    "playback.prepare.succeeded",
                    streamID: streamID,
                    sourceDescription: sourceDescription,
                    phase: "playback.prepare",
                    fields: ["engineRunning": String(engine.isRunning)]
                )
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
                if let streamID {
                    setCurrentStreamID(streamID)
                    await applyVolume(streamID: streamID)
                }
                if replacingScheduledBuffers {
                    playerNode.reset()
                    clearScheduledBuffers()
                    diagnosticsLog.recordEvent(
                        "playback.queue.flushed",
                        streamID: streamID,
                        phase: "playback.seek",
                        fields: ["reason": "seek"]
                    )
                }
                let buffers = try frames.map(bufferFactory.makePCMBuffer)
                try startAudioEngineIfNeeded()
                if bufferScheduler != nil {
                    try schedule(buffers, timeline: timeline, streamID: streamID)
                } else {
                    let outputFormat = engine.outputNode.inputFormat(forBus: 0)
                    let playbackBuffers = try buffers.map { try bufferFactory.convert($0, to: outputFormat) }
                    diagnosticsLog.recordEvent(
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
                    try schedule(playbackBuffers, timeline: timeline, streamID: streamID)
                }
                startPlayerNodeIfNeeded()
                diagnosticsLog.recordEvent(
                    "playback.play.scheduled",
                    streamID: streamID,
                    phase: "playback.play",
                    fields: [
                        "engineRunning": String(engine.isRunning),
                        "playerIsPlaying": String(playerNode.isPlaying),
                        "retainedBufferCount": String(scheduledBufferCount()),
                    ]
                )
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
            playerNode.pause()
            diagnosticsLog.recordEvent(
                "playback.pause.applied",
                streamID: currentStreamIDValue(),
                phase: "playback.pause",
                fields: ["playerIsPlaying": String(playerNode.isPlaying)]
            )
        #endif
        await timeline.updatePlayerState(.paused, message: "Playback paused.")
    }

    public func resume(timeline: AppPlayerTimelineClock) async {
        #if canImport(AVFoundation)
            startPlayerNodeIfNeeded()
            diagnosticsLog.recordEvent(
                "playback.resume.applied",
                streamID: currentStreamIDValue(),
                phase: "playback.resume",
                fields: ["playerIsPlaying": String(playerNode.isPlaying)]
            )
        #endif
        await timeline.updatePlayerState(.playing, message: "Playback resumed.")
    }

    public func stop(timeline: AppPlayerTimelineClock) async {
        #if canImport(AVFoundation)
            let streamID = currentStreamIDValue()
            let retainedBeforeStop = scheduledBufferCount()
            // Don't call playerNode.stop() — it blocks for seconds with a long
            // queue and causes the runtime stop-coordinator to time out, with
            // racing scheduleBuffer calls from the next stream. Use
            // playerNode.reset() instead: documented as "clears any previously
            // scheduled events" and runs without blocking. The player node stays
            // attached to the running engine; the next play() call schedules new
            // buffers from a clean queue and resumes playback via play().
            playerNode.reset()
            clearScheduledBuffers()
            setCurrentStreamID(nil)
            engineStopper?()
            diagnosticsLog.recordEvent(
                "playback.stop.applied",
                streamID: streamID,
                phase: "playback.stop",
                fields: [
                    "retainedBuffersBeforeStop": String(retainedBeforeStop),
                    "engineRunning": String(engine.isRunning),
                    "playerIsPlaying": String(playerNode.isPlaying),
                ]
            )
        #endif
        await timeline.updatePlayerState(.stopped, message: "Playback stopped.")
    }

    public func applyPlaybackVolume(streamID: Int64) async {
        #if canImport(AVFoundation)
            setCurrentStreamID(streamID)
            await applyVolume(streamID: streamID, source: "control")
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
            timeline: AppPlayerTimelineClock,
            streamID: Int64?
        ) throws {
            if let bufferScheduler {
                retainScheduledBuffers(buffers)
                do {
                    try bufferScheduler(buffers)
                } catch {
                    clearScheduledBuffers()
                    throw error
                }
                return
            }
            for buffer in buffers {
                retainScheduledBuffer(buffer)
                playerNode.scheduleBuffer(
                    buffer,
                    completionCallbackType: .dataRendered
                ) { [weak self, weak buffer, timeline] _ in
                    guard let buffer else { return }
                    guard let self else { return }
                    let remaining = self.releaseScheduledBuffer(buffer)
                    guard remaining == 0 else { return }
                    let currentStreamID = self.currentStreamIDValue()
                    guard currentStreamID == streamID else { return }
                    self.diagnosticsLog.recordEvent(
                        "playback.queue.drained",
                        streamID: currentStreamID,
                        phase: "playback.play",
                        fields: [
                            "engineRunning": String(self.engine.isRunning),
                            "playerIsPlaying": String(self.playerNode.isPlaying),
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
                    if self.currentStreamIDValue() == snapshot.streamID {
                        self.applyEffectiveVolume(snapshot.effectiveVolume)
                        self.diagnosticsLog.recordEvent(
                            "playback.volume.applied",
                            streamID: snapshot.streamID,
                            phase: "playback.volume",
                            fields: [
                                "volume": String(format: "%.3f", snapshot.volume),
                                "isMuted": String(snapshot.isMuted),
                                "effectiveVolume": String(format: "%.3f", snapshot.effectiveVolume),
                                "source": "observer",
                            ]
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

        private func retainScheduledBuffers(_ buffers: [AVAudioPCMBuffer]) {
            scheduledBuffersLock.lock()
            scheduledBuffers.append(contentsOf: buffers)
            scheduledBuffersLock.unlock()
        }

        private func retainScheduledBuffer(_ buffer: AVAudioPCMBuffer) {
            scheduledBuffersLock.lock()
            scheduledBuffers.append(buffer)
            scheduledBuffersLock.unlock()
        }

        private func releaseScheduledBuffer(_ buffer: AVAudioPCMBuffer) -> Int {
            scheduledBuffersLock.lock()
            if let index = scheduledBuffers.firstIndex(where: { $0 === buffer }) {
                scheduledBuffers.remove(at: index)
            }
            let remaining = scheduledBuffers.count
            scheduledBuffersLock.unlock()
            return remaining
        }

        private func clearScheduledBuffers() {
            scheduledBuffersLock.lock()
            scheduledBuffers.removeAll(keepingCapacity: false)
            scheduledBuffersLock.unlock()
        }

        private func scheduledBufferCount() -> Int {
            scheduledBuffersLock.lock()
            defer { scheduledBuffersLock.unlock() }
            return scheduledBuffers.count
        }

        private func applyVolume(streamID: Int64, source: String = "direct") async {
            let snapshot = await volumeStore.snapshot(streamID: streamID)
            applyEffectiveVolume(snapshot.effectiveVolume)
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

        var nodeVolumeSnapshotForTesting: (player: Float, mixer: Float) {
            (playerNode.volume, volumeMixerNode.outputVolume)
        }

    #endif
}
