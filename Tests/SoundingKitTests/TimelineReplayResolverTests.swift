import Foundation
import GRDB
import XCTest

@testable import SoundingKit

final class TimelineReplayResolverTests: XCTestCase {
    func testReplayPrefersRollingBufferOverArchive() async throws {
        let fixture = try ReplayArchiveFixture()
        defer { fixture.cleanup() }

        try fixture.archive(
            frame: frame(streamID: fixture.streamID, sequence: 1, start: 10, end: 20, bytes: [9])
        )
        let rolling = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: 60,
                hotMemoryDurationSeconds: 60,
                maximumSpillBytes: 0
            )
        )
        await rolling.start(streamID: fixture.streamID)
        _ = await rolling.append([
            frame(streamID: fixture.streamID, sequence: 2, start: 10, end: 20, bytes: [7])
        ])

        let result = await TimelineReplayResolver(
            rollingBuffer: rolling,
            audioArchiveStore: fixture.archiveStore
        )
        .resolve(streamID: fixture.streamID, seconds: 12)

        guard case .available(let resolvedFrame, let source) = result else {
            return XCTFail("Expected playable frame")
        }
        XCTAssertEqual(source, .rollingBuffer)
        XCTAssertEqual(resolvedFrame.audio, Data([7]))
    }

    func testReplayFallsBackToAudioArchiveWhenRollingBufferMisses() async throws {
        let fixture = try ReplayArchiveFixture()
        defer { fixture.cleanup() }

        try fixture.archive(
            frame: frame(streamID: fixture.streamID, sequence: 4, start: 100, end: 110, bytes: [4])
        )
        let rolling = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: 60,
                hotMemoryDurationSeconds: 60,
                maximumSpillBytes: 0
            )
        )
        await rolling.start(streamID: fixture.streamID)
        _ = await rolling.append([
            frame(streamID: fixture.streamID, sequence: 5, start: 10, end: 20, bytes: [5])
        ])

        let result = await TimelineReplayResolver(
            rollingBuffer: rolling,
            audioArchiveStore: fixture.archiveStore
        )
        .resolve(streamID: fixture.streamID, seconds: 105)

        guard case .available(let resolvedFrame, let source) = result else {
            return XCTFail("Expected archived frame")
        }
        XCTAssertEqual(source, .audioArchive)
        XCTAssertEqual(resolvedFrame.sequence, 4)
        XCTAssertEqual(resolvedFrame.audio, Data([4]))
    }

    func testReplayUnavailableIncludesCurrentBufferedRange() async throws {
        let rolling = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: 60,
                hotMemoryDurationSeconds: 60,
                maximumSpillBytes: 0
            )
        )
        await rolling.start(streamID: 123)
        _ = await rolling.append([
            frame(streamID: 123, sequence: 1, start: 10, end: 20, bytes: [1])
        ])

        let result = await TimelineReplayResolver(
            rollingBuffer: rolling,
            audioArchiveStore: nil
        )
        .resolve(streamID: 123, seconds: 45)

        XCTAssertEqual(
            result,
            .unavailable(
                requestedSeconds: 45,
                bufferedRange: RollingBufferRange(startSeconds: 10, endSeconds: 20),
                reason: "Requested time is not available in rolling buffer or audio archive."
            )
        )
    }

    private func frame(
        streamID: Int64,
        sequence: Int,
        start: Double,
        end: Double,
        bytes: [UInt8]
    ) -> SharedPCMFrame {
        SharedPCMFrame(
            streamID: streamID,
            sequence: sequence,
            audio: Data(bytes),
            startSeconds: start,
            endSeconds: end,
            format: .linearPCM(sampleRate: 44_100, channelCount: 1)
        )
    }
}

private final class ReplayArchiveFixture {
    let temporary: TemporarySoundingDatabase
    let archiveDirectory: URL
    let archiveStore: AudioArchiveStore
    let streamID: Int64
    private let runID: Int64
    private let chunkID: Int64

    init() throws {
        temporary = try TemporarySoundingDatabase()
        archiveDirectory = temporary.fileURL.deletingLastPathComponent()
            .appendingPathComponent("SoundingReplayArchive-\(UUID().uuidString)", isDirectory: true)
        archiveStore = AudioArchiveStore(
            database: temporary.database,
            archiveDirectory: archiveDirectory
        )
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Replay",
            streamType: .hls,
            source: "https://example.test/live.m3u8"
        )
        streamID = stream.id
        let identifiers = try temporary.database.write { db -> (runID: Int64, chunkID: Int64) in
            try db.execute(
                sql: """
                    INSERT INTO ingest_runs (stream_id, started_at, status)
                    VALUES (?, ?, ?)
                    """,
                arguments: [stream.id, "2026-05-01T10:00:00Z", "running"]
            )
            let runID = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO ingest_chunks (run_id, sequence, byte_count, started_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [runID, 7, 4, "2026-05-01T10:00:01Z"]
            )
            return (runID: runID, chunkID: db.lastInsertedRowID)
        }
        runID = identifiers.runID
        chunkID = identifiers.chunkID
    }

    func archive(frame: SharedPCMFrame) throws {
        _ = try archiveStore.archive(frame: frame, runID: runID, chunkID: chunkID)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: archiveDirectory)
    }
}
