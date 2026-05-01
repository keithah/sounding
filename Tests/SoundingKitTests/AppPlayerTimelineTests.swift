import Foundation
import GRDB
import XCTest

@testable import SoundingKit

final class AppPlayerTimelineTests: XCTestCase {
    func testRuntimeFeedsIngestAndPlaybackFromOneDecodeCall() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Shared HLS",
            streamType: "hls",
            source: "https://user:pass@example.test/shared.m3u8?token=secret"
        )
        let decoder = CountingSharedDecoder(chunks: [
            DecodedAudioChunk(
                sequence: 0,
                segmentURI: "https://user:pass@example.test/segment-0.ts?token=secret",
                audio: Data([0x01, 0x02, 0x03]),
                startSeconds: 0,
                endSeconds: 2,
                startedAt: "2026-05-01T00:00:00Z",
                endedAt: "2026-05-01T00:00:02Z"
            ),
            DecodedAudioChunk(
                sequence: 1,
                segmentURI: "https://user:pass@example.test/segment-1.ts?token=secret",
                audio: Data([0x04, 0x05]),
                startSeconds: 2,
                endSeconds: 4,
                startedAt: "2026-05-01T00:00:02Z",
                endedAt: "2026-05-01T00:00:04Z"
            ),
        ])
        let player = DeterministicAppPCMPlayerAdapter()
        let timeline = AppPlayerTimelineClock()
        let runner = StreamIngestAppRuntimeRunner(
            database: temporary.database,
            decoder: decoder,
            transcriber: FixtureTimelineTranscriber(),
            diarizer: FixtureTimelineDiarizer(),
            player: player,
            timeline: timeline,
            now: { "2026-05-01T00:00:00Z" }
        )

        let result = try await runner.run(
            AppStreamRuntimeRequest(
                streamID: stream.id,
                name: stream.name,
                source: "https://user:pass@example.test/shared.m3u8?token=secret",
                sourceDescription: stream.sourceDescription,
                streamType: .hls
            ))

        XCTAssertEqual(result.processedChunks, 2)
        let decodeCallCount = await decoder.callCount()
        XCTAssertEqual(decodeCallCount, 1)
        let frames = await player.frames()
        XCTAssertEqual(frames.map(\.sequence), [0, 1])
        XCTAssertEqual(frames.map(\.audio), [Data([0x01, 0x02, 0x03]), Data([0x04, 0x05])])
        XCTAssertEqual(frames.map(\.startSeconds), [0, 2])
        XCTAssertEqual(frames.map(\.endSeconds), [2, 4])
        let preparedStreams = await player.preparedStreams()
        XCTAssertEqual(preparedStreams, [stream.id])

        let snapshot = try XCTUnwrap(result.playerTimeline)
        XCTAssertEqual(snapshot.streamID, stream.id)
        XCTAssertEqual(snapshot.decodedFrameCount, 2)
        XCTAssertEqual(snapshot.bufferedStartSeconds, 0)
        XCTAssertEqual(snapshot.bufferedEndSeconds, 4)
        XCTAssertEqual(snapshot.liveEdgeSeconds, 4)
        XCTAssertEqual(snapshot.state, .stopped)
        XCTAssertFalse(snapshot.lastMessage.contains("token=secret"), snapshot.lastMessage)

        let rows = try temporary.database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) AS chunk_count
                    FROM ingest_runs
                    JOIN ingest_chunks ON ingest_chunks.run_id = ingest_runs.id
                    WHERE ingest_runs.stream_id = ?
                    """,
                arguments: [stream.id]
            )
        }
        XCTAssertEqual(rows?["chunk_count"] as Int?, 2)
    }

    func testSinglePathDecoderSurfacesPlaybackFailuresWithoutSecondDecodePath() async throws {
        let decoder = CountingSharedDecoder(chunks: [
            DecodedAudioChunk(
                sequence: 0,
                audio: Data([0x01]),
                startSeconds: 0,
                endSeconds: 1,
                startedAt: "2026-05-01T00:00:00Z"
            )
        ])
        let timeline = AppPlayerTimelineClock()
        await timeline.reset(streamID: 42)
        let tee = SinglePathPCMDecoder(
            streamID: 42,
            upstream: decoder,
            player: FailingAppPCMPlayerAdapter(),
            timeline: timeline
        )

        do {
            _ = try await tee.decodedChunks(
                for: AudioDecodeRequest(source: "https://example.test/live.m3u8", streamType: .hls))
            XCTFail("Expected playback failure")
        } catch let error as AppPlayerAdapterError {
            XCTAssertEqual(
                error,
                .decodeFailed("Playback adapter failed: device exploded token=[redacted-query]."))
        } catch {
            XCTFail("Expected AppPlayerAdapterError, got \(error)")
        }

        let decodeCallCount = await decoder.callCount()
        XCTAssertEqual(decodeCallCount, 1)
        let snapshot = await timeline.snapshot()
        XCTAssertEqual(
            snapshot.state,
            .failed(message: "Playback adapter failed: device exploded token=[redacted-query]."))
        XCTAssertFalse(snapshot.lastMessage.contains("secret"), snapshot.lastMessage)
    }

    func testPlayerTimelineClockTracksPositionLiveEdgeAndDrift() async throws {
        let timeline = AppPlayerTimelineClock()
        await timeline.reset(streamID: 7)
        await timeline.recordDecodedFrames([
            SharedPCMFrame(
                streamID: 7, sequence: 0, audio: Data([0x01]), startSeconds: 10, endSeconds: 15),
            SharedPCMFrame(
                streamID: 7, sequence: 1, audio: Data([0x02]), startSeconds: 15, endSeconds: 20),
        ])
        await timeline.updatePlayerState(
            .playing, positionSeconds: 12, message: "Playing shared timeline.")

        let snapshot = await timeline.snapshot()
        XCTAssertEqual(snapshot.streamID, 7)
        XCTAssertEqual(snapshot.state, .playing)
        XCTAssertEqual(snapshot.positionSeconds, 12)
        XCTAssertEqual(snapshot.liveEdgeSeconds, 20)
        XCTAssertEqual(snapshot.bufferedStartSeconds, 10)
        XCTAssertEqual(snapshot.bufferedEndSeconds, 20)
        XCTAssertEqual(snapshot.driftSeconds, 8)
        XCTAssertEqual(snapshot.decodedFrameCount, 2)
    }
}

private actor CountingSharedDecoder: AudioDecoding {
    private let chunks: [DecodedAudioChunk]
    private var calls = 0

    init(chunks: [DecodedAudioChunk]) {
        self.chunks = chunks
    }

    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        calls += 1
        XCTAssertEqual(request.streamType, .hls)
        return chunks
    }

    func callCount() -> Int { calls }
}

private struct FailingAppPCMPlayerAdapter: AppPCMPlaybackAdapting {
    func prepare(streamID: Int64, sourceDescription: String, timeline: AppPlayerTimelineClock)
        async throws
    {}

    func play(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock) async throws {
        throw AppPlayerAdapterError.audioDeviceUnavailable("device exploded token=secret")
    }

    func pause(timeline: AppPlayerTimelineClock) async {}
    func resume(timeline: AppPlayerTimelineClock) async {}
    func stop(timeline: AppPlayerTimelineClock) async {}
}

private struct FixtureTimelineTranscriber: MLTranscription {
    func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
        [
            TranscriptSegmentDraft(
                sequence: chunk.sequence,
                startSeconds: chunk.startSeconds,
                endSeconds: chunk.endSeconds,
                text: "chunk \(chunk.sequence)",
                confidence: 1,
                words: []
            )
        ]
    }
}

private struct FixtureTimelineDiarizer: SpeakerDiarization {
    func diarize(
        _ chunk: DecodedAudioChunk,
        transcriptSegments: [TranscriptSegmentDraft]
    ) async throws -> [SpeakerTurnDraft] {
        [
            SpeakerTurnDraft(
                speakerLabel: "speaker",
                startSeconds: chunk.startSeconds,
                endSeconds: chunk.endSeconds,
                confidence: 1
            )
        ]
    }
}
