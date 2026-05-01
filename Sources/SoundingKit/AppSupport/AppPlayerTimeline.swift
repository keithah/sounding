import Foundation

#if canImport(AVFoundation)
    import AVFoundation
#endif

/// Format metadata for decoded audio shared by ingest and playback.
/// Existing decoders may not know the concrete PCM format yet, so the default
/// contract remains explicit about unknown format instead of inventing one.
public struct SharedPCMFormat: Equatable, Sendable {
    public var sampleRate: Double?
    public var channelCount: Int?
    public var bitDepth: Int?

    public init(sampleRate: Double? = nil, channelCount: Int? = nil, bitDepth: Int? = nil) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
    }

    public static let unknown = SharedPCMFormat()
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

    public init(streamID: Int64, chunk: DecodedAudioChunk, format: SharedPCMFormat = .unknown) {
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
        lastMessage: String = "Player idle."
    ) {
        self.streamID = streamID
        self.state = state
        self.positionSeconds = positionSeconds
        self.liveEdgeSeconds = liveEdgeSeconds
        self.bufferedStartSeconds = bufferedStartSeconds
        self.bufferedEndSeconds = bufferedEndSeconds
        self.driftSeconds = driftSeconds
        self.decodedFrameCount = decodedFrameCount
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
            lastMessage: message
        )
    }

    public func snapshot() -> AppPlayerTimelineSnapshot { current }
}

public enum AppPlayerAdapterError: Error, Equatable, CustomStringConvertible, Sendable {
    case independentSourcePathRejected(String)
    case audioDeviceUnavailable(String)
    case decodeFailed(String)

    public var description: String {
        switch self {
        case .independentSourcePathRejected(let message), .audioDeviceUnavailable(let message),
            .decodeFailed(let message):
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
    #endif

    public init() {}

    public func prepare(
        streamID: Int64, sourceDescription: String, timeline: AppPlayerTimelineClock
    ) async throws {
        #if canImport(AVFoundation)
            if !engine.isRunning {
                do {
                    try engine.start()
                } catch {
                    await timeline.updatePlayerState(
                        .failed(message: "Audio device unavailable."),
                        message: "Audio device unavailable: \(error).")
                    throw AppPlayerAdapterError.audioDeviceUnavailable(
                        "Audio device unavailable: \(error).")
                }
            }
        #endif
        await timeline.reset(
            streamID: streamID, message: "Prepared playback for \(sourceDescription).")
    }

    public func play(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock) async throws {
        await timeline.recordDecodedFrames(frames)
        if let last = frames.max(by: { $0.endSeconds < $1.endSeconds }) {
            await timeline.updatePlayerState(
                .playing,
                positionSeconds: last.startSeconds,
                message: "Playing shared PCM frame \(last.sequence)."
            )
        } else {
            await timeline.updatePlayerState(.buffering, message: "Waiting for decoded PCM frames.")
        }
    }

    public func pause(timeline: AppPlayerTimelineClock) async {
        await timeline.updatePlayerState(.paused, message: "Playback paused.")
    }

    public func resume(timeline: AppPlayerTimelineClock) async {
        await timeline.updatePlayerState(.playing, message: "Playback resumed.")
    }

    public func stop(timeline: AppPlayerTimelineClock) async {
        #if canImport(AVFoundation)
            engine.stop()
        #endif
        await timeline.updatePlayerState(.stopped, message: "Playback stopped.")
    }
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

    public init(
        streamID: Int64,
        upstream: any AudioDecoding,
        player: any AppPCMPlaybackAdapting,
        timeline: AppPlayerTimelineClock
    ) {
        self.streamID = streamID
        self.upstream = upstream
        self.player = player
        self.timeline = timeline
    }

    public func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        let chunks = try await upstream.decodedChunks(for: request)
        let frames = chunks.map { SharedPCMFrame(streamID: streamID, chunk: $0) }
        do {
            try await player.play(frames, timeline: timeline)
        } catch {
            await timeline.updatePlayerState(
                .failed(message: String(describing: error)),
                message: "Playback adapter failed: \(error).")
            throw AppPlayerAdapterError.decodeFailed("Playback adapter failed: \(error).")
        }
        return chunks
    }
}
