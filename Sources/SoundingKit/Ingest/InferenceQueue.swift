import Foundation

/// A non-reentrant async boundary for shared ML inference providers.
///
/// Swift actors may interleave other actor-isolated work while an awaited provider call is suspended.
/// `InferenceQueue` instead hands out one explicit permit at a time and keeps that permit held until
/// the wrapped operation returns, throws, or is cancelled. Labels are accepted for caller-side context
/// but are not persisted or logged, because they may contain source-specific details.
public actor InferenceQueue {
    public struct Snapshot: Equatable, Sendable {
        public var submitted: Int
        public var started: Int
        public var completed: Int
        public var currentDepth: Int
        public var maxDepth: Int
        public var isBusy: Bool
    }

    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Void, any Error>
    }

    private var isBusy = false
    private var waiters: [Waiter] = []
    private var submitted = 0
    private var started = 0
    private var completed = 0
    private var maxDepth = 0

    public init() {}

    /// Runs `operation` after acquiring the single inference permit.
    ///
    /// Waiting callers are admitted FIFO. If a waiting task is cancelled, its continuation is removed
    /// from the queue and the permit remains available for the next waiter. Provider errors and
    /// cancellation are deliberately propagated unchanged.
    public func run<T>(
        _ label: String,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        _ = label
        try await acquire()
        do {
            try Task.checkCancellation()
            let value = try await operation()
            markCompleted()
            release()
            return value
        } catch {
            markCompleted()
            release()
            throw error
        }
    }

    /// Safe in-memory diagnostics for tests and completion summaries. No operation labels are exposed.
    public func snapshot() -> Snapshot {
        Snapshot(
            submitted: submitted,
            started: started,
            completed: completed,
            currentDepth: waiters.count + (isBusy ? 1 : 0),
            maxDepth: maxDepth,
            isBusy: isBusy
        )
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        submitted += 1

        if !isBusy && waiters.isEmpty {
            isBusy = true
            started += 1
            maxDepth = max(maxDepth, 1)
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(id: id, continuation: continuation)
            }
        } onCancel: {
            Task { await cancelWaiter(id: id) }
        }
        try Task.checkCancellation()
    }

    private func enqueue(id: UUID, continuation: CheckedContinuation<Void, any Error>) {
        waiters.append(Waiter(id: id, continuation: continuation))
        maxDepth = max(maxDepth, waiters.count + (isBusy ? 1 : 0))
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
            return
        }

        let waiter = waiters.removeFirst()
        isBusy = true
        started += 1
        waiter.continuation.resume()
    }

    private func markCompleted() {
        completed += 1
    }
}
