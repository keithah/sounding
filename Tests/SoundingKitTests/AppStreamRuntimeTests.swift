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
