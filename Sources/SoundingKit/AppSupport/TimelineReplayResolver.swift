import Foundation

public enum TimelineReplaySource: Equatable, Sendable {
    case rollingBuffer
    case audioArchive
}

public enum TimelineReplayResult: Equatable, Sendable {
    case available(SharedPCMFrame, source: TimelineReplaySource)
    case unavailable(requestedSeconds: Double, bufferedRange: RollingBufferRange?, reason: String)
}

public struct TimelineReplayResolver: Sendable {
    private let rollingBuffer: RollingPCMBuffer?
    private let audioArchiveStore: AudioArchiveStore?

    public init(
        rollingBuffer: RollingPCMBuffer?,
        audioArchiveStore: AudioArchiveStore?
    ) {
        self.rollingBuffer = rollingBuffer
        self.audioArchiveStore = audioArchiveStore
    }

    public func resolve(streamID: Int64, seconds: Double) async -> TimelineReplayResult {
        let snapshot = await rollingBuffer?.snapshot()
        let bufferedRange = snapshot?.streamID == streamID ? snapshot?.bufferedRange : nil
        guard seconds.isFinite, seconds >= 0 else {
            return unavailable(seconds: seconds, bufferedRange: bufferedRange)
        }

        if snapshot?.streamID == streamID, let rollingBuffer {
            let result = await rollingBuffer.seek(to: seconds)
            if case .available(let frame) = result, frame.streamID == streamID {
                return .available(frame, source: .rollingBuffer)
            }
        }

        if let audioArchiveStore, let archived = try? audioArchiveStore.frame(streamID: streamID, seconds: seconds) {
            return .available(archived.frame, source: .audioArchive)
        }

        return unavailable(seconds: seconds, bufferedRange: bufferedRange)
    }

    private func unavailable(seconds: Double, bufferedRange: RollingBufferRange?) -> TimelineReplayResult {
        .unavailable(
            requestedSeconds: seconds,
            bufferedRange: bufferedRange,
            reason: "Requested time is not available in rolling buffer or audio archive."
        )
    }
}
