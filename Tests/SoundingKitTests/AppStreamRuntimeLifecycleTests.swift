import Foundation
import GRDB
import XCTest

@testable import SoundingKit

final class AppStreamRuntimeLifecycleTests: AppStreamRuntimeTestCase {
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
        XCTAssertFalse(requests[0].isDiarizationEnabled)
    }

    func testStartPassesPerStreamDiarizationSettingToRuntimeRequest() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Fixture HLS",
            streamType: "hls",
            source: "https://example.test/live.m3u8"
        )
        _ = try registry.setDiarizationEnabled(id: stream.id, isEnabled: true)
        let ingester = RecordingAppRuntimeIngester(
            result: AppStreamRuntimeResult(streamID: stream.id, runID: 7)
        )
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: ingester,
            retryPolicy: .noRetry
        )
        try await runtime.start(streamID: stream.id)

        for _ in 0..<20 {
            if let request = await ingester.requests().first {
                XCTAssertTrue(request.isDiarizationEnabled)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected runtime start to invoke ingester")
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
        let player = RecordingRuntimePlaybackAdapter()
        let timeline = AppPlayerTimelineClock()
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: BlockingAppRuntimeIngester(gate: gate),
            retryPolicy: .noRetry,
            playbackTimeline: timeline,
            playbackController: player
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
        let playbackActions = await player.actions()
        XCTAssertEqual(playbackActions, ["pause", "resume", "stop"])

        await gate.release()
    }

    func testStopPublishesStoppedAfterPlaybackStopCompletes() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Fixture HLS",
            streamType: "hls",
            source: "https://example.test/live.m3u8"
        )
        let ingesterGate = RuntimeGate()
        let stopGate = RuntimeStopGate()
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: BlockingAppRuntimeIngester(gate: ingesterGate),
            retryPolicy: .noRetry,
            playbackTimeline: AppPlayerTimelineClock(),
            playbackController: GatedStopRuntimePlaybackAdapter(gate: stopGate),
            playbackStopTimeoutNanoseconds: 1_000_000
        )
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        try await runtime.start(streamID: stream.id)
        _ = try await nextEvent(matching: { $0.phase == .running }, from: &iterator)
        let stopTask = Task {
            await runtime.stop(streamID: stream.id)
        }
        await stopGate.waitForStopCallCount(1)
        await stopGate.release()
        await stopTask.value

        let stopped = try await nextEvent(matching: { $0.phase == .stopped }, from: &iterator)
        XCTAssertEqual(stopped.streamID, stream.id)
        let stopCallCount = await stopGate.callCount()
        XCTAssertEqual(stopCallCount, 1)

        await stopGate.release()
        await ingesterGate.release()
    }

    func testRestartingRunningStreamClearsPlaybackBeforeReplacement() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Fixture HLS",
            streamType: "hls",
            source: "https://example.test/live.m3u8"
        )
        let ingesterGate = RuntimeGate()
        let ingester = RecordingBlockingAppRuntimeIngester(gate: ingesterGate)
        let player = RecordingRuntimePlaybackAdapter()
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: ingester,
            retryPolicy: .noRetry,
            playbackTimeline: AppPlayerTimelineClock(),
            playbackController: player
        )

        try await runtime.start(streamID: stream.id)
        for _ in 0..<20 {
            if await ingester.callCount() >= 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let secondStart = Task { try await runtime.restart(streamID: stream.id) }

        try await secondStart.value

        for _ in 0..<20 {
            if await ingester.callCount() >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let ingesterCallCount = await ingester.callCount()
        let playbackActions = await player.actions()
        XCTAssertEqual(ingesterCallCount, 2)
        XCTAssertEqual(playbackActions, ["stop"])

        await runtime.stop(streamID: stream.id)
        await ingesterGate.release()
    }

    func testStartingInactiveStreamDoesNotStopSharedPlayback() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Fixture ICY",
            streamType: "icy",
            source: "https://example.test/live.mp3"
        )
        let gate = RuntimeGate()
        let ingester = RecordingBlockingAppRuntimeIngester(gate: gate)
        let player = RecordingRuntimePlaybackAdapter()
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: ingester,
            retryPolicy: .noRetry,
            playbackTimeline: AppPlayerTimelineClock(),
            playbackController: player
        )

        try await runtime.start(streamID: stream.id)

        let actions = await player.actions()
        XCTAssertEqual(actions, [])
        await runtime.stop(streamID: stream.id)
        await gate.release()
    }

    func testStartingSecondStreamReplacesSharedPlaybackOwner() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let first = try registry.add(
            name: "First HLS",
            streamType: "hls",
            source: "https://example.test/first.m3u8"
        )
        let second = try registry.add(
            name: "Second ICY",
            streamType: "icy",
            source: "https://example.test/second.mp3"
        )
        let gate = RuntimeGate()
        let ingester = RecordingBlockingAppRuntimeIngester(gate: gate)
        let player = RecordingRuntimePlaybackAdapter()
        let playbackSelection = AppPlaybackStreamSelection()
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: ingester,
            retryPolicy: .noRetry,
            playbackTimeline: AppPlayerTimelineClock(),
            playbackController: player,
            playbackSelection: playbackSelection
        )

        try await runtime.start(streamID: first.id)
        for _ in 0..<20 {
            if await ingester.callCount() >= 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let firstInitiallySelected = await playbackSelection.isSelected(streamID: first.id)
        XCTAssertTrue(firstInitiallySelected)

        try await runtime.start(streamID: second.id)
        for _ in 0..<20 {
            if await ingester.callCount() >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let ingesterCallCount = await ingester.callCount()
        let playbackActions = await player.actions()
        let preparedStreams = await player.preparedStreams()
        let firstStillSelected = await playbackSelection.isSelected(streamID: first.id)
        let secondSelected = await playbackSelection.isSelected(streamID: second.id)
        XCTAssertEqual(ingesterCallCount, 2)
        XCTAssertEqual(preparedStreams, [first.id, second.id])
        XCTAssertEqual(playbackActions, [])
        XCTAssertFalse(firstStillSelected)
        XCTAssertTrue(secondSelected)

        await runtime.stop(streamID: first.id)
        let actionsAfterStoppingBackgroundStream = await player.actions()
        XCTAssertEqual(actionsAfterStoppingBackgroundStream, [])
        await runtime.stop(streamID: second.id)
        let actionsAfterStoppingPlaybackOwner = await player.actions()
        XCTAssertEqual(actionsAfterStoppingPlaybackOwner, ["stop"])
        await gate.release()
    }

    func testMuteUnmuteSwitchingStopsMutedOwnerThenReplaysSelectedLiveBuffer() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let first = try registry.add(
            name: "First ICY",
            streamType: "icy",
            source: "https://example.test/first.mp3"
        )
        let second = try registry.add(
            name: "Second ICY",
            streamType: "icy",
            source: "https://example.test/second.mp3"
        )
        let gate = RuntimeGate()
        let ingester = RecordingBlockingAppRuntimeIngester(gate: gate)
        let player = RecordingRuntimePlaybackAdapter()
        let playbackSelection = AppPlaybackStreamSelection()
        let rollingBuffer = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: 120,
                hotMemoryDurationSeconds: 120,
                maximumSpillBytes: 0
            )
        )
        await rollingBuffer.start(streamID: first.id)
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: ingester,
            retryPolicy: .noRetry,
            playbackTimeline: AppPlayerTimelineClock(),
            rollingBuffer: rollingBuffer,
            playbackController: player,
            playbackSelection: playbackSelection
        )

        try await runtime.start(streamID: first.id)
        try await runtime.start(streamID: second.id)
        for _ in 0..<20 {
            if await ingester.callCount() >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let secondInitiallySelected = await playbackSelection.isSelected(streamID: second.id)
        XCTAssertTrue(secondInitiallySelected)

        await runtime.setMuted(streamID: second.id, isMuted: true)
        let secondSelectedAfterMute = await playbackSelection.isSelected(streamID: second.id)
        XCTAssertFalse(secondSelectedAfterMute)

        _ = await rollingBuffer.append([
            SharedPCMFrame(
                streamID: first.id,
                sequence: 9,
                audio: Data([0x09]),
                startSeconds: 90,
                endSeconds: 96
            )
        ])
        await runtime.setMuted(streamID: first.id, isMuted: false)
        let firstSelectedAfterUnmute = await playbackSelection.isSelected(streamID: first.id)
        XCTAssertTrue(firstSelectedAfterUnmute)

        let playbackActions = await player.actions()
        XCTAssertEqual(playbackActions, ["stop", "play:9"])
        await gate.release()
    }

    func testMutingCurrentPlaybackOwnerStopsSilentPlaybackSelection() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Selected ICY",
            streamType: "icy",
            source: "https://example.test/selected.mp3"
        )
        let gate = RuntimeGate()
        let ingester = RecordingBlockingAppRuntimeIngester(gate: gate)
        let player = RecordingRuntimePlaybackAdapter()
        let playbackSelection = AppPlaybackStreamSelection()
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: ingester,
            retryPolicy: .noRetry,
            playbackTimeline: AppPlayerTimelineClock(),
            playbackController: player,
            playbackSelection: playbackSelection
        )

        try await runtime.start(streamID: stream.id)
        for _ in 0..<20 {
            if await ingester.callCount() >= 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        await runtime.setMuted(streamID: stream.id, isMuted: true)

        let selectedAfterMute = await playbackSelection.isSelected(streamID: stream.id)
        let playbackActions = await player.actions()
        XCTAssertFalse(selectedAfterMute)
        XCTAssertEqual(playbackActions, ["stop"])
        await gate.release()
    }

    func testMuteUnmuteCurrentPlaybackOwnerStopsThenReplaysLiveBuffer() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Tailgate",
            streamType: "icy",
            source: "https://example.test/tailgate.mp3"
        )
        let gate = RuntimeGate()
        let ingester = RecordingBlockingAppRuntimeIngester(gate: gate)
        let player = RecordingRuntimePlaybackAdapter()
        let playbackSelection = AppPlaybackStreamSelection()
        let rollingBuffer = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: 120,
                hotMemoryDurationSeconds: 120,
                maximumSpillBytes: 0
            )
        )
        await rollingBuffer.start(streamID: stream.id)
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: ingester,
            retryPolicy: .noRetry,
            playbackTimeline: AppPlayerTimelineClock(),
            rollingBuffer: rollingBuffer,
            playbackController: player,
            playbackSelection: playbackSelection
        )

        try await runtime.start(streamID: stream.id)
        for _ in 0..<20 {
            if await ingester.callCount() >= 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let initiallySelected = await playbackSelection.isSelected(streamID: stream.id)
        let initiallyPreparedStreams = await player.preparedStreams()
        XCTAssertTrue(initiallySelected)
        XCTAssertEqual(initiallyPreparedStreams, [stream.id])

        _ = await rollingBuffer.append([
            SharedPCMFrame(
                streamID: stream.id,
                sequence: 11,
                audio: Data([0x11]),
                startSeconds: 110,
                endSeconds: 116
            )
        ])
        await runtime.setMuted(streamID: stream.id, isMuted: true)
        await runtime.setMuted(streamID: stream.id, isMuted: false)

        let selectedAfterUnmute = await playbackSelection.isSelected(streamID: stream.id)
        let preparedStreamsAfterUnmute = await player.preparedStreams()
        let playbackActionsAfterUnmute = await player.actions()
        XCTAssertTrue(selectedAfterUnmute)
        XCTAssertEqual(preparedStreamsAfterUnmute, [stream.id, stream.id])
        XCTAssertEqual(playbackActionsAfterUnmute, ["stop", "play:11"])
        await gate.release()
    }

    func testStartingSecondStreamSelectsNewPlaybackOwnerBeforePreviousStopCompletes() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let first = try registry.add(
            name: "First HLS",
            streamType: "hls",
            source: "https://example.test/first.m3u8"
        )
        let second = try registry.add(
            name: "Second ICY",
            streamType: "icy",
            source: "https://example.test/second.mp3"
        )
        let ingesterGate = RuntimeGate()
        let ingester = RecordingBlockingAppRuntimeIngester(gate: ingesterGate)
        let stopGate = RuntimeStopGate()
        let playbackSelection = AppPlaybackStreamSelection()
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: ingester,
            retryPolicy: .noRetry,
            playbackTimeline: AppPlayerTimelineClock(),
            playbackController: GatedStopRuntimePlaybackAdapter(gate: stopGate),
            playbackSelection: playbackSelection
        )

        try await runtime.start(streamID: first.id)
        for _ in 0..<20 {
            if await ingester.callCount() >= 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let firstInitiallySelected = await playbackSelection.isSelected(streamID: first.id)
        XCTAssertTrue(firstInitiallySelected)

        try await runtime.start(streamID: second.id)
        for _ in 0..<20 {
            if await ingester.callCount() >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let firstSelectedAfterReplacement = await playbackSelection.isSelected(streamID: first.id)
        let secondSelectedAfterReplacement = await playbackSelection.isSelected(streamID: second.id)
        let previousOwnerStopCount = await stopGate.callCount()
        XCTAssertFalse(firstSelectedAfterReplacement)
        XCTAssertTrue(secondSelectedAfterReplacement)
        XCTAssertEqual(previousOwnerStopCount, 0)
        let ingesterCallCount = await ingester.callCount()
        XCTAssertEqual(ingesterCallCount, 2)

        await stopGate.release()
        await runtime.stop(streamID: first.id)
        await runtime.stop(streamID: second.id)
        await ingesterGate.release()
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

    func testExplicitStopClearsPersistedStatusWithoutInMemoryRun() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Stale HLS",
            streamType: "hls",
            source: "https://example.test/stale.m3u8"
        )
        let statusStore = AppStreamRuntimeStatusStore(database: temporary.database)
        try statusStore.upsert(
            AppStreamRuntimeStatusUpdate(
                streamID: stream.id,
                phase: .running,
                attempt: 1,
                maxAttempts: 3,
                updatedAt: "2026-05-01T10:00:01Z"
            )
        )
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: RecordingAppRuntimeIngester(result: AppStreamRuntimeResult(streamID: stream.id)),
            retryPolicy: .noRetry,
            statusStore: statusStore
        )

        await runtime.stop(streamID: stream.id)

        let snapshot = try XCTUnwrap(try statusStore.status(streamID: stream.id))
        XCTAssertEqual(snapshot.phase, .stopped)
        XCTAssertEqual(snapshot.attempt, 1)
        let runtimeSnapshot = await runtime.snapshot(streamID: stream.id)
        XCTAssertEqual(runtimeSnapshot?.phase, .stopped)
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
        let dates = DeterministicDateProvider([
            // Runtime status persistence also consumes the injected clock while these
            // streams start and suspend. Keep those status timestamps at the sleep
            // instant so the lifecycle clock still advances exactly five seconds
            // when wake recovery begins under XCTest execution.
            Date(timeIntervalSince1970: 1_767_225_600),
            Date(timeIntervalSince1970: 1_767_225_600),
            Date(timeIntervalSince1970: 1_767_225_600),
            Date(timeIntervalSince1970: 1_767_225_600),
            Date(timeIntervalSince1970: 1_767_225_600),
            Date(timeIntervalSince1970: 1_767_225_600),
            Date(timeIntervalSince1970: 1_767_225_600),
            Date(timeIntervalSince1970: 1_767_225_605),
        ])
        let runtime = AppStreamRuntimeService(registry: registry, ingester: ingester, retryPolicy: .noRetry, statusStore: statusStore, now: { dates.next() })
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        try await runtime.start(streamID: first.id)
        let firstConnecting = try await nextEvent(from: &iterator)
        let firstRunning = try await nextEvent(from: &iterator)
        XCTAssertEqual(firstConnecting.phase, .connecting)
        XCTAssertEqual(firstRunning.phase, .running)
        try await runtime.start(streamID: second.id)
        let secondConnecting = try await nextEvent(from: &iterator)
        let secondRunning = try await nextEvent(from: &iterator)
        XCTAssertEqual(secondConnecting.phase, .connecting)
        XCTAssertEqual(secondRunning.phase, .running)

        await runtime.suspendForSystemSleep(reason: "sleep for https://user:pass@example.test/private?token=secret at /Users/example/private")
        let firstSuspended = try await nextEvent(from: &iterator)
        let secondSuspended = try await nextEvent(from: &iterator)
        XCTAssertEqual(firstSuspended.phase, AppStreamRuntimePhase.suspended)
        XCTAssertEqual(secondSuspended.phase, AppStreamRuntimePhase.suspended)
        XCTAssertFalse(firstSuspended.message.contains("user:pass"), firstSuspended.message)
        XCTAssertFalse(firstSuspended.message.contains("token=secret"), firstSuspended.message)
        XCTAssertFalse(firstSuspended.message.contains("/Users/example"), firstSuspended.message)
        XCTAssertNil(firstSuspended.lifecycleEvidence?.recoveryLatencySeconds)
        XCTAssertEqual(try statusStore.status(streamID: first.id)?.phase, .suspended)

        try await Task.sleep(nanoseconds: 50_000_000)
        let firstSnapshotAfterCancel = await runtime.snapshot(streamID: first.id)
        let secondSnapshotAfterCancel = await runtime.snapshot(streamID: second.id)
        XCTAssertEqual(firstSnapshotAfterCancel?.phase, AppStreamRuntimePhase.suspended)
        XCTAssertEqual(secondSnapshotAfterCancel?.phase, AppStreamRuntimePhase.suspended)

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
        let requestStreamIDs = await ingester.requestStreamIDs()
        XCTAssertEqual(requestStreamIDs, [first.id, second.id, first.id, second.id])
        await gate.release()
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
        let siblingSnapshot = await runtime.snapshot(streamID: sibling.id)
        XCTAssertEqual(siblingSnapshot?.phase, AppStreamRuntimePhase.running)

        await gate.release()
    }

    func testWakeRecoveryUsesPersistedRunningStatusWhenSleepCaptureIsMissing() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Persisted HLS",
            streamType: "hls",
            source: "https://example.test/persisted.m3u8"
        )
        let statusStore = AppStreamRuntimeStatusStore(database: temporary.database)
        try statusStore.upsert(
            AppStreamRuntimeStatusUpdate(
                streamID: stream.id,
                phase: .running,
                updatedAt: "2026-05-01T10:00:00Z"
            )
        )
        let gate = RuntimeGate()
        let ingester = LifecycleRecordingIngester(gate: gate)
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: ingester,
            retryPolicy: .noRetry,
            statusStore: statusStore,
            now: { Date(timeIntervalSince1970: 1_767_225_600) }
        )
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()

        await runtime.recoverFromSystemWake(reason: "wake after missed sleep notification")

        let recovering = try await nextEvent(matching: { $0.streamID == stream.id && $0.phase == .recovering }, from: &iterator)
        XCTAssertEqual(recovering.lifecycleEvidence?.recoveryLatencySeconds, 0)
        _ = try await nextEvent(matching: { $0.streamID == stream.id && $0.phase == .connecting }, from: &iterator)
        _ = try await nextEvent(matching: { $0.streamID == stream.id && $0.phase == .running }, from: &iterator)
        let requestStreamIDs = await ingester.requestStreamIDs()
        XCTAssertEqual(try statusStore.status(streamID: stream.id)?.phase, .running)
        XCTAssertEqual(requestStreamIDs, [stream.id])

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
        let emptySnapshot = await runtime.snapshot()
        XCTAssertNil(emptySnapshot)

        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()
        try await runtime.start(streamID: stream.id)
        _ = try await nextEvent(from: &iterator)
        _ = try await nextEvent(from: &iterator)
        await runtime.suspendForSystemSleep(reason: "sleep")
        _ = try await nextEvent(from: &iterator)
        await runtime.recoverFromSystemWake(reason: "wake")
        _ = try await nextEvent(matching: { $0.phase == .running }, from: &iterator)
        let afterFirstWake = (await ingester.requestStreamIDs()).count
        await runtime.recoverFromSystemWake(reason: "repeated wake")
        try await Task.sleep(nanoseconds: 50_000_000)
        let afterRepeatedWake = await ingester.requestStreamIDs()
        XCTAssertEqual(afterRepeatedWake.count, afterFirstWake)

        await gate.release()
    }
}
