import Foundation
import GRDB
import XCTest

@testable import SoundingKit

final class AppStreamRuntimePipelineRunnerTests: AppStreamRuntimeTestCase {
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

    func testRuntimeStartPropagatesRegistryAudioArchiveSettingToRequest() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Archive HLS",
            streamType: "hls",
            source: "https://example.test/archive.m3u8"
        )
        _ = try registry.updateAudioArchive(streamID: stream.id, isEnabled: true)
        let ingester = RecordingAppRuntimeIngester(
            result: AppStreamRuntimeResult(streamID: stream.id)
        )
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: ingester,
            retryPolicy: .noRetry
        )

        try await runtime.start(streamID: stream.id)

        var requests = await ingester.requests()
        for _ in 0..<50 where requests.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
            requests = await ingester.requests()
        }
        let request = try XCTUnwrap(requests.first)
        XCTAssertTrue(request.isAudioArchiveEnabled)
    }

    func testPipelineRunnerPollsLivePlaybackUntilCancelled() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Continuous HLS",
            streamType: "hls",
            source: "https://example.test/continuous.m3u8"
        )
        let decoder = PollingFixtureDecoder()
        let runner = StreamIngestAppRuntimeRunner(
            database: temporary.database,
            decoder: decoder,
            transcriber: FixtureTranscriber(),
            diarizer: FixtureDiarizer(),
            player: RecordingRuntimePlaybackAdapter(),
            timeline: AppPlayerTimelineClock(),
            ingestMode: .livePolling(maxChunksPerPass: 1),
            livePollIntervalNanoseconds: 1_000_000,
            now: { "2026-05-01T00:00:00Z" }
        )
        let request = AppStreamRuntimeRequest(
            streamID: stream.id,
            name: stream.name,
            source: "https://example.test/continuous.m3u8",
            sourceDescription: stream.sourceDescription,
            streamType: .hls
        )

        let task = Task {
            try await runner.run(request)
        }
        await decoder.waitForCalls(2)
        for _ in 0..<50 {
            let completedChunks = try temporary.database.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(ingest_chunks.id)
                        FROM ingest_runs
                        JOIN ingest_chunks ON ingest_chunks.run_id = ingest_runs.id
                        WHERE ingest_runs.stream_id = ?
                          AND ingest_runs.status = 'completed'
                        """,
                    arguments: [stream.id]
                ) ?? 0
            }
            if completedChunks >= 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()

        do {
            let result = try await task.value
            XCTAssertGreaterThanOrEqual(result.processedChunks, 2)
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let evidence = try temporary.database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(DISTINCT ingest_runs.id) AS run_count,
                           COUNT(ingest_chunks.id) AS chunk_count
                    FROM ingest_runs
                    JOIN ingest_chunks ON ingest_chunks.run_id = ingest_runs.id
                    WHERE ingest_runs.stream_id = ?
                      AND ingest_runs.status = 'completed'
                    """,
                arguments: [stream.id]
            )
        }
        XCTAssertGreaterThanOrEqual(evidence?["run_count"] as Int? ?? 0, 2)
        XCTAssertGreaterThanOrEqual(evidence?["chunk_count"] as Int? ?? 0, 2)
    }

    func testPipelineRunnerCancellationDoesNotWaitForeverForPlaybackStop() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Continuous HLS",
            streamType: "hls",
            source: "https://example.test/continuous.m3u8"
        )
        let decoder = PollingFixtureDecoder()
        let stopGate = RuntimeStopGate()
        let runner = StreamIngestAppRuntimeRunner(
            database: temporary.database,
            decoder: decoder,
            transcriber: FixtureTranscriber(),
            diarizer: FixtureDiarizer(),
            player: GatedStopRuntimePlaybackAdapter(gate: stopGate),
            timeline: AppPlayerTimelineClock(),
            ingestMode: .livePolling(maxChunksPerPass: 1),
            livePollIntervalNanoseconds: 1_000_000,
            playbackStopTimeoutNanoseconds: 1_000_000,
            now: { "2026-05-01T00:00:00Z" }
        )
        let request = AppStreamRuntimeRequest(
            streamID: stream.id,
            name: stream.name,
            source: "https://example.test/continuous.m3u8",
            sourceDescription: stream.sourceDescription,
            streamType: .hls
        )

        let task = Task {
            try await runner.run(request)
        }
        await decoder.waitForCalls(1)
        let startedAt = Date()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        let stopCallCount = await stopGate.callCount()
        XCTAssertEqual(stopCallCount, 1)

        await stopGate.release()
    }
}
