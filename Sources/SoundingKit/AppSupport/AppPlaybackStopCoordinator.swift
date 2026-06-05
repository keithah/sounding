import Foundation

enum AppPlaybackStopCoordinator {
    static let defaultTimeoutNanoseconds: UInt64 = 2_000_000_000

    static func stop(
        _ player: any AppPCMPlaybackAdapting,
        timeline: AppPlayerTimelineClock,
        timeoutNanoseconds: UInt64,
        onTimeout: @escaping @Sendable () -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = AppPlaybackStopCompletion(continuation)
            let stopTask = Task {
                await player.stop(timeline: timeline)
                gate.resume(true)
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                let didResume = gate.resume(false)
                if didResume {
                    stopTask.cancel()
                    onTimeout()
                }
            }
        }
    }
}

private final class AppPlaybackStopCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ value: Bool) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
        return true
    }
}
