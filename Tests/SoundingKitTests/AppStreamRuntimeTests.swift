import Foundation
import GRDB
import XCTest

@testable import SoundingKit

final class AppStreamRuntimeTests: XCTestCase {
    func testStartsManagedStreamThroughInProcessRunnerAndPublishesLifecycle() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Fixture HLS",
            streamType: "hls",
            source: "https://user:pass@example.test/live.m3u8?token=secret"
        )
        let ingester = RecordingAppRuntimeIngester(
            result: AppStreamRuntimeResult(
                streamID: stream.id, runID: 7, processedChunks: 2, diagnosticCount: 0))
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: ingester,
            retryPolicy: .noRetry
        )
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        try await runtime.start(streamID: stream.id)

        let connecting = try await nextEvent(from: &iterator)
        let running = try await nextEvent(from: &iterator)
        let stopped = try await nextEvent(from: &iterator)

        XCTAssertEqual(connecting.phase, .connecting)
        XCTAssertEqual(running.phase, .running)
        XCTAssertEqual(stopped.phase, .stopped)
        XCTAssertEqual(stopped.result?.runID, 7)
        XCTAssertEqual(stopped.result?.processedChunks, 2)
        XCTAssertFalse(
            [connecting, running, stopped].map(\.message).joined().contains("user:pass"))
        XCTAssertFalse(
            [connecting, running, stopped].map(\.message).joined().contains("token=secret"))

        let requests = await ingester.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].streamID, stream.id)
        XCTAssertEqual(requests[0].source, "https://user:pass@example.test/live.m3u8?token=secret")
        XCTAssertEqual(requests[0].sourceDescription, "https://example.test/live.m3u8")
        XCTAssertEqual(requests[0].streamType, .hls)
    }

    func testPauseResumeAndStopPublishSelectedStreamStatusWithoutCLISubprocess() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Fixture ICY",
            streamType: "icy",
            source: "http://user:pass@example.test/live?token=secret"
        )
        let gate = RuntimeGate()
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: BlockingAppRuntimeIngester(gate: gate),
            retryPolicy: .noRetry
        )
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        try await runtime.start(streamID: stream.id)
        let connecting = try await nextEvent(from: &iterator)
        let running = try await nextEvent(from: &iterator)
        XCTAssertEqual(connecting.phase, .connecting)
        XCTAssertEqual(running.phase, .running)

        await runtime.pause()
        let paused = try await nextEvent(from: &iterator)
        XCTAssertEqual(paused.phase, .paused)
        await runtime.resume()
        let resumed = try await nextEvent(from: &iterator)
        XCTAssertEqual(resumed.phase, .running)
        await runtime.stop()
        let stopped = try await nextEvent(from: &iterator)
        XCTAssertEqual(stopped.phase, .stopped)

        await gate.release()
    }

    func testReconnectsAfterRedactedRuntimeFailure() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Retry HLS",
            streamType: "hls",
            source: "https://user:pass@example.test/retry.m3u8?token=secret"
        )
        let ingester = FlakyAppRuntimeIngester(streamID: stream.id)
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: ingester,
            retryPolicy: AppStreamRuntimeRetryPolicy(
                maximumReconnectAttempts: 1, backoffSeconds: { _ in 0 }),
            retrySleep: { _ in }
        )
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        try await runtime.start(streamID: stream.id)

        let firstConnecting = try await nextEvent(from: &iterator)
        let firstRunning = try await nextEvent(from: &iterator)
        XCTAssertEqual(firstConnecting.phase, .connecting)
        XCTAssertEqual(firstRunning.phase, .running)
        let reconnecting = try await nextEvent(from: &iterator)
        XCTAssertEqual(reconnecting.phase, .reconnecting(nextRetrySeconds: 0))
        XCTAssertFalse(reconnecting.message.contains("user:pass"), reconnecting.message)
        XCTAssertFalse(reconnecting.message.contains("token=secret"), reconnecting.message)
        XCTAssertTrue(reconnecting.message.contains("[redacted-path]"), reconnecting.message)
        let secondConnecting = try await nextEvent(from: &iterator)
        let secondRunning = try await nextEvent(from: &iterator)
        let stopped = try await nextEvent(from: &iterator)
        XCTAssertEqual(secondConnecting.phase, .connecting)
        XCTAssertEqual(secondRunning.phase, .running)
        XCTAssertEqual(stopped.phase, .stopped)
        let callCount = await ingester.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testFlakyStreamReconnectsWhileSiblingRemainsRunningAndStatusesAreIsolated() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let retrying = try registry.add(
            name: "Retry HLS",
            streamType: "hls",
            source: "https://user:pass@example.test/retry.m3u8?token=secret"
        )
        let sibling = try registry.add(
            name: "Sibling ICY",
            streamType: "icy",
            source: "http://user:pass@example.test/live?token=sibling"
        )
        let statusStore = AppStreamRuntimeStatusStore(database: temporary.database)
        let retrySleep = RetrySleepGate()
        let siblingGate = RuntimeGate()
        let ingester = PerStreamRuntimeIngester(
            flakyStreamID: retrying.id,
            blockingStreamID: sibling.id,
            blockingGate: siblingGate
        )
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: ingester,
            retryPolicy: AppStreamRuntimeRetryPolicy(
                maximumReconnectAttempts: 1, backoffSeconds: { _ in 5 }),
            statusStore: statusStore,
            retrySleep: { seconds in try await retrySleep.sleep(seconds: seconds) }
        )
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        try await runtime.start(streamID: retrying.id)
        let retryingConnecting = try await nextEvent(from: &iterator)
        let retryingRunning = try await nextEvent(from: &iterator)
        XCTAssertEqual(retryingConnecting.phase, .connecting)
        XCTAssertEqual(retryingRunning.phase, .running)
        let reconnecting = try await nextEvent(from: &iterator)
        XCTAssertEqual(reconnecting.streamID, retrying.id)
        XCTAssertEqual(reconnecting.phase, .reconnecting(nextRetrySeconds: 5))

        try await runtime.start(streamID: sibling.id)
        let siblingConnecting = try await nextEvent(from: &iterator)
        let siblingRunning = try await nextEvent(from: &iterator)
        XCTAssertEqual(siblingConnecting.streamID, sibling.id)
        XCTAssertEqual(siblingConnecting.phase, .connecting)
        XCTAssertEqual(siblingRunning.streamID, sibling.id)
        XCTAssertEqual(siblingRunning.phase, .running)
        let retryingSnapshot = await runtime.snapshot(streamID: retrying.id)
        let siblingSnapshot = await runtime.snapshot(streamID: sibling.id)
        XCTAssertEqual(retryingSnapshot?.phase, .reconnecting(nextRetrySeconds: 5))
        XCTAssertEqual(siblingSnapshot?.phase, .running)

        let retryingStatus = try XCTUnwrap(try statusStore.status(streamID: retrying.id))
        let siblingStatus = try XCTUnwrap(try statusStore.status(streamID: sibling.id))
        XCTAssertEqual(retryingStatus.phase, .reconnecting)
        XCTAssertEqual(retryingStatus.attempt, 1)
        XCTAssertEqual(retryingStatus.maxAttempts, 1)
        XCTAssertEqual(retryingStatus.nextRetrySeconds, 5)
        XCTAssertNotNil(retryingStatus.nextRetryAt)
        XCTAssertEqual(siblingStatus.phase, .running)
        XCTAssertEqual(siblingStatus.attempt, 0)

        await retrySleep.releaseAll()
        let retryConnecting = try await nextEvent(from: &iterator)
        let retryRunning = try await nextEvent(from: &iterator)
        XCTAssertEqual(retryConnecting.phase, .connecting)
        XCTAssertEqual(retryRunning.phase, .running)
        let stopped = try await nextEvent(from: &iterator)
        XCTAssertEqual(stopped.streamID, retrying.id)
        XCTAssertEqual(stopped.phase, .stopped)
        let siblingAfterRetry = await runtime.snapshot(streamID: sibling.id)
        XCTAssertEqual(siblingAfterRetry?.phase, .running)

        await runtime.stop(streamID: sibling.id)
        await siblingGate.release()
    }

    func testMaximumReconnectAttemptsPublishesTerminalRedactedStatus() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Terminal HLS",
            streamType: "hls",
            source: "https://user:pass@example.test/terminal.m3u8?token=secret#frag"
        )
        let statusStore = AppStreamRuntimeStatusStore(database: temporary.database)
        let ingester = AlwaysFailingAppRuntimeIngester(
            message:
                "failed at /Users/example/private/output.raw for https://user:pass@example.test/terminal.m3u8?token=secret#frag api_key=secret"
        )
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: ingester,
            retryPolicy: AppStreamRuntimeRetryPolicy(
                maximumReconnectAttempts: 1, backoffSeconds: { _ in 0 }),
            statusStore: statusStore,
            retrySleep: { _ in }
        )
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        try await runtime.start(streamID: stream.id)
        let firstConnecting = try await nextEvent(from: &iterator)
        let firstRunning = try await nextEvent(from: &iterator)
        let reconnecting = try await nextEvent(from: &iterator)
        let secondConnecting = try await nextEvent(from: &iterator)
        let secondRunning = try await nextEvent(from: &iterator)
        XCTAssertEqual(firstConnecting.phase, .connecting)
        XCTAssertEqual(firstRunning.phase, .running)
        XCTAssertEqual(reconnecting.phase, .reconnecting(nextRetrySeconds: 0))
        XCTAssertEqual(secondConnecting.phase, .connecting)
        XCTAssertEqual(secondRunning.phase, .running)
        let terminal = try await nextEvent(from: &iterator)
        XCTAssertEqual(terminal.phase.statusPhase, .error)
        XCTAssertFalse(terminal.message.contains("user:pass"), terminal.message)
        XCTAssertFalse(terminal.message.contains("token=secret"), terminal.message)
        XCTAssertFalse(terminal.message.contains("api_key=secret"), terminal.message)
        XCTAssertFalse(terminal.message.contains("/Users/example"), terminal.message)
        XCTAssertTrue(terminal.message.contains("[redacted-path]"), terminal.message)

        let status = try XCTUnwrap(try statusStore.status(streamID: stream.id))
        XCTAssertEqual(status.phase, .error)
        XCTAssertEqual(status.attempt, 1)
        XCTAssertEqual(status.maxAttempts, 1)
        XCTAssertNil(status.nextRetrySeconds)
        let failure = try XCTUnwrap(status.recentFailure)
        XCTAssertFalse(failure.message.contains("user:pass"), failure.message)
        XCTAssertFalse(failure.message.contains("token=secret"), failure.message)
        XCTAssertFalse(failure.message.contains("api_key=secret"), failure.message)
        XCTAssertFalse(failure.message.contains("/Users/example"), failure.message)
        XCTAssertTrue(failure.message.contains("[redacted-path]"), failure.message)
    }

    func testStoppingStreamDuringRetryPreventsLaterRetryPublication() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Cancel HLS",
            streamType: "hls",
            source: "https://example.test/cancel.m3u8"
        )
        let statusStore = AppStreamRuntimeStatusStore(database: temporary.database)
        let retrySleep = RetrySleepGate()
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: AlwaysFailingAppRuntimeIngester(message: "temporary failure"),
            retryPolicy: AppStreamRuntimeRetryPolicy(
                maximumReconnectAttempts: 1, backoffSeconds: { _ in 30 }),
            statusStore: statusStore,
            retrySleep: { seconds in try await retrySleep.sleep(seconds: seconds) }
        )
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        try await runtime.start(streamID: stream.id)
        let connecting = try await nextEvent(from: &iterator)
        let running = try await nextEvent(from: &iterator)
        let reconnecting = try await nextEvent(from: &iterator)
        XCTAssertEqual(connecting.phase, .connecting)
        XCTAssertEqual(running.phase, .running)
        XCTAssertEqual(reconnecting.phase, .reconnecting(nextRetrySeconds: 30))

        await runtime.stop(streamID: stream.id)
        let stopped = try await nextEvent(from: &iterator)
        XCTAssertEqual(stopped.phase, .stopped)
        await retrySleep.releaseAll()
        try await Task.sleep(nanoseconds: 50_000_000)

        let stoppedSnapshot = await runtime.snapshot(streamID: stream.id)
        XCTAssertEqual(stoppedSnapshot?.phase, .stopped)
        XCTAssertEqual(try statusStore.status(streamID: stream.id)?.phase, .stopped)
    }

    func testOlderRunCannotOverwriteNewerRunForSameStream() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Restart HLS",
            streamType: "hls",
            source: "https://example.test/restart.m3u8"
        )
        let statusStore = AppStreamRuntimeStatusStore(database: temporary.database)
        let firstGate = RuntimeGate()
        let secondGate = RuntimeGate()
        let ingester = RestartingAppRuntimeIngester(firstGate: firstGate, secondGate: secondGate)
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: ingester,
            retryPolicy: .noRetry,
            statusStore: statusStore
        )
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        try await runtime.start(streamID: stream.id)
        let firstConnecting = try await nextEvent(from: &iterator)
        let firstRunning = try await nextEvent(from: &iterator)
        XCTAssertEqual(firstConnecting.phase, .connecting)
        XCTAssertEqual(firstRunning.phase, .running)
        try await runtime.start(streamID: stream.id)
        let restartStopped = try await nextEvent(from: &iterator)
        let secondConnecting = try await nextEvent(from: &iterator)
        let secondRunning = try await nextEvent(from: &iterator)
        XCTAssertEqual(restartStopped.phase, .stopped)
        XCTAssertEqual(secondConnecting.phase, .connecting)
        XCTAssertEqual(secondRunning.phase, .running)

        await firstGate.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        let runningSnapshot = await runtime.snapshot(streamID: stream.id)
        XCTAssertEqual(runningSnapshot?.phase, .running)
        XCTAssertEqual(try statusStore.status(streamID: stream.id)?.phase, .running)

        await secondGate.release()
        let stopped = try await nextEvent(from: &iterator)
        XCTAssertEqual(stopped.phase, .stopped)
    }

    func testSystemSleepSuspendsActiveStreamsAndWakeRecoversWithDeterministicLatency() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let first = try registry.add(name: "Sleep HLS", streamType: "hls", source: "https://user:pass@example.test/sleep.m3u8?token=secret#frag")
        let second = try registry.add(name: "Sleep ICY", streamType: "icy", source: "http://user:pass@example.test/live?api_key=secret")
        let statusStore = AppStreamRuntimeStatusStore(database: temporary.database)
        let gate = RuntimeGate()
        let ingester = LifecycleRecordingIngester(gate: gate)
        var dates = [Date(timeIntervalSince1970: 1_767_225_600), Date(timeIntervalSince1970: 1_767_225_605)]
        let runtime = AppStreamRuntimeService(registry: registry, ingester: ingester, retryPolicy: .noRetry, statusStore: statusStore, now: { dates.isEmpty ? Date(timeIntervalSince1970: 1_767_225_605) : dates.removeFirst() })
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        try await runtime.start(streamID: first.id)
        XCTAssertEqual(try await nextEvent(from: &iterator).phase, .connecting)
        XCTAssertEqual(try await nextEvent(from: &iterator).phase, .running)
        try await runtime.start(streamID: second.id)
        XCTAssertEqual(try await nextEvent(from: &iterator).phase, .connecting)
        XCTAssertEqual(try await nextEvent(from: &iterator).phase, .running)

        await runtime.suspendForSystemSleep(reason: "sleep for https://user:pass@example.test/private?token=secret at /Users/example/private")
        let firstSuspended = try await nextEvent(from: &iterator)
        let secondSuspended = try await nextEvent(from: &iterator)
        XCTAssertEqual(firstSuspended.phase, .suspended)
        XCTAssertEqual(secondSuspended.phase, .suspended)
        XCTAssertFalse(firstSuspended.message.contains("user:pass"), firstSuspended.message)
        XCTAssertFalse(firstSuspended.message.contains("token=secret"), firstSuspended.message)
        XCTAssertFalse(firstSuspended.message.contains("/Users/example"), firstSuspended.message)
        XCTAssertNil(firstSuspended.lifecycleEvidence?.recoveryLatencySeconds)
        XCTAssertEqual(try statusStore.status(streamID: first.id)?.phase, .suspended)

        await gate.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual((await runtime.snapshot(streamID: first.id))?.phase, .suspended)
        XCTAssertEqual((await runtime.snapshot(streamID: second.id))?.phase, .suspended)

        await runtime.recoverFromSystemWake(reason: "wake token=secret from /Users/example/private")
        let firstRecovering = try await nextEvent(matching: { $0.streamID == first.id && $0.phase == .recovering }, from: &iterator)
        XCTAssertEqual(firstRecovering.lifecycleEvidence?.recoveryLatencySeconds, 5)
        XCTAssertFalse(firstRecovering.message.contains("token=secret"), firstRecovering.message)
        XCTAssertFalse(firstRecovering.lifecycleEvidence?.reason.contains("token=secret") ?? true)
        _ = try await nextEvent(matching: { $0.streamID == first.id && $0.phase == .connecting }, from: &iterator)
        _ = try await nextEvent(matching: { $0.streamID == second.id && $0.phase == .recovering }, from: &iterator)
        _ = try await nextEvent(matching: { $0.streamID == second.id && $0.phase == .connecting }, from: &iterator)
        _ = try await nextEvent(matching: { $0.streamID == first.id && $0.phase == .running }, from: &iterator)
        _ = try await nextEvent(matching: { $0.streamID == second.id && $0.phase == .running }, from: &iterator)
        XCTAssertEqual(try statusStore.status(streamID: first.id)?.phase, .running)
        XCTAssertEqual(try statusStore.status(streamID: second.id)?.phase, .running)
        XCTAssertEqual(await ingester.requestStreamIDs(), [first.id, second.id, first.id, second.id])
    }

    func testWakeRecoveryFailureIsRedactedAndDoesNotBlockSibling() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let removed = try registry.add(name: "Removed HLS", streamType: "hls", source: "https://user:pass@example.test/removed.m3u8?token=secret")
        let sibling = try registry.add(name: "Sibling ICY", streamType: "icy", source: "http://user:pass@example.test/live?token=sibling")
        let gate = RuntimeGate()
        let runtime = AppStreamRuntimeService(registry: registry, ingester: LifecycleRecordingIngester(gate: gate), retryPolicy: .noRetry, now: { Date(timeIntervalSince1970: 1_767_225_600) })
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        try await runtime.start(streamID: removed.id)
        _ = try await nextEvent(from: &iterator)
        _ = try await nextEvent(from: &iterator)
        try await runtime.start(streamID: sibling.id)
        _ = try await nextEvent(from: &iterator)
        _ = try await nextEvent(from: &iterator)
        await runtime.suspendForSystemSleep(reason: "sleep token=secret")
        _ = try await nextEvent(from: &iterator)
        _ = try await nextEvent(from: &iterator)
        _ = try registry.remove(id: removed.id)

        await runtime.recoverFromSystemWake(reason: "wake token=secret")
        let failure = try await nextEvent(matching: { $0.streamID == removed.id && $0.phase.statusPhase == .error }, from: &iterator)
        XCTAssertFalse(failure.message.contains("token=secret"), failure.message)
        _ = try await nextEvent(matching: { $0.streamID == sibling.id && $0.phase == .running }, from: &iterator)
        XCTAssertEqual((await runtime.snapshot(streamID: sibling.id))?.phase, .running)

        await gate.release()
    }

    func testSuspendWithNoActiveStreamsAndRepeatedWakeAreNoOps() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(name: "Noop HLS", streamType: "hls", source: "https://example.test/noop.m3u8")
        let gate = RuntimeGate()
        let ingester = LifecycleRecordingIngester(gate: gate)
        let runtime = AppStreamRuntimeService(registry: registry, ingester: ingester, retryPolicy: .noRetry)

        await runtime.suspendForSystemSleep(reason: "sleep with no active streams")
        await runtime.recoverFromSystemWake(reason: "wake with no capture")
        XCTAssertNil(await runtime.snapshot())

        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()
        try await runtime.start(streamID: stream.id)
        _ = try await nextEvent(from: &iterator)
        _ = try await nextEvent(from: &iterator)
        await runtime.suspendForSystemSleep(reason: "sleep")
        _ = try await nextEvent(from: &iterator)
        await runtime.recoverFromSystemWake(reason: "wake")
        _ = try await nextEvent(matching: { $0.phase == .running }, from: &iterator)
        let afterFirstWake = await ingester.requestStreamIDs().count
        await runtime.recoverFromSystemWake(reason: "repeated wake")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(await ingester.requestStreamIDs().count, afterFirstWake)

        await gate.release()
    }

    func testSeekToBufferedSecondPublishesPlayerTimelineEvent() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Buffered HLS",
            streamType: "hls",
            source: "https://user:pass@example.test/buffered.m3u8?token=secret"
        )
        let gate = RuntimeGate()
        let rollingBuffer = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: 120,
                hotMemoryDurationSeconds: 120,
                maximumSpillBytes: 0
            )
        )
        await rollingBuffer.start(streamID: stream.id)
        _ = await rollingBuffer.append([
            SharedPCMFrame(
                streamID: stream.id,
                sequence: 0,
                audio: Data([0x01]),
                startSeconds: 0,
                endSeconds: 10
            ),
            SharedPCMFrame(
                streamID: stream.id,
                sequence: 1,
                audio: Data([0x02]),
                startSeconds: 10,
                endSeconds: 20
            ),
        ])
        let timeline = AppPlayerTimelineClock()
        await timeline.reset(streamID: stream.id)
        await timeline.updateRollingBuffer(await rollingBuffer.snapshot())
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: BlockingAppRuntimeIngester(gate: gate),
            retryPolicy: .noRetry,
            playbackTimeline: timeline,
            rollingBuffer: rollingBuffer
        )
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        try await runtime.start(streamID: stream.id)
        _ = try await nextEvent(from: &iterator)
        _ = try await nextEvent(from: &iterator)

        await runtime.seek(to: 10)

        let seeked = try await nextEvent(from: &iterator)
        XCTAssertEqual(seeked.phase, .running)
        XCTAssertEqual(seeked.result?.streamID, stream.id)
        let snapshot = try XCTUnwrap(seeked.result?.playerTimeline)
        XCTAssertEqual(snapshot.streamID, stream.id)
        XCTAssertEqual(snapshot.state, .playing)
        XCTAssertEqual(snapshot.positionSeconds, 10)
        XCTAssertEqual(snapshot.liveEdgeSeconds, 20)
        XCTAssertEqual(snapshot.bufferedStartSeconds, 0)
        XCTAssertEqual(snapshot.bufferedEndSeconds, 20)
        XCTAssertNil(snapshot.unavailableRangeMessage)
        XCTAssertEqual(snapshot.lastMessage, "Playback seeked to buffered frame 1.")

        await runtime.stop()
        await gate.release()
    }

    func testSeekRejectsNegativeTargetAsUnavailableWithoutMovingPlayback() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Buffered HLS",
            streamType: "hls",
            source: "https://user:pass@example.test/buffered.m3u8?token=secret"
        )
        let gate = RuntimeGate()
        let rollingBuffer = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: 120,
                hotMemoryDurationSeconds: 120,
                maximumSpillBytes: 0
            )
        )
        await rollingBuffer.start(streamID: stream.id)
        _ = await rollingBuffer.append([
            SharedPCMFrame(
                streamID: stream.id,
                sequence: 0,
                audio: Data([0x01]),
                startSeconds: 0,
                endSeconds: 10
            )
        ])
        let timeline = AppPlayerTimelineClock()
        await timeline.reset(streamID: stream.id)
        await timeline.updateRollingBuffer(await rollingBuffer.snapshot())
        await timeline.updatePlayerState(
            .playing,
            positionSeconds: 5,
            message: "Playback already inside buffered range."
        )
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: BlockingAppRuntimeIngester(gate: gate),
            retryPolicy: .noRetry,
            playbackTimeline: timeline,
            rollingBuffer: rollingBuffer
        )
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        try await runtime.start(streamID: stream.id)
        _ = try await nextEvent(from: &iterator)
        _ = try await nextEvent(from: &iterator)

        await runtime.seek(to: -1)

        let rejected = try await nextEvent(from: &iterator)
        let snapshot = try XCTUnwrap(rejected.result?.playerTimeline)
        XCTAssertEqual(snapshot.positionSeconds, 5)
        XCTAssertEqual(snapshot.state, .playing)
        XCTAssertEqual(snapshot.bufferedStartSeconds, 0)
        XCTAssertEqual(snapshot.bufferedEndSeconds, 10)
        XCTAssertEqual(
            snapshot.unavailableRangeMessage,
            "Requested -1.0s is unavailable (available range 0.0-10.0s)."
        )
        XCTAssertEqual(snapshot.lastMessage, snapshot.unavailableRangeMessage)
        XCTAssertFalse(rejected.message.contains("user:pass"), rejected.message)
        XCTAssertFalse(rejected.message.contains("token=secret"), rejected.message)

        await runtime.stop()
        await gate.release()
    }

    func testSeekOutsideBufferedRangePublishesUnavailableTimelineFeedback() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Buffered HLS",
            streamType: "hls",
            source: "https://user:pass@example.test/buffered.m3u8?token=secret"
        )
        let gate = RuntimeGate()
        let rollingBuffer = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: 120,
                hotMemoryDurationSeconds: 120,
                maximumSpillBytes: 0
            )
        )
        await rollingBuffer.start(streamID: stream.id)
        _ = await rollingBuffer.append([
            SharedPCMFrame(
                streamID: stream.id,
                sequence: 0,
                audio: Data([0x01]),
                startSeconds: 0,
                endSeconds: 10
            )
        ])
        let timeline = AppPlayerTimelineClock()
        await timeline.reset(streamID: stream.id)
        await timeline.updateRollingBuffer(await rollingBuffer.snapshot())
        await timeline.updatePlayerState(
            .playing, positionSeconds: 4, message: "Playing buffered audio.")
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: BlockingAppRuntimeIngester(gate: gate),
            retryPolicy: .noRetry,
            playbackTimeline: timeline,
            rollingBuffer: rollingBuffer
        )
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        try await runtime.start(streamID: stream.id)
        _ = try await nextEvent(from: &iterator)
        _ = try await nextEvent(from: &iterator)

        await runtime.seek(to: 42)

        let unavailable = try await nextEvent(from: &iterator)
        let snapshot = try XCTUnwrap(unavailable.result?.playerTimeline)
        XCTAssertEqual(snapshot.positionSeconds, 4)
        XCTAssertEqual(snapshot.state, .playing)
        XCTAssertEqual(
            snapshot.unavailableRangeMessage,
            "Requested 42.0s is unavailable (available range 0.0-10.0s)."
        )
        XCTAssertEqual(unavailable.message, snapshot.unavailableRangeMessage)
        XCTAssertFalse(unavailable.message.contains("user:pass"), unavailable.message)
        XCTAssertFalse(unavailable.message.contains("token=secret"), unavailable.message)

        await runtime.stop()
        await gate.release()
    }

    func testSeekWithoutCurrentStreamIsNoOp() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let rollingBuffer = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(maximumSpillBytes: 0)
        )
        await rollingBuffer.start(streamID: 999)
        _ = await rollingBuffer.append([
            SharedPCMFrame(
                streamID: 999,
                sequence: 0,
                audio: Data([0x01]),
                startSeconds: 0,
                endSeconds: 10
            )
        ])
        let timeline = AppPlayerTimelineClock()
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: RecordingAppRuntimeIngester(result: AppStreamRuntimeResult(streamID: 999)),
            retryPolicy: .noRetry,
            playbackTimeline: timeline,
            rollingBuffer: rollingBuffer
        )

        await runtime.seek(to: 5)

        let runtimeSnapshot = await runtime.snapshot()
        let timelineSnapshot = await timeline.snapshot()
        XCTAssertNil(runtimeSnapshot)
        XCTAssertEqual(timelineSnapshot, AppPlayerTimelineSnapshot())
    }

    func testSeekRejectsNonFiniteTargetsAsUnavailableWithoutMovingPlayback() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Buffered HLS",
            streamType: "hls",
            source: "https://user:pass@example.test/buffered.m3u8?token=secret"
        )
        let gate = RuntimeGate()
        let rollingBuffer = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: 120,
                hotMemoryDurationSeconds: 120,
                maximumSpillBytes: 0
            )
        )
        await rollingBuffer.start(streamID: stream.id)
        _ = await rollingBuffer.append([
            SharedPCMFrame(
                streamID: stream.id,
                sequence: 0,
                audio: Data([0x01]),
                startSeconds: 0,
                endSeconds: 10
            )
        ])
        let timeline = AppPlayerTimelineClock()
        await timeline.reset(streamID: stream.id)
        await timeline.updateRollingBuffer(await rollingBuffer.snapshot())
        await timeline.updatePlayerState(
            .playing, positionSeconds: 3, message: "Playing buffered audio.")
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: BlockingAppRuntimeIngester(gate: gate),
            retryPolicy: .noRetry,
            playbackTimeline: timeline,
            rollingBuffer: rollingBuffer
        )
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        try await runtime.start(streamID: stream.id)
        _ = try await nextEvent(from: &iterator)
        _ = try await nextEvent(from: &iterator)

        for target in [Double.nan, Double.infinity] {
            await runtime.seek(to: target)
            let rejected = try await nextEvent(from: &iterator)
            let snapshot = try XCTUnwrap(rejected.result?.playerTimeline)
            XCTAssertEqual(snapshot.positionSeconds, 3)
            XCTAssertEqual(snapshot.state, .playing)
            XCTAssertNotNil(snapshot.unavailableRangeMessage)
            XCTAssertTrue(snapshot.lastMessage.contains("unavailable"), snapshot.lastMessage)
            XCTAssertFalse(rejected.message.contains("user:pass"), rejected.message)
            XCTAssertFalse(rejected.message.contains("token=secret"), rejected.message)
        }

        await runtime.stop()
        await gate.release()
    }

    func testSeekSupportsBufferedStartEndLiveEdgeAndZeroBoundaries() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Boundary HLS",
            streamType: "hls",
            source: "https://example.test/boundary.m3u8"
        )
        let gate = RuntimeGate()
        let rollingBuffer = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: 120,
                hotMemoryDurationSeconds: 120,
                maximumSpillBytes: 0
            )
        )
        await rollingBuffer.start(streamID: stream.id)
        _ = await rollingBuffer.append([
            SharedPCMFrame(
                streamID: stream.id,
                sequence: 0,
                audio: Data([0x01]),
                startSeconds: 0,
                endSeconds: 10
            ),
            SharedPCMFrame(
                streamID: stream.id,
                sequence: 1,
                audio: Data([0x02]),
                startSeconds: 10,
                endSeconds: 20
            ),
        ])
        let timeline = AppPlayerTimelineClock()
        await timeline.reset(streamID: stream.id)
        await timeline.updateRollingBuffer(await rollingBuffer.snapshot())
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: BlockingAppRuntimeIngester(gate: gate),
            retryPolicy: .noRetry,
            playbackTimeline: timeline,
            rollingBuffer: rollingBuffer
        )
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        try await runtime.start(streamID: stream.id)
        _ = try await nextEvent(from: &iterator)
        _ = try await nextEvent(from: &iterator)

        await runtime.seek(to: 0)
        let zero = try await nextEvent(from: &iterator)
        XCTAssertEqual(zero.result?.playerTimeline?.positionSeconds, 0)
        XCTAssertNil(zero.result?.playerTimeline?.unavailableRangeMessage)

        await runtime.seek(to: 20)
        let liveEdge = try await nextEvent(from: &iterator)
        let liveSnapshot = try XCTUnwrap(liveEdge.result?.playerTimeline)
        XCTAssertEqual(liveSnapshot.positionSeconds, 10)
        XCTAssertEqual(liveSnapshot.liveEdgeSeconds, 20)
        XCTAssertNil(liveSnapshot.unavailableRangeMessage)
        XCTAssertEqual(liveSnapshot.lastMessage, "Playback seeked to buffered frame 1.")

        await runtime.stop()
        await gate.release()
    }

    func testSeekWithoutRollingBufferLeavesCurrentRuntimeEventUnchanged() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "No Buffer HLS",
            streamType: "hls",
            source: "https://example.test/no-buffer.m3u8"
        )
        let gate = RuntimeGate()
        let timeline = AppPlayerTimelineClock()
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: BlockingAppRuntimeIngester(gate: gate),
            retryPolicy: .noRetry,
            playbackTimeline: timeline,
            rollingBuffer: nil
        )
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        try await runtime.start(streamID: stream.id)
        _ = try await nextEvent(from: &iterator)
        let running = try await nextEvent(from: &iterator)

        await runtime.seek(to: 5)

        let latest = await runtime.snapshot()
        XCTAssertEqual(latest, running)
        XCTAssertNil(latest?.result?.playerTimeline)

        await runtime.stop()
        await gate.release()
    }

    func testPipelineRunnerUsesExistingManagedStreamAndTemporarySQLite() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Pipeline HLS",
            streamType: "hls",
            source: "https://user:pass@example.test/pipeline.m3u8?token=secret"
        )
        let runner = StreamIngestAppRuntimeRunner(
            database: temporary.database,
            decoder: FixtureDecoder(),
            transcriber: FixtureTranscriber(),
            diarizer: FixtureDiarizer(),
            now: { "2026-05-01T00:00:00Z" }
        )
        let request = AppStreamRuntimeRequest(
            streamID: stream.id,
            name: stream.name,
            source: "https://user:pass@example.test/pipeline.m3u8?token=secret",
            sourceDescription: stream.sourceDescription,
            streamType: .hls
        )

        let result = try await runner.run(request)

        XCTAssertEqual(result.streamID, stream.id)
        XCTAssertEqual(result.processedChunks, 1)
        XCTAssertEqual(result.diagnosticCount, 0)
        let rows = try temporary.database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT streams.source AS source, streams.source_url AS source_url,
                           ingest_runs.status AS status, COUNT(ingest_chunks.id) AS chunk_count
                    FROM streams
                    JOIN ingest_runs ON ingest_runs.stream_id = streams.id
                    JOIN ingest_chunks ON ingest_chunks.run_id = ingest_runs.id
                    WHERE streams.id = ?
                    GROUP BY streams.id, ingest_runs.id
                    """,
                arguments: [stream.id]
            )
        }
        XCTAssertEqual(rows?["source"] as String?, "https://example.test/pipeline.m3u8")
        XCTAssertEqual(
            rows?["source_url"] as String?,
            "https://user:pass@example.test/pipeline.m3u8?token=secret")
        XCTAssertEqual(rows?["status"] as String?, "completed")
        XCTAssertEqual(rows?["chunk_count"] as Int?, 1)
    }

    func testRuntimeFactoryBuildsDefaultStartupStateWithConfiguredModelBufferAndNonBlockingAcoustID() throws {
        let directory = try makeRuntimeFactoryTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = SoundingAppPreferences(
            databaseURL: directory.appendingPathComponent("Sounding.sqlite"),
            acoustIDKeyStatus: .missing
        )
        let recorder = RuntimeFactoryRecorder()
        let factory = SoundingAppRuntimeFactory(
            ingesterFactory: { _, configuration, _, _ in
                recorder.recordIngesterConfiguration(configuration)
                return RecordingAppRuntimeIngester(result: AppStreamRuntimeResult(streamID: 1))
            },
            runtimeFactory: { registry, ingester, timeline, rollingBuffer, _ in
                recorder.recordRuntimeConstructed()
                return AppStreamRuntimeService(
                    registry: registry,
                    ingester: ingester,
                    retryPolicy: .noRetry,
                    playbackTimeline: timeline,
                    rollingBuffer: rollingBuffer
                )
            }
        )

        let state = factory.makeStartupState(preferences: preferences)

        XCTAssertNotNil(state.registry)
        XCTAssertNotNil(state.runtime)
        XCTAssertNotNil(state.timelineStore)
        XCTAssertNotNil(state.searchStore)
        XCTAssertNil(state.persistenceError)
        XCTAssertEqual(recorder.ingesterConfigurations.count, 1)
        XCTAssertEqual(recorder.ingesterConfigurations[0].whisperModelName, "tiny")
        XCTAssertEqual(
            recorder.ingesterConfigurations[0].rollingBuffer.targetDurationSeconds,
            RollingBufferConfiguration.appDefault().targetDurationSeconds
        )
        XCTAssertTrue(recorder.runtimeConstructed)
        XCTAssertEqual(state.configuration.issues.map(\.id), ["acoustid.key-missing"])
        XCTAssertFalse(state.configuration.hasBlockingIssues)
    }

    func testRuntimeFactoryDatabaseOpenFailureShortCircuitsBeforeIngesterAndRedactsIssue() throws {
        let directory = try makeRuntimeFactoryTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("Sounding.sqlite")
        let recorder = RuntimeFactoryRecorder()
        let rawPath = directory.appendingPathComponent("private.sqlite").path
        let factory = SoundingAppRuntimeFactory(
            databaseFactory: { _ in
                recorder.recordDatabaseOpen()
                throw RuntimeFailure(
                    message: "open failed at \(rawPath) for https://user:pass@example.test/db?token=secret#frag"
                )
            },
            ingesterFactory: { _, configuration, _, _ in
                recorder.recordIngesterConfiguration(configuration)
                return RecordingAppRuntimeIngester(result: AppStreamRuntimeResult(streamID: 1))
            }
        )

        let state = factory.makeStartupState(
            preferences: SoundingAppPreferences(databaseURL: databaseURL, acoustIDKeyStatus: .present)
        )

        XCTAssertEqual(recorder.databaseOpenCount, 1)
        XCTAssertTrue(recorder.ingesterConfigurations.isEmpty)
        XCTAssertNil(state.registry)
        XCTAssertNil(state.runtime)
        let issue = try XCTUnwrap(state.configuration.issues.first { $0.id == "database.open-failed" })
        XCTAssertEqual(issue.action.kind, .chooseDatabaseLocation)
        XCTAssertEqual(issue.phase, .startup)
        XCTAssertTrue(issue.blocksRuntime)
        XCTAssertFalse(issue.detail?.contains(rawPath) ?? true, issue.detail ?? "")
        XCTAssertFalse(issue.detail?.contains("user:pass") ?? true, issue.detail ?? "")
        XCTAssertFalse(issue.detail?.contains("token=secret") ?? true, issue.detail ?? "")
    }

    func testRuntimeFactoryInvalidModelBlocksBeforeDatabaseAndDependencyConstruction() throws {
        let directory = try makeRuntimeFactoryTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawModel = "/Users/example/private-model?api_key=secret"
        let recorder = RuntimeFactoryRecorder()
        let factory = SoundingAppRuntimeFactory(
            databaseFactory: { url in
                recorder.recordDatabaseOpen()
                return try SoundingDatabase(fileURL: url)
            },
            ingesterFactory: { _, configuration, _, _ in
                recorder.recordIngesterConfiguration(configuration)
                return RecordingAppRuntimeIngester(result: AppStreamRuntimeResult(streamID: 1))
            }
        )

        let state = factory.makeStartupState(
            preferences: SoundingAppPreferences(
                databaseURL: directory.appendingPathComponent("Sounding.sqlite"),
                whisperModelName: rawModel,
                acoustIDKeyStatus: .present
            )
        )

        XCTAssertEqual(recorder.databaseOpenCount, 0)
        XCTAssertTrue(recorder.ingesterConfigurations.isEmpty)
        XCTAssertNil(state.registry)
        XCTAssertNil(state.runtime)
        let issue = try XCTUnwrap(state.configuration.issues.first { $0.category == .model })
        XCTAssertEqual(issue.id, "model.invalid-name")
        XCTAssertEqual(issue.action.kind, .chooseWhisperModel)
        XCTAssertFalse(String(describing: issue).contains(rawModel))
        XCTAssertFalse(String(describing: issue).contains("api_key=secret"))
        XCTAssertFalse(String(describing: issue).contains("/Users/example"))
    }

    func testRuntimeFactoryDependencyFailureKeepsStoresButDoesNotStartRuntime() throws {
        let directory = try makeRuntimeFactoryTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawPath = directory.appendingPathComponent("cache/private-model").path
        let factory = SoundingAppRuntimeFactory(
            ingesterFactory: { _, _, _, _ in
                throw ModelCacheError.setupFailed(
                    provider: "whisperkit",
                    model: "tiny",
                    reason: "cache unavailable at \(rawPath)"
                )
            }
        )

        let state = factory.makeStartupState(
            preferences: SoundingAppPreferences(
                databaseURL: directory.appendingPathComponent("Sounding.sqlite"),
                acoustIDKeyStatus: .present
            )
        )

        XCTAssertNotNil(state.registry)
        XCTAssertNotNil(state.timelineStore)
        XCTAssertNotNil(state.searchStore)
        XCTAssertNil(state.runtime)
        let issue = try XCTUnwrap(state.configuration.issues.first { $0.id == "model.setup-failed" })
        XCTAssertEqual(issue.phase, .startup)
        XCTAssertEqual(issue.action.kind, .chooseWhisperModel)
        XCTAssertTrue(issue.blocksRuntime)
        XCTAssertFalse(issue.detail?.contains(rawPath) ?? true, issue.detail ?? "")
        XCTAssertTrue(issue.detail?.contains("[redacted-path]") ?? false, issue.detail ?? "")
    }

    func testRuntimeFactoryCapsHugeBufferBeforeRollingBufferConstruction() throws {
        let directory = try makeRuntimeFactoryTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = RuntimeFactoryRecorder()
        let factory = SoundingAppRuntimeFactory(
            ingesterFactory: { _, configuration, _, _ in
                recorder.recordIngesterConfiguration(configuration)
                return RecordingAppRuntimeIngester(result: AppStreamRuntimeResult(streamID: 1))
            }
        )

        let state = factory.makeStartupState(
            preferences: SoundingAppPreferences(
                databaseURL: directory.appendingPathComponent("Sounding.sqlite"),
                rollingBufferTargetSeconds: SoundingAppConfiguration.maximumRollingBufferSeconds * 100,
                acoustIDKeyStatus: .present
            )
        )

        XCTAssertNotNil(state.runtime)
        XCTAssertEqual(recorder.ingesterConfigurations.count, 1)
        XCTAssertEqual(
            recorder.ingesterConfigurations[0].rollingBuffer.targetDurationSeconds,
            SoundingAppConfiguration.maximumRollingBufferSeconds
        )
        XCTAssertEqual(state.configuration.issues.map(\.id), ["rolling-buffer.too-large"])
        XCTAssertFalse(state.configuration.hasBlockingIssues)
    }

    private func nextEvent(
        from iterator: inout AsyncStream<AppStreamRuntimeEvent>.Iterator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> AppStreamRuntimeEvent {
        guard let event = await iterator.next() else {
            throw RuntimeTestError.missingEvent
        }
        return event
    }

    private func nextEvent(
        matching predicate: (AppStreamRuntimeEvent) -> Bool,
        from iterator: inout AsyncStream<AppStreamRuntimeEvent>.Iterator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> AppStreamRuntimeEvent {
        for _ in 0..<10 {
            let event = try await nextEvent(from: &iterator, file: file, line: line)
            if predicate(event) { return event }
        }
        throw RuntimeTestError.missingEvent
    }
}

private enum RuntimeTestError: Error {
    case missingEvent
}

private actor RecordingAppRuntimeIngester: AppStreamRuntimeIngesting {
    private let result: AppStreamRuntimeResult
    private var recorded: [AppStreamRuntimeRequest] = []

    init(result: AppStreamRuntimeResult) {
        self.result = result
    }

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        recorded.append(request)
        return result
    }

    func requests() -> [AppStreamRuntimeRequest] {
        recorded
    }
}

private actor RuntimeGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private struct BlockingAppRuntimeIngester: AppStreamRuntimeIngesting {
    let gate: RuntimeGate

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        await gate.wait()
        try Task.checkCancellation()
        return AppStreamRuntimeResult(streamID: request.streamID)
    }
}

private actor RetrySleepGate {
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func sleep(seconds: Int) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(continuation)
            }
        } onCancel: {
            Task { await self.releaseAll() }
        }
        try Task.checkCancellation()
    }

    func releaseAll() {
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private actor PerStreamRuntimeIngester: AppStreamRuntimeIngesting {
    private let flakyStreamID: Int64
    private let blockingStreamID: Int64
    private let blockingGate: RuntimeGate
    private var flakyCalls = 0

    init(flakyStreamID: Int64, blockingStreamID: Int64, blockingGate: RuntimeGate) {
        self.flakyStreamID = flakyStreamID
        self.blockingStreamID = blockingStreamID
        self.blockingGate = blockingGate
    }

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        if request.streamID == flakyStreamID {
            flakyCalls += 1
            if flakyCalls == 1 {
                throw RuntimeFailure(
                    message:
                        "decode failed at /tmp/token=secret.raw for https://user:pass@example.test/retry.m3u8?token=secret"
                )
            }
            return AppStreamRuntimeResult(streamID: request.streamID, processedChunks: 1)
        }
        if request.streamID == blockingStreamID {
            await blockingGate.wait()
            try Task.checkCancellation()
            return AppStreamRuntimeResult(streamID: request.streamID)
        }
        return AppStreamRuntimeResult(streamID: request.streamID)
    }
}

private actor AlwaysFailingAppRuntimeIngester: AppStreamRuntimeIngesting {
    private let message: String

    init(message: String) {
        self.message = message
    }

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        throw RuntimeFailure(message: message)
    }
}

private actor RestartingAppRuntimeIngester: AppStreamRuntimeIngesting {
    private let firstGate: RuntimeGate
    private let secondGate: RuntimeGate
    private var calls = 0

    init(firstGate: RuntimeGate, secondGate: RuntimeGate) {
        self.firstGate = firstGate
        self.secondGate = secondGate
    }

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        calls += 1
        if calls == 1 {
            await firstGate.wait()
        } else {
            await secondGate.wait()
        }
        try Task.checkCancellation()
        return AppStreamRuntimeResult(streamID: request.streamID, processedChunks: calls)
    }
}

private actor FlakyAppRuntimeIngester: AppStreamRuntimeIngesting {
    private let streamID: Int64
    private var calls = 0

    init(streamID: Int64) {
        self.streamID = streamID
    }

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        calls += 1
        if calls == 1 {
            throw RuntimeFailure(
                message:
                    "decode failed at /tmp/token=secret.raw for https://user:pass@example.test/retry.m3u8?token=secret"
            )
        }
        return AppStreamRuntimeResult(streamID: streamID, processedChunks: 1)
    }

    func callCount() -> Int { calls }
}

private func makeRuntimeFactoryTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SoundingAppRuntimeFactoryTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class RuntimeFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _databaseOpenCount = 0
    private var _ingesterConfigurations: [SoundingAppConfiguration] = []
    private var _runtimeConstructed = false

    var databaseOpenCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _databaseOpenCount
    }

    var ingesterConfigurations: [SoundingAppConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return _ingesterConfigurations
    }

    var runtimeConstructed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _runtimeConstructed
    }

    func recordDatabaseOpen() {
        lock.lock()
        defer { lock.unlock() }
        _databaseOpenCount += 1
    }

    func recordIngesterConfiguration(_ configuration: SoundingAppConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        _ingesterConfigurations.append(configuration)
    }

    func recordRuntimeConstructed() {
        lock.lock()
        defer { lock.unlock() }
        _runtimeConstructed = true
    }
}

private struct RuntimeFailure: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

private struct FixtureDecoder: AudioDecoding {
    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        XCTAssertNil(request.durationSeconds)
        XCTAssertNil(request.maxChunks)
        return [
            DecodedAudioChunk(
                sequence: 0,
                segmentURI: "https://user:pass@example.test/pipeline-0.ts?token=secret",
                audio: Data([0x01, 0x02, 0x03]),
                startSeconds: 0,
                endSeconds: 1,
                startedAt: "2026-05-01T00:00:00Z",
                endedAt: "2026-05-01T00:00:01Z"
            )
        ]
    }
}

private struct FixtureTranscriber: MLTranscription {
    func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
        [
            TranscriptSegmentDraft(
                sequence: 0,
                speakerLabel: "fixture-speaker",
                startSeconds: chunk.startSeconds,
                endSeconds: chunk.endSeconds,
                text: "fixture transcript",
                confidence: 0.9,
                words: [
                    TranscriptWordDraft(
                        sequence: 0,
                        speakerLabel: "fixture-speaker",
                        startSeconds: chunk.startSeconds,
                        endSeconds: chunk.endSeconds,
                        text: "fixture",
                        confidence: 0.9
                    )
                ]
            )
        ]
    }
}

private struct FixtureDiarizer: SpeakerDiarization {
    func diarize(
        _ chunk: DecodedAudioChunk,
        transcriptSegments: [TranscriptSegmentDraft]
    ) async throws -> [SpeakerTurnDraft] {
        transcriptSegments.map { segment in
            SpeakerTurnDraft(
                speakerLabel: segment.speakerLabel ?? "fixture-speaker",
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                confidence: 0.8
            )
        }
    }
}
