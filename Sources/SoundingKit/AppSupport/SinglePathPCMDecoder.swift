import Foundation

struct SinglePathPCMFramePartition: Sendable {
    let linearPCMFrames: [SharedPCMFrame]
    let sawDecodedAudio: Bool

    init(frames: [SharedPCMFrame]) {
        var linearPCMFrames: [SharedPCMFrame] = []
        linearPCMFrames.reserveCapacity(frames.count)
        var sawDecodedAudio = false

        for frame in frames {
            if frame.format.payloadKind == .linearPCM {
                linearPCMFrames.append(frame)
            }
            if !frame.audio.isEmpty && frame.byteCount > 0 {
                sawDecodedAudio = true
            }
        }

        self.linearPCMFrames = linearPCMFrames
        self.sawDecodedAudio = sawDecodedAudio
    }
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
        let framePartition = SinglePathPCMFramePartition(frames: frames)
        if let rollingBuffer {
            let snapshot = await rollingBuffer.append(framePartition.linearPCMFrames)
            await timeline.updateRollingBuffer(snapshot)
        }
        let playableFrames = await playableFrames(fromLinearPCMFrames: framePartition.linearPCMFrames)

        guard !playableFrames.isEmpty else {
            let message = framePartition.sawDecodedAudio
                ? "Decoded audio was not playable PCM; ingest continues without scheduling playback."
                : "No new playable PCM was decoded; ingest continues without rescheduling duplicate audio."
            await timeline.updatePlayerState(
                .buffering,
                message: message
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

    private func playableFrames(fromLinearPCMFrames linearPCMFrames: [SharedPCMFrame]) async -> [SharedPCMFrame] {
        guard let hlsPlaybackDeduplicator else { return linearPCMFrames }
        return await hlsPlaybackDeduplicator.playableFrames(from: linearPCMFrames)
    }
}

private actor HLSPlaybackDeduplicator {
    private let streamID: Int64
    private let persistence: IngestPersistence
    private var acceptedSegmentKeys: Set<String> = []
    private var persistedSegmentKeys: Set<HLSDecodedAudioSegmentKey>?

    init(streamID: Int64, database: SoundingDatabase) {
        self.streamID = streamID
        self.persistence = IngestPersistence(database: database)
    }

    func playableFrames(from frames: [SharedPCMFrame]) -> [SharedPCMFrame] {
        var playableFrames: [SharedPCMFrame] = []
        playableFrames.reserveCapacity(frames.count)

        for frame in frames where shouldPlay(frame) {
            playableFrames.append(frame)
        }

        return playableFrames
    }

    private func shouldPlay(_ frame: SharedPCMFrame) -> Bool {
        guard let hlsIdentity = frame.hlsIdentity else { return true }
        let mediaSequence = hlsIdentity.mediaSequence
        let inMemoryKey = "\(mediaSequence):\(hlsIdentity.segmentIdentity)"
        guard !acceptedSegmentKeys.contains(inMemoryKey) else { return false }
        let segmentKey = HLSDecodedAudioSegmentKey(
            mediaSequence: mediaSequence,
            segmentIdentity: hlsIdentity.segmentIdentity
        )
        if persistedKeys().contains(segmentKey) {
            return false
        }
        acceptedSegmentKeys.insert(inMemoryKey)
        return true
    }

    private func persistedKeys() -> Set<HLSDecodedAudioSegmentKey> {
        if let persistedSegmentKeys { return persistedSegmentKeys }
        let keys = (try? persistence.persistedHLSSegmentKeys(streamID: streamID)) ?? []
        persistedSegmentKeys = keys
        return keys
    }
}
