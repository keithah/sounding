import Foundation
import GRDB
import XCTest
@testable import SoundingKit

final class AudioArchiveStoreTests: XCTestCase {
    func testWritesIndexesAndReadsArchivedFrame() throws {
        let temporary = try TemporarySoundingDatabase()
        let archiveDirectory = temporary.fileURL.deletingLastPathComponent()
            .appendingPathComponent("SoundingArchive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archiveDirectory) }

        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "JFL",
            streamType: .hls,
            source: "https://example.test/live.m3u8"
        )
        let identifiers = try makeRunAndChunk(database: temporary.database, streamID: stream.id)
        let store = AudioArchiveStore(
            database: temporary.database,
            archiveDirectory: archiveDirectory
        )

        let frame = SharedPCMFrame(
            streamID: stream.id,
            sequence: 7,
            audio: Data([1, 2, 3, 4]),
            startSeconds: 12,
            endSeconds: 18,
            format: .linearPCM(sampleRate: 48_000, channelCount: 2)
        )

        let row = try store.archive(
            frame: frame,
            runID: identifiers.runID,
            chunkID: identifiers.chunkID
        )
        XCTAssertEqual(row.streamID, stream.id)
        XCTAssertEqual(row.startSeconds, 12)
        XCTAssertEqual(row.sampleRate, 48_000)
        XCTAssertEqual(row.channelCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.fileURL.path))

        let resolved = try XCTUnwrap(store.frame(streamID: stream.id, seconds: 12.5))
        XCTAssertEqual(resolved.frame.audio, Data([1, 2, 3, 4]))
        XCTAssertEqual(resolved.frame.format.sampleRate, 48_000)
        XCTAssertEqual(resolved.frame.format.channelCount, 2)
        XCTAssertEqual(resolved.row.id, row.id)
    }

    func testUpsertReturnsPersistedRowAndPointsAtWinningContentFile() throws {
        let temporary = try TemporarySoundingDatabase()
        let archiveDirectory = temporary.fileURL.deletingLastPathComponent()
            .appendingPathComponent("SoundingArchive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archiveDirectory) }

        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "JFL",
            streamType: .hls,
            source: "https://example.test/live.m3u8"
        )
        let identifiers = try makeRunAndChunk(database: temporary.database, streamID: stream.id)
        let store = AudioArchiveStore(
            database: temporary.database,
            archiveDirectory: archiveDirectory
        )

        let first = try store.archive(
            frame: SharedPCMFrame(
                streamID: stream.id,
                sequence: 7,
                audio: Data([1, 2, 3, 4]),
                startSeconds: 12,
                endSeconds: 18,
                format: .linearPCM(sampleRate: 48_000, channelCount: 2)
            ),
            runID: identifiers.runID,
            chunkID: identifiers.chunkID
        )
        let second = try store.archive(
            frame: SharedPCMFrame(
                streamID: stream.id,
                sequence: 7,
                audio: Data([9, 8, 7, 6]),
                startSeconds: 12,
                endSeconds: 19,
                format: .linearPCM(sampleRate: 48_000, channelCount: 2)
            ),
            runID: identifiers.runID,
            chunkID: identifiers.chunkID
        )

        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.createdAt, first.createdAt)
        XCTAssertNotEqual(second.sha256, first.sha256)

        let resolved = try XCTUnwrap(store.frame(streamID: stream.id, seconds: 18.5))
        XCTAssertEqual(resolved.frame.audio, Data([9, 8, 7, 6]))
        XCTAssertEqual(resolved.row, second)
    }

    func testRejectsFramesWithoutConcreteLinearPCMFormat() throws {
        let temporary = try TemporarySoundingDatabase()
        let archiveDirectory = temporary.fileURL.deletingLastPathComponent()
            .appendingPathComponent("SoundingArchive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archiveDirectory) }

        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "JFL",
            streamType: .hls,
            source: "https://example.test/live.m3u8"
        )
        let identifiers = try makeRunAndChunk(database: temporary.database, streamID: stream.id)
        let store = AudioArchiveStore(
            database: temporary.database,
            archiveDirectory: archiveDirectory
        )
        let frame = SharedPCMFrame(
            streamID: stream.id,
            sequence: 7,
            audio: Data([1, 2, 3, 4]),
            startSeconds: 12,
            endSeconds: 18,
            format: .unknown
        )

        XCTAssertThrowsError(
            try store.archive(frame: frame, runID: identifiers.runID, chunkID: identifiers.chunkID)
        ) { error in
            XCTAssertEqual(error as? AudioArchiveStoreError, .invalidLinearPCMFormat)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveDirectory.path))
    }

    func testArchiveUsesFrameByteCountAsValidAudioPrefix() throws {
        let temporary = try TemporarySoundingDatabase()
        let archiveDirectory = temporary.fileURL.deletingLastPathComponent()
            .appendingPathComponent("SoundingArchive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archiveDirectory) }

        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "JFL",
            streamType: .hls,
            source: "https://example.test/live.m3u8"
        )
        let identifiers = try makeRunAndChunk(database: temporary.database, streamID: stream.id)
        let store = AudioArchiveStore(
            database: temporary.database,
            archiveDirectory: archiveDirectory
        )
        let frame = SharedPCMFrame(
            streamID: stream.id,
            sequence: 7,
            audio: Data([1, 2, 3, 4, 99, 100]),
            byteCount: 4,
            startSeconds: 12,
            endSeconds: 18,
            format: .linearPCM(sampleRate: 48_000, channelCount: 2)
        )

        let row = try store.archive(frame: frame, runID: identifiers.runID, chunkID: identifiers.chunkID)
        XCTAssertEqual(row.byteCount, 4)
        XCTAssertEqual(try Data(contentsOf: row.fileURL), Data([1, 2, 3, 4]))

        let resolved = try XCTUnwrap(store.frame(streamID: stream.id, seconds: 12.5))
        XCTAssertEqual(resolved.frame.audio, Data([1, 2, 3, 4]))
        XCTAssertEqual(resolved.frame.byteCount, 4)
    }

    func testReadRejectsCorruptArchiveFile() throws {
        let temporary = try TemporarySoundingDatabase()
        let archiveDirectory = temporary.fileURL.deletingLastPathComponent()
            .appendingPathComponent("SoundingArchive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archiveDirectory) }

        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "JFL",
            streamType: .hls,
            source: "https://example.test/live.m3u8"
        )
        let identifiers = try makeRunAndChunk(database: temporary.database, streamID: stream.id)
        let store = AudioArchiveStore(
            database: temporary.database,
            archiveDirectory: archiveDirectory
        )
        let row = try store.archive(
            frame: SharedPCMFrame(
                streamID: stream.id,
                sequence: 7,
                audio: Data([1, 2, 3, 4]),
                startSeconds: 12,
                endSeconds: 18,
                format: .linearPCM(sampleRate: 48_000, channelCount: 2)
            ),
            runID: identifiers.runID,
            chunkID: identifiers.chunkID
        )
        try Data([1, 2]).write(to: row.fileURL, options: .atomic)

        XCTAssertThrowsError(try store.frame(streamID: stream.id, seconds: 12.5)) { error in
            XCTAssertEqual(error as? AudioArchiveStoreError, .archiveFileCorrupt)
        }
    }

    func testArchiveRejectsMismatchedStreamRunChunkIdentity() throws {
        let temporary = try TemporarySoundingDatabase()
        let archiveDirectory = temporary.fileURL.deletingLastPathComponent()
            .appendingPathComponent("SoundingArchive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archiveDirectory) }

        let registry = StreamRegistry(database: temporary.database)
        let first = try registry.add(
            name: "First",
            streamType: .hls,
            source: "https://example.test/first.m3u8"
        )
        let second = try registry.add(
            name: "Second",
            streamType: .hls,
            source: "https://example.test/second.m3u8"
        )
        let secondIdentifiers = try makeRunAndChunk(
            database: temporary.database,
            streamID: second.id
        )
        let store = AudioArchiveStore(
            database: temporary.database,
            archiveDirectory: archiveDirectory
        )

        XCTAssertThrowsError(
            try store.archive(
                frame: SharedPCMFrame(
                    streamID: first.id,
                    sequence: 7,
                    audio: Data([1, 2, 3, 4]),
                    startSeconds: 12,
                    endSeconds: 18,
                    format: .linearPCM(sampleRate: 48_000, channelCount: 2)
                ),
                runID: secondIdentifiers.runID,
                chunkID: secondIdentifiers.chunkID
            )
        ) { error in
            XCTAssertEqual(error as? AudioArchiveStoreError, .archiveIdentityMismatch)
        }
    }

    func testArchiveRewritesCorruptExistingContentAddressedFile() throws {
        let temporary = try TemporarySoundingDatabase()
        let archiveDirectory = temporary.fileURL.deletingLastPathComponent()
            .appendingPathComponent("SoundingArchive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archiveDirectory) }

        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "JFL",
            streamType: .hls,
            source: "https://example.test/live.m3u8"
        )
        let identifiers = try makeRunAndChunk(database: temporary.database, streamID: stream.id)
        let store = AudioArchiveStore(
            database: temporary.database,
            archiveDirectory: archiveDirectory
        )
        let frame = SharedPCMFrame(
            streamID: stream.id,
            sequence: 7,
            audio: Data([1, 2, 3, 4]),
            startSeconds: 12,
            endSeconds: 18,
            format: .linearPCM(sampleRate: 48_000, channelCount: 2)
        )
        let row = try store.archive(frame: frame, runID: identifiers.runID, chunkID: identifiers.chunkID)
        try Data([9, 9, 9, 9]).write(to: row.fileURL, options: .atomic)

        let rewritten = try store.archive(frame: frame, runID: identifiers.runID, chunkID: identifiers.chunkID)

        XCTAssertEqual(rewritten.id, row.id)
        XCTAssertEqual(try Data(contentsOf: rewritten.fileURL), Data([1, 2, 3, 4]))
        XCTAssertEqual(try XCTUnwrap(store.frame(streamID: stream.id, seconds: 12.5)).frame.audio, Data([1, 2, 3, 4]))
    }

    func testMaximumBytesPrunesOldestArchivedRowsAndFiles() throws {
        let temporary = try TemporarySoundingDatabase()
        let archiveDirectory = temporary.fileURL.deletingLastPathComponent()
            .appendingPathComponent("SoundingArchive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archiveDirectory) }

        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "JFL",
            streamType: .hls,
            source: "https://example.test/live.m3u8"
        )
        let firstIdentifiers = try makeRunAndChunk(database: temporary.database, streamID: stream.id)
        let secondIdentifiers = try makeRunAndChunk(database: temporary.database, streamID: stream.id)
        let store = AudioArchiveStore(
            database: temporary.database,
            archiveDirectory: archiveDirectory,
            maximumBytes: 4
        )

        let first = try store.archive(
            frame: SharedPCMFrame(
                streamID: stream.id,
                sequence: 7,
                audio: Data([1, 2, 3, 4]),
                startSeconds: 0,
                endSeconds: 4,
                format: .linearPCM(sampleRate: 48_000, channelCount: 2)
            ),
            runID: firstIdentifiers.runID,
            chunkID: firstIdentifiers.chunkID
        )
        let second = try store.archive(
            frame: SharedPCMFrame(
                streamID: stream.id,
                sequence: 7,
                audio: Data([5, 6, 7, 8]),
                startSeconds: 4,
                endSeconds: 8,
                format: .linearPCM(sampleRate: 48_000, channelCount: 2)
            ),
            runID: secondIdentifiers.runID,
            chunkID: secondIdentifiers.chunkID
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.fileURL.path))
        XCTAssertNil(try store.frame(streamID: stream.id, seconds: 1))
        XCTAssertEqual(try XCTUnwrap(store.frame(streamID: stream.id, seconds: 5)).row.id, second.id)
    }

    func testRetentionPrunesExpiredRowsAndFiles() throws {
        let temporary = try TemporarySoundingDatabase()
        let archiveDirectory = temporary.fileURL.deletingLastPathComponent()
            .appendingPathComponent("SoundingArchive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archiveDirectory) }

        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "JFL",
            streamType: .hls,
            source: "https://example.test/live.m3u8"
        )
        let firstIdentifiers = try makeRunAndChunk(database: temporary.database, streamID: stream.id)
        let secondIdentifiers = try makeRunAndChunk(database: temporary.database, streamID: stream.id)
        let store = AudioArchiveStore(
            database: temporary.database,
            archiveDirectory: archiveDirectory,
            retentionSeconds: 60
        )
        let expired = try store.archive(
            frame: SharedPCMFrame(
                streamID: stream.id,
                sequence: 7,
                audio: Data([1, 2, 3, 4]),
                startSeconds: 0,
                endSeconds: 4,
                format: .linearPCM(sampleRate: 48_000, channelCount: 2)
            ),
            runID: firstIdentifiers.runID,
            chunkID: firstIdentifiers.chunkID
        )
        try temporary.database.write { db in
            try db.execute(
                sql: "UPDATE audio_archive_segments SET created_at = ? WHERE id = ?",
                arguments: ["2000-01-01T00:00:00Z", expired.id]
            )
        }

        _ = try store.archive(
            frame: SharedPCMFrame(
                streamID: stream.id,
                sequence: 7,
                audio: Data([5, 6, 7, 8]),
                startSeconds: 4,
                endSeconds: 8,
                format: .linearPCM(sampleRate: 48_000, channelCount: 2)
            ),
            runID: secondIdentifiers.runID,
            chunkID: secondIdentifiers.chunkID
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.fileURL.path))
        XCTAssertNil(try store.frame(streamID: stream.id, seconds: 1))
    }

    func testRejectsUnsafeArchiveRelativePathOnRead() throws {
        let temporary = try TemporarySoundingDatabase()
        let archiveDirectory = temporary.fileURL.deletingLastPathComponent()
            .appendingPathComponent("SoundingArchive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archiveDirectory) }

        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "JFL",
            streamType: .hls,
            source: "https://example.test/live.m3u8"
        )
        let identifiers = try makeRunAndChunk(database: temporary.database, streamID: stream.id)
        try temporary.database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audio_archive_segments (
                        stream_id, run_id, chunk_id, sequence, start_seconds, end_seconds,
                        sample_rate, channel_count, byte_count, sha256, relative_path, created_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    stream.id,
                    identifiers.runID,
                    identifiers.chunkID,
                    7,
                    12,
                    18,
                    48_000,
                    2,
                    4,
                    "abcd",
                    "../outside.pcm",
                    "2026-05-01T10:00:00Z",
                ]
            )
        }

        let store = AudioArchiveStore(
            database: temporary.database,
            archiveDirectory: archiveDirectory
        )
        XCTAssertThrowsError(try store.frame(streamID: stream.id, seconds: 12.5)) { error in
            XCTAssertEqual(
                error as? AudioArchiveStoreError,
                .unsafeRelativePath("../outside.pcm")
            )
        }
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
                arguments: [runID, 7, 4, "2026-05-01T10:00:01Z"]
            )
            return (runID: runID, chunkID: db.lastInsertedRowID)
        }
    }
}
