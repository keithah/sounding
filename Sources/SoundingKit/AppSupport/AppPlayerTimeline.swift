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

    public var hasActivePlayback: Bool {
        switch state {
        case .buffering, .playing, .paused:
            return true
        case .idle, .stopped, .failed:
            return false
        }
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
