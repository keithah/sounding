import Foundation

#if canImport(AVFoundation)
    import AVFoundation
#endif

/// Format metadata for decoded audio shared by ingest and playback.
/// Existing decoders may not know the concrete PCM format yet, so the default
/// contract remains explicit about unknown format instead of inventing one.
public enum SharedPCMPayloadKind: String, Equatable, Sendable {
    case unknown
    case linearPCM
    case containerBytes
}

public struct SharedPCMFormat: Equatable, Sendable {
    public var sampleRate: Double?
    public var channelCount: Int?
    public var bitDepth: Int?
    public var payloadKind: SharedPCMPayloadKind
    public var isFloat: Bool
    public var isInterleaved: Bool
    public var isBigEndian: Bool

    public init(
        sampleRate: Double? = nil,
        channelCount: Int? = nil,
        bitDepth: Int? = nil,
        payloadKind: SharedPCMPayloadKind = .unknown,
        isFloat: Bool = false,
        isInterleaved: Bool = true,
        isBigEndian: Bool = false
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.payloadKind = payloadKind
        self.isFloat = isFloat
        self.isInterleaved = isInterleaved
        self.isBigEndian = isBigEndian
    }

    public static let unknown = SharedPCMFormat()
    public static let containerBytes = SharedPCMFormat(payloadKind: .containerBytes)

    public static func linearPCM(
        sampleRate: Double,
        channelCount: Int,
        bitDepth: Int = 16,
        isFloat: Bool = false,
        isInterleaved: Bool = true,
        isBigEndian: Bool = false
    ) -> SharedPCMFormat {
        SharedPCMFormat(
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitDepth: bitDepth,
            payloadKind: .linearPCM,
            isFloat: isFloat,
            isInterleaved: isInterleaved,
            isBigEndian: isBigEndian
        )
    }

    public init(decodedAudioFormat: DecodedAudioFormat) {
        let kind: SharedPCMPayloadKind
        switch decodedAudioFormat.payloadKind {
        case .unknown:
            kind = .unknown
        case .linearPCM:
            kind = .linearPCM
        case .containerBytes:
            kind = .containerBytes
        }
        self.init(
            sampleRate: decodedAudioFormat.sampleRate,
            channelCount: decodedAudioFormat.channelCount,
            bitDepth: decodedAudioFormat.bitDepth,
            payloadKind: kind,
            isFloat: decodedAudioFormat.isFloat,
            isInterleaved: decodedAudioFormat.isInterleaved,
            isBigEndian: decodedAudioFormat.isBigEndian
        )
    }
}

/// One decoded audio range on the single SoundingKit timeline.
/// Playback adapters consume these values; they never receive live source URLs,
/// which keeps listening on the same decode path as ingest.
public struct SharedPCMFrame: Equatable, Sendable {
    public var streamID: Int64
    public var sequence: Int
    public var audio: Data
    public var byteCount: Int
    public var startSeconds: Double
    public var endSeconds: Double
    public var format: SharedPCMFormat
    public var hlsIdentity: HLSDecodedAudioChunkIdentity?

    public init(
        streamID: Int64,
        sequence: Int,
        audio: Data,
        byteCount: Int? = nil,
        startSeconds: Double,
        endSeconds: Double,
        format: SharedPCMFormat = .unknown,
        hlsIdentity: HLSDecodedAudioChunkIdentity? = nil
    ) {
        self.streamID = streamID
        self.sequence = sequence
        self.audio = audio
        self.byteCount = byteCount ?? audio.count
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.format = format
        self.hlsIdentity = hlsIdentity
    }

    public init(
        streamID: Int64, chunk: DecodedAudioChunk, format: SharedPCMFormat? = nil
    ) {
        self.init(
            streamID: streamID,
            sequence: chunk.sequence,
            audio: chunk.audio,
            byteCount: chunk.byteCount,
            startSeconds: chunk.startSeconds,
            endSeconds: chunk.endSeconds,
            format: format ?? SharedPCMFormat(decodedAudioFormat: chunk.audioFormat),
            hlsIdentity: chunk.hlsIdentity
        )
    }
}

public enum AppPlayerState: Equatable, Sendable {
    case idle
    case buffering
    case playing
    case paused
    case stopped
    case failed(message: String)

    public var title: String {
        switch self {
        case .idle: return "Idle"
        case .buffering: return "Buffering"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .failed: return "Playback error"
        }
    }
}

public struct AppPlayerTimelineSnapshot: Equatable, Sendable {
    public var streamID: Int64?
    public var state: AppPlayerState
    public var positionSeconds: Double
    public var liveEdgeSeconds: Double
    public var bufferedStartSeconds: Double?
    public var bufferedEndSeconds: Double?
    public var driftSeconds: Double
    public var decodedFrameCount: Int
    public var rollingBuffer: RollingBufferSnapshot?
    public var unavailableRangeMessage: String?
    public var lastMessage: String

    public init(
        streamID: Int64? = nil,
        state: AppPlayerState = .idle,
        positionSeconds: Double = 0,
        liveEdgeSeconds: Double = 0,
        bufferedStartSeconds: Double? = nil,
        bufferedEndSeconds: Double? = nil,
        driftSeconds: Double = 0,
        decodedFrameCount: Int = 0,
        rollingBuffer: RollingBufferSnapshot? = nil,
        unavailableRangeMessage: String? = nil,
        lastMessage: String = "Player idle."
    ) {
        self.streamID = streamID
        switch state {
        case .failed(let message):
            self.state = .failed(message: IngestRedaction.redact(message))
        case .idle, .buffering, .playing, .paused, .stopped:
            self.state = state
        }
        self.positionSeconds = positionSeconds
        self.liveEdgeSeconds = liveEdgeSeconds
        self.bufferedStartSeconds = bufferedStartSeconds
        self.bufferedEndSeconds = bufferedEndSeconds
        self.driftSeconds = driftSeconds
        self.decodedFrameCount = decodedFrameCount
        self.rollingBuffer = rollingBuffer
        self.unavailableRangeMessage = unavailableRangeMessage.map(IngestRedaction.redact)
        self.lastMessage = IngestRedaction.redact(lastMessage)
    }
}

/// Actor-owned single timeline shared by ingest and playback for one app stream.
public actor AppPlayerTimelineClock {
    private var current = AppPlayerTimelineSnapshot()

    public init() {}

    public func reset(streamID: Int64, message: String = "Player timeline reset.") {
        current = AppPlayerTimelineSnapshot(
            streamID: streamID, state: .buffering, lastMessage: message)
    }

    public func recordDecodedFrames(_ frames: [SharedPCMFrame]) {
        guard !frames.isEmpty else { return }
        let sorted = frames.sorted { $0.startSeconds < $1.startSeconds }
        let start = min(
            current.bufferedStartSeconds ?? sorted[0].startSeconds, sorted[0].startSeconds)
        let end = max(
            current.bufferedEndSeconds ?? sorted[0].endSeconds,
            sorted.map(\.endSeconds).max() ?? sorted[0].endSeconds)
        let position = max(current.positionSeconds, sorted[0].startSeconds)
        let liveEdge = max(current.liveEdgeSeconds, end)
        current = AppPlayerTimelineSnapshot(
            streamID: sorted[0].streamID,
            state: current.state == .idle || current.state == .stopped ? .buffering : current.state,
            positionSeconds: position,
            liveEdgeSeconds: liveEdge,
            bufferedStartSeconds: start,
            bufferedEndSeconds: end,
            driftSeconds: liveEdge - position,
            decodedFrameCount: current.decodedFrameCount + frames.count,
            rollingBuffer: current.rollingBuffer,
            unavailableRangeMessage: current.unavailableRangeMessage,
            lastMessage: "Decoded \(frames.count) shared PCM frame(s)."
        )
    }

    public func updatePlayerState(
        _ state: AppPlayerState, positionSeconds: Double? = nil, message: String
    ) {
        let position = positionSeconds ?? current.positionSeconds
        current = AppPlayerTimelineSnapshot(
            streamID: current.streamID,
            state: state,
            positionSeconds: position,
            liveEdgeSeconds: current.liveEdgeSeconds,
            bufferedStartSeconds: current.bufferedStartSeconds,
            bufferedEndSeconds: current.bufferedEndSeconds,
            driftSeconds: current.liveEdgeSeconds - position,
            decodedFrameCount: current.decodedFrameCount,
            rollingBuffer: current.rollingBuffer,
            unavailableRangeMessage: current.unavailableRangeMessage,
            lastMessage: message
        )
    }

    public func updateRollingBuffer(_ snapshot: RollingBufferSnapshot) {
        let range = snapshot.bufferedRange
        current = AppPlayerTimelineSnapshot(
            streamID: current.streamID ?? snapshot.streamID,
            state: current.state,
            positionSeconds: current.positionSeconds,
            liveEdgeSeconds: max(current.liveEdgeSeconds, snapshot.liveEdgeSeconds),
            bufferedStartSeconds: range?.startSeconds ?? current.bufferedStartSeconds,
            bufferedEndSeconds: range?.endSeconds ?? current.bufferedEndSeconds,
            driftSeconds: max(current.liveEdgeSeconds, snapshot.liveEdgeSeconds)
                - current.positionSeconds,
            decodedFrameCount: current.decodedFrameCount,
            rollingBuffer: snapshot,
            unavailableRangeMessage: nil,
            lastMessage: snapshot.lastMessage
        )
    }

    public func applySeekResult(_ result: RollingBufferSeekResult) {
        switch result {
        case .available(let frame):
            current = AppPlayerTimelineSnapshot(
                streamID: frame.streamID,
                state: .playing,
                positionSeconds: frame.startSeconds,
                liveEdgeSeconds: max(current.liveEdgeSeconds, frame.endSeconds),
                bufferedStartSeconds: current.rollingBuffer?.bufferedRange?.startSeconds
                    ?? current.bufferedStartSeconds,
                bufferedEndSeconds: current.rollingBuffer?.bufferedRange?.endSeconds
                    ?? current.bufferedEndSeconds,
                driftSeconds: max(current.liveEdgeSeconds, frame.endSeconds) - frame.startSeconds,
                decodedFrameCount: current.decodedFrameCount,
                rollingBuffer: current.rollingBuffer,
                unavailableRangeMessage: nil,
                lastMessage: "Playback seeked to buffered frame \(frame.sequence)."
            )
        case .unavailable(let requestedSeconds, let range):
            let rangeDescription: String
            if let range {
                rangeDescription = "available range \(range.startSeconds)-\(range.endSeconds)s"
            } else {
                rangeDescription = "no buffered audio available"
            }
            let message = "Requested \(requestedSeconds)s is unavailable (\(rangeDescription))."
            current = AppPlayerTimelineSnapshot(
                streamID: current.streamID,
                state: current.state,
                positionSeconds: current.positionSeconds,
                liveEdgeSeconds: current.liveEdgeSeconds,
                bufferedStartSeconds: range?.startSeconds ?? current.bufferedStartSeconds,
                bufferedEndSeconds: range?.endSeconds ?? current.bufferedEndSeconds,
                driftSeconds: current.driftSeconds,
                decodedFrameCount: current.decodedFrameCount,
                rollingBuffer: current.rollingBuffer,
                unavailableRangeMessage: message,
                lastMessage: message
            )
        }
    }

    public func snapshot() -> AppPlayerTimelineSnapshot { current }
}

public struct AppPlaybackVolumeSnapshot: Equatable, Sendable {
    public var streamID: Int64
    public var volume: Double
    public var isMuted: Bool

    public init(streamID: Int64, volume: Double = 1.0, isMuted: Bool = false) {
        self.streamID = streamID
        self.volume = min(max(volume, 0), 1)
        self.isMuted = isMuted
    }

    public var effectiveVolume: Float {
        isMuted ? 0 : Float(volume)
    }

    public var displayPercent: Int {
        Int((volume * 100).rounded())
    }
}

public actor AppPlaybackVolumeStore {
    private var snapshots: [Int64: AppPlaybackVolumeSnapshot] = [:]
    private var continuations: [UUID: AsyncStream<AppPlaybackVolumeSnapshot>.Continuation] = [:]

    public init() {}

    public func snapshot(streamID: Int64) -> AppPlaybackVolumeSnapshot {
        snapshots[streamID] ?? AppPlaybackVolumeSnapshot(streamID: streamID)
    }

    public func setVolume(streamID: Int64, volume: Double) {
        var snapshot = snapshots[streamID] ?? AppPlaybackVolumeSnapshot(streamID: streamID)
        snapshot.volume = min(max(volume, 0), 1)
        snapshots[streamID] = snapshot
        publish(snapshot)
    }

    public func setMuted(streamID: Int64, isMuted: Bool) {
        var snapshot = snapshots[streamID] ?? AppPlaybackVolumeSnapshot(streamID: streamID)
        snapshot.isMuted = isMuted
        snapshots[streamID] = snapshot
        publish(snapshot)
    }

    public func changes() -> AsyncStream<AppPlaybackVolumeSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func publish(_ snapshot: AppPlaybackVolumeSnapshot) {
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}

public enum AppPlayerAdapterError: Error, Equatable, CustomStringConvertible, Sendable {
    case independentSourcePathRejected(String)
    case audioDeviceUnavailable(String)
    case decodeFailed(String)
    case unsupportedPCMFormat(String)
    case schedulingFailed(String)

    public var description: String {
        switch self {
        case .independentSourcePathRejected(let message), .audioDeviceUnavailable(let message),
            .decodeFailed(let message), .unsupportedPCMFormat(let message),
            .schedulingFailed(let message):
            return IngestRedaction.redact(message)
        }
    }

    var redacted: AppPlayerAdapterError {
        switch self {
        case .independentSourcePathRejected:
            return .independentSourcePathRejected(description)
        case .audioDeviceUnavailable:
            return .audioDeviceUnavailable(description)
        case .decodeFailed:
            return .decodeFailed(description)
        case .unsupportedPCMFormat:
            return .unsupportedPCMFormat(description)
        case .schedulingFailed:
            return .schedulingFailed(description)
        }
    }
}

/// App-facing playback adapter. Implementations consume decoded frames only;
/// source-opening belongs exclusively to the ingest decoder.
public protocol AppPCMPlaybackAdapting: Sendable {
    func prepare(streamID: Int64, sourceDescription: String, timeline: AppPlayerTimelineClock)
        async throws
    func play(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock) async throws
    func playReplacingScheduledBuffers(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock)
        async throws
    func pause(timeline: AppPlayerTimelineClock) async
    func resume(timeline: AppPlayerTimelineClock) async
    func stop(timeline: AppPlayerTimelineClock) async
    func applyPlaybackVolume(streamID: Int64) async
}

public extension AppPCMPlaybackAdapting {
    func applyPlaybackVolume(streamID: Int64) async {}

    func playReplacingScheduledBuffers(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock)
        async throws
    {
        try await play(frames, timeline: timeline)
    }
}

/// Minimal AVFoundation-backed app adapter. It owns the audio-device boundary and
/// intentionally has no API for opening a network source, preserving the single
/// decode path enforced by `SinglePathPCMDecoder`.
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
            playerNode.stop()
            clearScheduledBuffers()
            diagnosticsLog.recordEvent(
                "playback.prepare.requested",
                streamID: streamID,
                sourceDescription: sourceDescription,
                phase: "playback.prepare",
                fields: ["engineRunning": String(engine.isRunning)]
            )
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
                    playerNode.stop()
                    clearScheduledBuffers()
                    diagnosticsLog.recordEvent(
                        "playback.queue.flushed",
                        streamID: streamID,
                        phase: "playback.seek",
                        fields: ["reason": "seek"]
                    )
                }
                let buffers = try frames.map(makePCMBuffer)
                try startAudioEngineIfNeeded()
                if bufferScheduler != nil {
                    try schedule(buffers, timeline: timeline, streamID: streamID)
                } else {
                    let playbackBuffers = try buffers.map(convertToPlaybackFormat)
                    diagnosticsLog.recordEvent(
                        "playback.buffers.converted",
                        streamID: streamID,
                        phase: "playback.play",
                        fields: [
                            "sourceBufferCount": String(buffers.count),
                            "playbackBufferCount": String(playbackBuffers.count),
                            "outputSampleRate": String(engine.outputNode.inputFormat(forBus: 0).sampleRate),
                            "outputChannels": String(engine.outputNode.inputFormat(forBus: 0).channelCount),
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
            playerNode.stop()
            clearScheduledBuffers()
            setCurrentStreamID(nil)
            if let engineStopper {
                engineStopper()
            } else {
                engine.stop()
            }
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

        private func convertToPlaybackFormat(_ sourceBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
            let playbackFormat = engine.outputNode.inputFormat(forBus: 0)
            guard sourceBuffer.format != playbackFormat else { return sourceBuffer }
            guard let converter = AVAudioConverter(from: sourceBuffer.format, to: playbackFormat) else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format: AVFoundation could not create playback format converter."
                )
            }

            let sourceFrameCount = Double(sourceBuffer.frameLength)
            let sourceRate = sourceBuffer.format.sampleRate
            let playbackRate = playbackFormat.sampleRate
            let capacity = max(
                1,
                AVAudioFrameCount(ceil(sourceFrameCount * playbackRate / sourceRate)) + 512
            )
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: playbackFormat,
                frameCapacity: capacity
            ) else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format: AVFoundation could not allocate playback format buffer."
                )
            }

            var didProvideInput = false
            var conversionError: NSError?
            let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                didProvideInput = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            if let conversionError {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format: playback conversion failed: \(conversionError)."
                )
            }
            guard status != .error, convertedBuffer.frameLength > 0 else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format: playback conversion produced no renderable audio."
                )
            }
            return convertedBuffer
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
            playerNode.volume = effectiveVolume
            volumeMixerNode.outputVolume = effectiveVolume
        }

        private func makePCMBuffer(from frame: SharedPCMFrame) throws -> AVAudioPCMBuffer {
            let format = frame.format
            guard format.payloadKind == .linearPCM else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): decoded payload is \(format.payloadKind.rawValue)."
                )
            }
            guard frame.startSeconds.isFinite, frame.endSeconds.isFinite,
                frame.startSeconds >= 0, frame.endSeconds >= frame.startSeconds
            else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): timestamp bounds are malformed."
                )
            }
            guard let sampleRate = format.sampleRate, sampleRate.isFinite, sampleRate > 0 else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): missing sample rate.")
            }
            guard let channelCount = format.channelCount, channelCount > 0,
                channelCount <= Int(UInt32.max)
            else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): missing channel count.")
            }
            guard format.bitDepth == 16, !format.isFloat, format.isInterleaved, !format.isBigEndian
            else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): only little-endian interleaved 16-bit PCM is schedulable."
                )
            }
            guard frame.byteCount > 0, frame.byteCount <= frame.audio.count else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): PCM payload is empty or truncated."
                )
            }

            let bytesPerFrame = channelCount * MemoryLayout<Int16>.size
            guard frame.byteCount % bytesPerFrame == 0 else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): PCM payload byte count is not aligned to frames."
                )
            }
            let frameCount = frame.byteCount / bytesPerFrame
            guard frameCount > 0, frameCount <= Int(UInt32.max) else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): PCM payload frame count is invalid."
                )
            }
            guard
                let audioFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: sampleRate,
                    channels: AVAudioChannelCount(channelCount),
                    interleaved: true
                ),
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: audioFormat,
                    frameCapacity: AVAudioFrameCount(frameCount)
                )
            else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): AVFoundation could not create a PCM buffer."
                )
            }

            buffer.frameLength = AVAudioFrameCount(frameCount)
            let mutableBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard let audioBuffer = mutableBuffers.first,
                let destination = audioBuffer.mData
            else {
                throw AppPlayerAdapterError.schedulingFailed(
                    "Player scheduling failed: AVFoundation did not expose PCM buffer storage.")
            }
            guard audioBuffer.mDataByteSize >= frame.byteCount else {
                throw AppPlayerAdapterError.schedulingFailed(
                    "Player scheduling failed: AVFoundation PCM buffer storage is too small.")
            }
            frame.audio.withUnsafeBytes { rawBytes in
                if let source = rawBytes.baseAddress {
                    destination.copyMemory(from: source, byteCount: frame.byteCount)
                }
            }
            mutableBuffers[0].mDataByteSize = UInt32(frame.byteCount)
            return buffer
        }
    #endif
}

/// Deterministic adapter for tests and previews.
public actor DeterministicAppPCMPlayerAdapter: AppPCMPlaybackAdapting {
    private var preparedStreamIDs: [Int64] = []
    private var playedFrames: [SharedPCMFrame] = []

    public init() {}

    public func prepare(
        streamID: Int64, sourceDescription: String, timeline: AppPlayerTimelineClock
    ) async throws {
        preparedStreamIDs.append(streamID)
        await timeline.reset(
            streamID: streamID, message: "Prepared deterministic playback for \(sourceDescription)."
        )
    }

    public func play(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock) async throws {
        playedFrames.append(contentsOf: frames)
        await timeline.recordDecodedFrames(frames)
        let position = frames.last?.startSeconds
        await timeline.updatePlayerState(
            .playing, positionSeconds: position,
            message: "Deterministic playback accepted \(frames.count) frame(s).")
    }

    public func pause(timeline: AppPlayerTimelineClock) async {
        await timeline.updatePlayerState(.paused, message: "Deterministic playback paused.")
    }

    public func resume(timeline: AppPlayerTimelineClock) async {
        await timeline.updatePlayerState(.playing, message: "Deterministic playback resumed.")
    }

    public func stop(timeline: AppPlayerTimelineClock) async {
        await timeline.updatePlayerState(.stopped, message: "Deterministic playback stopped.")
    }

    public func preparedStreams() -> [Int64] { preparedStreamIDs }
    public func frames() -> [SharedPCMFrame] { playedFrames }
}

/// Decoder tee used by the app runtime: one upstream decode produces the frames
/// consumed by ingest and handed to playback. Playback failures surface on the
/// shared clock and fail the runtime rather than silently starting a second path.
public struct SinglePathPCMDecoder: AudioDecoding {
    private let streamID: Int64
    private let upstream: any AudioDecoding
    private let player: any AppPCMPlaybackAdapting
    private let timeline: AppPlayerTimelineClock
    private let rollingBuffer: RollingPCMBuffer?
    private let hlsPlaybackDeduplicator: HLSPlaybackDeduplicator?

    public init(
        streamID: Int64,
        upstream: any AudioDecoding,
        player: any AppPCMPlaybackAdapting,
        timeline: AppPlayerTimelineClock,
        rollingBuffer: RollingPCMBuffer? = nil,
        database: SoundingDatabase? = nil
    ) {
        self.streamID = streamID
        self.upstream = upstream
        self.player = player
        self.timeline = timeline
        self.rollingBuffer = rollingBuffer
        self.hlsPlaybackDeduplicator = database.map {
            HLSPlaybackDeduplicator(streamID: streamID, database: $0)
        }
    }

    public func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        let chunks = try await upstream.decodedChunks(for: request)
        let frames = chunks.map { SharedPCMFrame(streamID: streamID, chunk: $0) }
        if let rollingBuffer {
            let bufferedFrames = frames.filter { $0.format.payloadKind == .linearPCM }
            let snapshot = await rollingBuffer.append(bufferedFrames)
            await timeline.updateRollingBuffer(snapshot)
        }
        let playableFrames = await playableFrames(from: frames)

        guard !playableFrames.isEmpty else {
            await timeline.recordDecodedFrames(frames)
            await timeline.updatePlayerState(
                .buffering,
                message: "No new playable PCM was decoded; ingest continues without rescheduling duplicate audio."
            )
            return chunks
        }

        do {
            try await player.play(playableFrames, timeline: timeline)
        } catch {
            let failureMessage = "Playback adapter failed: \(error)."
            await timeline.updatePlayerState(
                .failed(message: failureMessage),
                message: failureMessage)
            throw AppPlayerAdapterError.decodeFailed(failureMessage)
        }
        return chunks
    }

    private func playableFrames(from frames: [SharedPCMFrame]) async -> [SharedPCMFrame] {
        var playableFrames: [SharedPCMFrame] = []
        playableFrames.reserveCapacity(frames.count)

        for frame in frames where frame.format.payloadKind == .linearPCM {
            guard let hlsPlaybackDeduplicator else {
                playableFrames.append(frame)
                continue
            }
            if await hlsPlaybackDeduplicator.shouldPlay(frame) {
                playableFrames.append(frame)
            }
        }

        return playableFrames
    }
}

private actor HLSPlaybackDeduplicator {
    private let streamID: Int64
    private let persistence: IngestPersistence
    private var acceptedMediaSequences: Set<Int> = []

    init(streamID: Int64, database: SoundingDatabase) {
        self.streamID = streamID
        self.persistence = IngestPersistence(database: database)
    }

    func shouldPlay(_ frame: SharedPCMFrame) -> Bool {
        guard let mediaSequence = frame.hlsIdentity?.mediaSequence else { return true }
        guard !acceptedMediaSequences.contains(mediaSequence) else { return false }
        if (try? persistence.hasPersistedHLSSegment(
            streamID: streamID,
            mediaSequence: mediaSequence
        )) == true {
            return false
        }
        acceptedMediaSequences.insert(mediaSequence)
        return true
    }
}
