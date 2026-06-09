import Foundation

enum AppPlaybackStopCoordinator {
    static let defaultTimeoutNanoseconds: UInt64 = 2_000_000_000

    static func stop(
        _ player: any AppPCMPlaybackAdapting,
        timeline: AppPlayerTimelineClock,
        timeoutNanoseconds: UInt64,
        onTimeout: @escaping @Sendable () -> Void
    ) async -> Bool {
        _ = timeoutNanoseconds
        _ = onTimeout
        await player.stop(timeline: timeline)
        return true
    }
}
