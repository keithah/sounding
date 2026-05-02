import Foundation
import GRDB
import XCTest

@testable import SoundingKit

#if canImport(AVFoundation)
    import AVFoundation
#endif

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
                audioFormat: .linearPCM(sampleRate: 44_100, channelCount: 1, bitDepth: 16),
                startSeconds: 0,
                endSeconds: 2,
                startedAt: "2026-05-01T00:00:00Z",
                endedAt: "2026-05-01T00:00:02Z"
            ),
            DecodedAudioChunk(
                sequence: 1,
                segmentURI: "https://user:pass@example.test/segment-1.ts?token=secret",
                audio: Data([0x04, 0x05]),
                audioFormat: .linearPCM(sampleRate: 44_100, channelCount: 1, bitDepth: 16),
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
                audioFormat: .linearPCM(sampleRate: 44_100, channelCount: 1, bitDepth: 16),
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
                .decodeFailed("Playback adapter failed: device exploded token=[redacted]."))
        } catch {
            XCTFail("Expected AppPlayerAdapterError, got \(error)")
        }

        let decodeCallCount = await decoder.callCount()
        XCTAssertEqual(decodeCallCount, 1)
        let snapshot = await timeline.snapshot()
        XCTAssertEqual(
            snapshot.state,
            .failed(message: "Playback adapter failed: device exploded token=[redacted]"))
        XCTAssertFalse(snapshot.lastMessage.contains("secret"), snapshot.lastMessage)
    }

    func testAVFoundationAdapterSchedulesSupportedPCMFrames() async throws {
        #if canImport(AVFoundation)
            let timeline = AppPlayerTimelineClock()
            await timeline.reset(streamID: 88)
            let scheduledBufferCount = LockedCounter()
            let adapter = AVFoundationAppPCMPlayerAdapter(
                engineStarter: {},
                bufferScheduler: { buffers in
                    XCTAssertEqual(buffers.count, 2)
                    XCTAssertEqual(buffers.map(\.frameLength), [2, 2])
                    XCTAssertEqual(buffers.map { $0.format.sampleRate }, [48_000, 48_000])
                    XCTAssertEqual(buffers.map { Int($0.format.channelCount) }, [2, 2])
                    scheduledBufferCount.increment(by: buffers.count)
                },
                playerStarter: {}
            )
            let format = SharedPCMFormat.linearPCM(
                sampleRate: 48_000,
                channelCount: 2,
                bitDepth: 16
            )

            try await adapter.play(
                [
                    SharedPCMFrame(
                        streamID: 88,
                        sequence: 0,
                        audio: Data([0x00, 0x00, 0xff, 0x7f, 0x00, 0x80, 0xff, 0xff]),
                        startSeconds: 0,
                        endSeconds: 0.00004,
                        format: format
                    ),
                    SharedPCMFrame(
                        streamID: 88,
                        sequence: 1,
                        audio: Data([0x10, 0x00, 0x20, 0x00, 0x30, 0x00, 0x40, 0x00]),
                        startSeconds: 0.00004,
                        endSeconds: 0.00008,
                        format: format
                    ),
                ], timeline: timeline)

            XCTAssertEqual(scheduledBufferCount.value, 2)
            let snapshot = await timeline.snapshot()
            XCTAssertEqual(snapshot.state, .playing)
            XCTAssertEqual(snapshot.decodedFrameCount, 2)
            XCTAssertEqual(snapshot.bufferedStartSeconds, 0)
            XCTAssertEqual(snapshot.bufferedEndSeconds, 0.00008)
            XCTAssertEqual(snapshot.lastMessage, "Playing shared PCM frame 1.")
        #endif
    }

    func testAVFoundationAdapterRejectsUnknownAndContainerBytesWithoutClaimingPlayback()
        async throws
    {
        #if canImport(AVFoundation)
            let timeline = AppPlayerTimelineClock()
            await timeline.reset(streamID: 89)
            let scheduledBufferCount = LockedCounter()
            let adapter = AVFoundationAppPCMPlayerAdapter(
                engineStarter: {},
                bufferScheduler: { buffers in scheduledBufferCount.increment(by: buffers.count) },
                playerStarter: {}
            )
            let frame = SharedPCMFrame(
                streamID: 89,
                sequence: 0,
                audio: Data([0x23, 0x45, 0x58, 0x54, 0x4d, 0x33, 0x55]),
                startSeconds: 0,
                endSeconds: 1,
                format: .containerBytes
            )

            do {
                try await adapter.play([frame], timeline: timeline)
                XCTFail("Expected unsupported PCM format")
            } catch let error as AppPlayerAdapterError {
                guard case .unsupportedPCMFormat(let message) = error else {
                    return XCTFail("Expected unsupportedPCMFormat, got \(error)")
                }
                XCTAssertTrue(message.contains("containerBytes"), message)
            }

            XCTAssertEqual(scheduledBufferCount.value, 0)
            let snapshot = await timeline.snapshot()
            XCTAssertEqual(snapshot.decodedFrameCount, 0)
            XCTAssertEqual(
                snapshot.state,
                .failed(
                    message:
                        "Unsupported PCM format for frame 0: decoded payload is containerBytes."))
            XCTAssertEqual(
                snapshot.lastMessage,
                "Unsupported PCM format for frame 0: decoded payload is containerBytes.")
        #endif
    }

    func testAVFoundationAdapterRejectsMalformedPCMAndRedactsFailureMessages() async throws {
        #if canImport(AVFoundation)
            let timeline = AppPlayerTimelineClock()
            await timeline.reset(streamID: 90)
            let adapter = AVFoundationAppPCMPlayerAdapter(
                engineStarter: {},
                bufferScheduler: { _ in
                    throw AppPlayerAdapterError.schedulingFailed(
                        "leaked https://user:pass@example.test/live.m3u8?token=secret")
                },
                playerStarter: {}
            )
            let malformedFrame = SharedPCMFrame(
                streamID: 90,
                sequence: 7,
                audio: Data([0x00, 0x01, 0x02]),
                startSeconds: 1,
                endSeconds: 2,
                format: .linearPCM(sampleRate: 44_100, channelCount: 2)
            )

            do {
                try await adapter.play([malformedFrame], timeline: timeline)
                XCTFail("Expected malformed payload rejection")
            } catch let error as AppPlayerAdapterError {
                XCTAssertEqual(
                    error,
                    .unsupportedPCMFormat(
                        "Unsupported PCM format for frame 7: PCM payload byte count is not aligned to frames."
                    )
                )
            }

            let badTimestampFrame = SharedPCMFrame(
                streamID: 90,
                sequence: 6,
                audio: Data([0x00, 0x00, 0x01, 0x00]),
                startSeconds: .infinity,
                endSeconds: .infinity,
                format: .linearPCM(sampleRate: 44_100, channelCount: 1)
            )
            do {
                try await adapter.play([badTimestampFrame], timeline: timeline)
                XCTFail("Expected malformed timestamp rejection")
            } catch let error as AppPlayerAdapterError {
                XCTAssertEqual(
                    error,
                    .unsupportedPCMFormat(
                        "Unsupported PCM format for frame 6: timestamp bounds are malformed.")
                )
            }

            let validFrame = SharedPCMFrame(
                streamID: 90,
                sequence: 8,
                audio: Data([0x00, 0x00, 0x01, 0x00]),
                startSeconds: 2,
                endSeconds: 3,
                format: .linearPCM(sampleRate: 44_100, channelCount: 1)
            )
            do {
                try await adapter.play([validFrame], timeline: timeline)
                XCTFail("Expected scheduler failure")
            } catch let error as AppPlayerAdapterError {
                guard case .schedulingFailed(let message) = error else {
                    return XCTFail("Expected schedulingFailed, got \(error)")
                }
                XCTAssertTrue(message.contains("https://example.test/live.m3u8"), message)
                XCTAssertFalse(message.contains("user:pass"), message)
                XCTAssertFalse(message.contains("token=secret"), message)
            }

            let snapshot = await timeline.snapshot()
            guard case .failed(let message) = snapshot.state else {
                return XCTFail("Expected failed snapshot, got \(snapshot.state)")
            }
            XCTAssertFalse(message.contains("token=secret"), message)
            XCTAssertFalse(snapshot.lastMessage.contains("user:pass"), snapshot.lastMessage)
            XCTAssertTrue(snapshot.lastMessage.contains("https://example.test/live.m3u8"), snapshot.lastMessage)
        #endif
    }

    func testAVFoundationAdapterEmptyFramesAreNoOpForTimelineState() async throws {
        #if canImport(AVFoundation)
            let timeline = AppPlayerTimelineClock()
            await timeline.reset(streamID: 91)
            await timeline.updatePlayerState(
                .playing, positionSeconds: 12, message: "Already playing.")
            let before = await timeline.snapshot()
            let adapter = AVFoundationAppPCMPlayerAdapter(
                engineStarter: { XCTFail("Empty frames should not start the engine") },
                bufferScheduler: { _ in XCTFail("Empty frames should not schedule buffers") },
                playerStarter: { XCTFail("Empty frames should not start playback") }
            )

            try await adapter.play([], timeline: timeline)

            let after = await timeline.snapshot()
            XCTAssertEqual(after, before)
        #endif
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

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment(by amount: Int) {
        lock.lock()
        storage += amount
        lock.unlock()
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
