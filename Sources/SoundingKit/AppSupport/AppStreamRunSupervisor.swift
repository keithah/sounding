import Foundation

struct AppStreamRunSupervisor: Sendable {
    typealias RecoveredLifecycleEvidence =
        @Sendable (AppStreamRuntimeLifecycleEvidence?) async -> AppStreamRuntimeLifecycleEvidence?
    typealias PublishIfCurrent =
        @Sendable (
            Int64,
            UUID,
            AppStreamRuntimeEvent,
            Int,
            Int?,
            String?
        ) async -> Void
    typealias FinishIfCurrent =
        @Sendable (
            Int64,
            UUID,
            AppStreamRuntimeEvent,
            Int,
            String?
        ) async -> Void

    let request: AppStreamRuntimeRequest
    let token: UUID
    let ingester: any AppStreamRuntimeIngesting
    let retryPolicy: AppStreamRuntimeRetryPolicy
    let retrySleep: @Sendable (Int) async throws -> Void
    let recoveryEvidence: AppStreamRuntimeLifecycleEvidence?
    let recoveredLifecycleEvidence: RecoveredLifecycleEvidence
    let publishIfCurrent: PublishIfCurrent
    let finishIfCurrent: FinishIfCurrent

    func makeTask() -> Task<Void, Never> {
        Task {
            var attempt = 0
            while !Task.isCancelled {
                await publishRunning(attempt: attempt)
                do {
                    let result = try await ingester.run(request)
                    await finish(
                        phase: .stopped,
                        message: "Stopped \(request.name) after \(result.processedChunks) chunk(s).",
                        result: result,
                        attempt: attempt
                    )
                    return
                } catch is CancellationError {
                    await finish(
                        phase: .stopped,
                        message: "Stopped \(request.name).",
                        attempt: attempt
                    )
                    return
                } catch {
                    let shouldContinue = await handleFailure(error, attempt: &attempt)
                    if !shouldContinue { return }
                }
            }
        }
    }

    private func publishRunning(attempt: Int) async {
        let runningLifecycleEvidence = await recoveredLifecycleEvidence(recoveryEvidence)
        await publishIfCurrent(
            request.streamID,
            token,
            AppStreamRuntimeEvent(
                streamID: request.streamID,
                phase: .running,
                message: "Running \(request.name) from \(request.sourceDescription).",
                lifecycleEvidence: runningLifecycleEvidence
            ),
            attempt,
            nil,
            nil
        )
    }

    private func handleFailure(_ error: any Error, attempt: inout Int) async -> Bool {
        let redacted = IngestRedaction.redact(String(describing: error))
        guard attempt < retryPolicy.maximumReconnectAttempts else {
            await finish(
                phase: .error(message: redacted),
                message: "Runtime failed for \(request.name): \(redacted).",
                attempt: attempt,
                failureMessage: redacted
            )
            return false
        }

        attempt += 1
        let seconds = max(0, retryPolicy.backoffSeconds(attempt))
        await publishIfCurrent(
            request.streamID,
            token,
            AppStreamRuntimeEvent(
                streamID: request.streamID,
                phase: .reconnecting(nextRetrySeconds: seconds),
                message: "Runtime failed for \(request.name): \(redacted). Reconnecting in \(seconds) second(s).",
                lifecycleEvidence: recoveryEvidence
            ),
            attempt,
            seconds,
            redacted
        )
        do {
            try await retrySleep(seconds)
        } catch {
            await finish(
                phase: .stopped,
                message: "Stopped \(request.name).",
                attempt: attempt
            )
            return false
        }
        await publishIfCurrent(
            request.streamID,
            token,
            AppStreamRuntimeEvent(
                streamID: request.streamID,
                phase: .connecting,
                message: "Reconnecting \(request.name).",
                lifecycleEvidence: recoveryEvidence
            ),
            attempt,
            nil,
            nil
        )
        return true
    }

    private func finish(
        phase: AppStreamRuntimePhase,
        message: String,
        result: AppStreamRuntimeResult? = nil,
        attempt: Int,
        failureMessage: String? = nil
    ) async {
        await finishIfCurrent(
            request.streamID,
            token,
            AppStreamRuntimeEvent(
                streamID: request.streamID,
                phase: phase,
                message: message,
                result: result,
                lifecycleEvidence: recoveryEvidence
            ),
            attempt,
            failureMessage
        )
    }
}
