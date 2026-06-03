import Foundation

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
