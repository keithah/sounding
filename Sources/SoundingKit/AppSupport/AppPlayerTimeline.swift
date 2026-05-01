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

    public init(
        streamID: Int64,
        sequence: Int,
        audio: Data,
        byteCount: Int? = nil,
        startSeconds: Double,
        endSeconds: Double,
        format: SharedPCMFormat = .unknown
    ) {
        self.streamID = streamID
        self.sequence = sequence
        self.audio = audio
        self.byteCount = byteCount ?? audio.count
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.format = format
    }

    public init(
        streamID: Int64, chunk: DecodedAudioChunk, format: SharedPCMFormat = .containerBytes
    ) {
        self.init(
            streamID: streamID,
            sequence: chunk.sequence,
            audio: chunk.audio,
            byteCount: chunk.byteCount,
            startSeconds: chunk.startSeconds,
            endSeconds: chunk.endSeconds,
            format: format
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
}

/// App-facing playback adapter. Implementations consume decoded frames only;
/// source-opening belongs exclusively to the ingest decoder.
public protocol AppPCMPlaybackAdapting: Sendable {
    func prepare(streamID: Int64, sourceDescription: String, timeline: AppPlayerTimelineClock)
        async throws
    func play(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock) async throws
    func pause(timeline: AppPlayerTimelineClock) async
    func resume(timeline: AppPlayerTimelineClock) async
    func stop(timeline: AppPlayerTimelineClock) async
}

/// Minimal AVFoundation-backed app adapter. It owns the audio-device boundary and
/// intentionally has no API for opening a network source, preserving the single
/// decode path enforced by `SinglePathPCMDecoder`.
public final class AVFoundationAppPCMPlayerAdapter: AppPCMPlaybackAdapting, @unchecked Sendable {
    #if canImport(AVFoundation)
        private let engine = AVAudioEngine()
        private let playerNode = AVAudioPlayerNode()
        private var didAttachPlayerNode = false
        private let engineStarter: (@Sendable () throws -> Void)?
        private let bufferScheduler: (@Sendable ([AVAudioPCMBuffer]) throws -> Void)?
        private let playerStarter: (@Sendable () -> Void)?
        private let engineStopper: (@Sendable () -> Void)?
    #endif

    public init() {
        #if canImport(AVFoundation)
            self.engineStarter = nil
            self.bufferScheduler = nil
            self.playerStarter = nil
            self.engineStopper = nil
        #endif
    }

    #if canImport(AVFoundation)
        init(
            engineStarter: (@Sendable () throws -> Void)?,
            bufferScheduler: (@Sendable ([AVAudioPCMBuffer]) throws -> Void)?,
            playerStarter: (@Sendable () -> Void)? = nil,
            engineStopper: (@Sendable () -> Void)? = nil
        ) {
            self.engineStarter = engineStarter
            self.bufferScheduler = bufferScheduler
            self.playerStarter = playerStarter
            self.engineStopper = engineStopper
        }
    #endif

    public func prepare(
        streamID: Int64, sourceDescription: String, timeline: AppPlayerTimelineClock
    ) async throws {
        #if canImport(AVFoundation)
            do {
                try startAudioEngineIfNeeded()
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
        guard !frames.isEmpty else { return }

        do {
            #if canImport(AVFoundation)
                let buffers = try frames.map(makePCMBuffer)
                try startAudioEngineIfNeeded()
                try schedule(buffers)
                startPlayerNodeIfNeeded()
            #else
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "AVFoundation playback is unavailable on this platform.")
            #endif
        } catch let error as AppPlayerAdapterError {
            await publishFailure(error.description, timeline: timeline)
            throw error
        } catch {
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
        #endif
        await timeline.updatePlayerState(.paused, message: "Playback paused.")
    }

    public func resume(timeline: AppPlayerTimelineClock) async {
        #if canImport(AVFoundation)
            startPlayerNodeIfNeeded()
        #endif
        await timeline.updatePlayerState(.playing, message: "Playback resumed.")
    }

    public func stop(timeline: AppPlayerTimelineClock) async {
        #if canImport(AVFoundation)
            playerNode.stop()
            if let engineStopper {
                engineStopper()
            } else {
                engine.stop()
            }
        #endif
        await timeline.updatePlayerState(.stopped, message: "Playback stopped.")
    }

    private func publishFailure(_ message: String, timeline: AppPlayerTimelineClock) async {
        await timeline.updatePlayerState(
            .failed(message: message),
            message: message
        )
    }

    #if canImport(AVFoundation)
        private func startAudioEngineIfNeeded() throws {
            if let engineStarter {
                try engineStarter()
                return
            }
            if !didAttachPlayerNode {
                engine.attach(playerNode)
                let outputFormat = engine.outputNode.inputFormat(forBus: 0)
                engine.connect(playerNode, to: engine.outputNode, format: outputFormat)
                didAttachPlayerNode = true
            }
            if !engine.isRunning {
                try engine.start()
            }
        }

        private func schedule(_ buffers: [AVAudioPCMBuffer]) throws {
            if let bufferScheduler {
                try bufferScheduler(buffers)
                return
            }
            for buffer in buffers {
                playerNode.scheduleBuffer(buffer, completionHandler: nil)
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

    public init(
        streamID: Int64,
        upstream: any AudioDecoding,
        player: any AppPCMPlaybackAdapting,
        timeline: AppPlayerTimelineClock,
        rollingBuffer: RollingPCMBuffer? = nil
    ) {
        self.streamID = streamID
        self.upstream = upstream
        self.player = player
        self.timeline = timeline
        self.rollingBuffer = rollingBuffer
    }

    public func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        let chunks = try await upstream.decodedChunks(for: request)
        let frames = chunks.map { SharedPCMFrame(streamID: streamID, chunk: $0) }
        if let rollingBuffer {
            let snapshot = await rollingBuffer.append(frames)
            await timeline.updateRollingBuffer(snapshot)
        }
        do {
            try await player.play(frames, timeline: timeline)
        } catch {
            let failureMessage = "Playback adapter failed: \(error)."
            await timeline.updatePlayerState(
                .failed(message: failureMessage),
                message: failureMessage)
            throw AppPlayerAdapterError.decodeFailed(failureMessage)
        }
        return chunks
    }
}
