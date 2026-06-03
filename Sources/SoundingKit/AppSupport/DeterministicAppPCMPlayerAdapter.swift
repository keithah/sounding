import Foundation

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

    public func playReplacingScheduledBuffers(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock)
        async throws
    {
        playedFrames.append(contentsOf: frames)
        await timeline.recordDecodedFrames(frames)
        await timeline.applySeekResult(frames.last.map { .available($0) } ?? .unavailable(
            requestedSeconds: 0,
            bufferedRange: nil
        ))
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
