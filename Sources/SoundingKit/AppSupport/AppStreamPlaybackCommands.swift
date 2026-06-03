import Foundation

struct AppStreamPlaybackCommands: Sendable {
    let volumeStore: AppPlaybackVolumeStore?
    let playbackTimeline: AppPlayerTimelineClock?
    let rollingBuffer: RollingPCMBuffer?
    let audioArchiveStore: AudioArchiveStore?
    let playbackController: (any AppPCMPlaybackAdapting)?
    let diagnosticsLog: AppRuntimeDiagnosticsLog

    func setVolume(streamID: Int64, volume: Double) async -> Int {
        let clamped = min(max(volume, 0), 1)
        diagnosticsLog.recordEvent(
            "runtime.volume.requested",
            streamID: streamID,
            phase: "runtime.volume",
            fields: ["volume": String(format: "%.3f", clamped)]
        )
        await volumeStore?.setVolume(streamID: streamID, volume: volume)
        await playbackController?.applyPlaybackVolume(streamID: streamID)
        return Int((clamped * 100).rounded())
    }

    func setMuted(streamID: Int64, isMuted: Bool) async {
        diagnosticsLog.recordEvent(
            "runtime.mute.requested",
            streamID: streamID,
            phase: "runtime.volume",
            fields: ["isMuted": String(isMuted)]
        )
        await volumeStore?.setMuted(streamID: streamID, isMuted: isMuted)
        await playbackController?.applyPlaybackVolume(streamID: streamID)
    }

    func seek(to seconds: Double, streamID: Int64) async -> Bool {
        guard let playbackTimeline else { return false }
        guard rollingBuffer != nil || audioArchiveStore != nil else { return false }
        if let rollingBuffer, audioArchiveStore == nil {
            let bufferSnapshot = await rollingBuffer.snapshot()
            guard bufferSnapshot.streamID == streamID else { return false }
        }
        let result = await TimelineReplayResolver(
            rollingBuffer: rollingBuffer,
            audioArchiveStore: audioArchiveStore
        )
        .resolve(streamID: streamID, seconds: seconds)
        guard result.availableStreamID.map({ $0 == streamID }) ?? true else { return false }
        await playReplayResult(result, streamID: streamID, playbackTimeline: playbackTimeline)
        return true
    }

    func seekToLive(streamID: Int64) async -> Bool {
        guard let rollingBuffer, let playbackTimeline else { return false }
        let bufferSnapshot = await rollingBuffer.snapshot()
        guard bufferSnapshot.streamID == streamID else { return false }
        let result = await rollingBuffer.seekToLive()
        guard result.availableStreamID.map({ $0 == streamID }) ?? true else { return false }
        await playSeekResult(result, streamID: streamID, playbackTimeline: playbackTimeline)
        return true
    }

    func scrubBackward(seconds: Double, streamID: Int64) async -> Bool {
        guard let rollingBuffer, let playbackTimeline else { return false }
        let bufferSnapshot = await rollingBuffer.snapshot()
        guard bufferSnapshot.streamID == streamID else { return false }
        let timeline = await playbackTimeline.snapshot()
        let requested = max(0, timeline.liveEdgeSeconds - max(0, seconds))
        let result = await rollingBuffer.seek(to: requested)
        guard result.availableStreamID.map({ $0 == streamID }) ?? true else { return false }
        await playSeekResult(result, streamID: streamID, playbackTimeline: playbackTimeline)
        return true
    }

    private func playSeekResult(
        _ result: RollingBufferSeekResult,
        streamID: Int64,
        playbackTimeline: AppPlayerTimelineClock
    ) async {
        if case .available(let frame) = result, let playbackController {
            diagnosticsLog.recordEvent(
                "runtime.seek.playback.requested",
                streamID: streamID,
                phase: "runtime.seek",
                fields: [
                    "frameSequence": String(frame.sequence),
                    "startSeconds": String(format: "%.3f", frame.startSeconds),
                    "endSeconds": String(format: "%.3f", frame.endSeconds),
                ]
            )
            do {
                try await playbackController.playReplacingScheduledBuffers(
                    [frame],
                    timeline: playbackTimeline
                )
            } catch {
                diagnosticsLog.recordEvent(
                    "runtime.seek.playback.failed",
                    streamID: streamID,
                    phase: "runtime.seek",
                    fields: ["error": IngestRedaction.redact(String(describing: error))]
                )
                await playbackTimeline.applySeekResult(result)
            }
        } else {
            await playbackTimeline.applySeekResult(result)
        }
    }

    private func playReplayResult(
        _ result: TimelineReplayResult,
        streamID: Int64,
        playbackTimeline: AppPlayerTimelineClock
    ) async {
        switch result {
        case .available(let frame, let source):
            diagnosticsLog.recordEvent(
                "runtime.seek.playback.requested",
                streamID: streamID,
                phase: "runtime.seek",
                fields: [
                    "frameSequence": String(frame.sequence),
                    "source": source.rawValue,
                    "startSeconds": String(format: "%.3f", frame.startSeconds),
                    "endSeconds": String(format: "%.3f", frame.endSeconds),
                ]
            )
            do {
                try await playbackController?.playReplacingScheduledBuffers(
                    [frame],
                    timeline: playbackTimeline
                )
                await playbackTimeline.applySeekResult(.available(frame))
            } catch {
                diagnosticsLog.recordEvent(
                    "runtime.seek.playback.failed",
                    streamID: streamID,
                    phase: "runtime.seek",
                    fields: ["error": IngestRedaction.redact(String(describing: error))]
                )
                await playbackTimeline.applySeekResult(.available(frame))
            }
        case .unavailable(let requestedSeconds, let bufferedRange, _):
            await playbackTimeline.applySeekResult(
                .unavailable(requestedSeconds: requestedSeconds, bufferedRange: bufferedRange)
            )
        }
    }
}

private extension TimelineReplaySource {
    var rawValue: String {
        switch self {
        case .rollingBuffer: return "rollingBuffer"
        case .audioArchive: return "audioArchive"
        }
    }
}

private extension TimelineReplayResult {
    var availableStreamID: Int64? {
        switch self {
        case .available(let frame, _):
            return frame.streamID
        case .unavailable:
            return nil
        }
    }
}
