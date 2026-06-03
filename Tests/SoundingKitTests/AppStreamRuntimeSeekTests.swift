import Foundation
import GRDB
import XCTest

@testable import SoundingKit

final class AppStreamRuntimeSeekTests: AppStreamRuntimeTestCase {
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

        await runtime.seek(to: 10, streamID: stream.id)

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

    func testSeekPlaybackReplacesQueuedLiveAudio() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Seek HLS",
            streamType: "hls",
            source: "https://example.test/seek.m3u8"
        )
        let gate = RuntimeGate()
        let rollingBuffer = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: 60,
                hotMemoryDurationSeconds: 60,
                maximumSpillBytes: 0
            )
        )
        await rollingBuffer.start(streamID: stream.id)
        _ = await rollingBuffer.append([
            SharedPCMFrame(
                streamID: stream.id,
                sequence: 7,
                audio: Data([0x01, 0x02]),
                startSeconds: 12,
                endSeconds: 18,
                format: .linearPCM(sampleRate: 48_000, channelCount: 1)
            )
        ])
        let timeline = AppPlayerTimelineClock()
        await timeline.reset(streamID: stream.id)
        await timeline.updateRollingBuffer(await rollingBuffer.snapshot())
        let player = RecordingRuntimePlaybackAdapter()
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: BlockingAppRuntimeIngester(gate: gate),
            retryPolicy: .noRetry,
            playbackTimeline: timeline,
            rollingBuffer: rollingBuffer,
            playbackController: player
        )
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()
        try await runtime.start(streamID: stream.id)
        _ = try await nextEvent(from: &iterator)
        _ = try await nextEvent(from: &iterator)

        await runtime.seek(to: 12, streamID: stream.id)

        let playbackActions = await player.actions()
        XCTAssertTrue(playbackActions.contains("replace:7"), String(describing: playbackActions))
        XCTAssertFalse(playbackActions.contains("play:7"), String(describing: playbackActions))
        await runtime.stop()
        await gate.release()
    }

    func testSeekFallsBackToArchivedAudioOutsideRollingBuffer() async throws {
        let temporary = try TemporarySoundingDatabase()
        let archiveDirectory = temporary.fileURL.deletingLastPathComponent()
            .appendingPathComponent("RuntimeSeekArchive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archiveDirectory) }
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Archived HLS",
            streamType: "hls",
            source: "https://example.test/archive.m3u8"
        )
        let identifiers = try makeRunAndChunk(database: temporary.database, streamID: stream.id)
        let archiveStore = AudioArchiveStore(
            database: temporary.database,
            archiveDirectory: archiveDirectory
        )
        _ = try archiveStore.archive(
            frame: SharedPCMFrame(
                streamID: stream.id,
                sequence: 42,
                audio: Data([0x2a]),
                startSeconds: 120,
                endSeconds: 130,
                format: .linearPCM(sampleRate: 44_100, channelCount: 1)
            ),
            runID: identifiers.runID,
            chunkID: identifiers.chunkID
        )
        let gate = RuntimeGate()
        let rollingBuffer = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: 60,
                hotMemoryDurationSeconds: 60,
                maximumSpillBytes: 0
            )
        )
        await rollingBuffer.start(streamID: stream.id)
        _ = await rollingBuffer.append([
            SharedPCMFrame(
                streamID: stream.id,
                sequence: 7,
                audio: Data([0x07]),
                startSeconds: 10,
                endSeconds: 20
            )
        ])
        let timeline = AppPlayerTimelineClock()
        await timeline.reset(streamID: stream.id)
        await timeline.updateRollingBuffer(await rollingBuffer.snapshot())
        let player = RecordingRuntimePlaybackAdapter()
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: BlockingAppRuntimeIngester(gate: gate),
            retryPolicy: .noRetry,
            playbackTimeline: timeline,
            rollingBuffer: rollingBuffer,
            audioArchiveStore: archiveStore,
            playbackController: player
        )
        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()
        try await runtime.start(streamID: stream.id)
        _ = try await nextEvent(from: &iterator)
        _ = try await nextEvent(from: &iterator)

        await runtime.seek(to: 125, streamID: stream.id)

        let playbackActions = await player.actions()
        XCTAssertTrue(playbackActions.contains("replace:42"), String(describing: playbackActions))
        XCTAssertFalse(playbackActions.contains("play:42"), String(describing: playbackActions))
        let seeked = try await nextEvent(from: &iterator)
        XCTAssertEqual(seeked.result?.playerTimeline?.positionSeconds, 120)
        XCTAssertNil(seeked.result?.playerTimeline?.unavailableRangeMessage)

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

        await runtime.seek(to: -1, streamID: stream.id)

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

        await runtime.seek(to: 42, streamID: stream.id)

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

        await runtime.seek(to: 5, streamID: 111)

        let runtimeSnapshot = await runtime.snapshot()
        let timelineSnapshot = await timeline.snapshot()
        XCTAssertNil(runtimeSnapshot)
        XCTAssertEqual(timelineSnapshot, AppPlayerTimelineSnapshot())
    }

    func testSeekTargetsExplicitStreamRatherThanCurrentRuntimeFallback() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let first = try registry.add(
            name: "First",
            streamType: "hls",
            source: "https://example.test/first.m3u8"
        )
        let second = try registry.add(
            name: "Second",
            streamType: "hls",
            source: "https://example.test/second.m3u8"
        )
        let gate = RuntimeGate()
        let rollingBuffer = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: 120,
                hotMemoryDurationSeconds: 120,
                maximumSpillBytes: 0
            )
        )
        await rollingBuffer.start(streamID: second.id)
        _ = await rollingBuffer.append([
            SharedPCMFrame(
                streamID: second.id,
                sequence: 2,
                audio: Data([0x02]),
                startSeconds: 20,
                endSeconds: 30
            )
        ])
        let timeline = AppPlayerTimelineClock()
        await timeline.reset(streamID: second.id)
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

        try await runtime.start(streamID: first.id)
        _ = try await nextEvent(from: &iterator)
        _ = try await nextEvent(from: &iterator)

        await runtime.seek(to: 20, streamID: second.id)

        let seeked = try await nextEvent(from: &iterator)
        XCTAssertEqual(seeked.streamID, second.id)
        XCTAssertEqual(seeked.result?.playerTimeline?.positionSeconds, 20)

        await runtime.stop(streamID: first.id)
        await gate.release()
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
            await runtime.seek(to: target, streamID: stream.id)
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

        await runtime.seek(to: 0, streamID: stream.id)
        let zero = try await nextEvent(from: &iterator)
        XCTAssertEqual(zero.result?.playerTimeline?.positionSeconds, 0)
        XCTAssertNil(zero.result?.playerTimeline?.unavailableRangeMessage)

        await runtime.seek(to: 20, streamID: stream.id)
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

        await runtime.seek(to: 5, streamID: stream.id)

        let latest = await runtime.snapshot()
        XCTAssertEqual(latest, running)
        XCTAssertNil(latest?.result?.playerTimeline)

        await runtime.stop()
        await gate.release()
    }

    private func makeRunAndChunk(database: SoundingDatabase, streamID: Int64) throws
        -> (runID: Int64, chunkID: Int64)
    {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO ingest_runs (stream_id, started_at, status)
                    VALUES (?, ?, ?)
                    """,
                arguments: [streamID, "2026-05-01T10:00:00Z", "running"]
            )
            let runID = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO ingest_chunks (run_id, sequence, byte_count, started_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [runID, 42, 1, "2026-05-01T10:00:01Z"]
            )
            return (runID: runID, chunkID: db.lastInsertedRowID)
        }
    }
}
