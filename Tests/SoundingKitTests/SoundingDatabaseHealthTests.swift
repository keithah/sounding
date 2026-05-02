import Foundation
import GRDB
import XCTest
@testable import SoundingKit

final class SoundingDatabaseHealthTests: XCTestCase {
    func testHealthyTemporaryDatabaseReportsWALMetricsAndCheckSummaries() throws {
        let temporary = try TemporarySoundingDatabase()

        let health = temporary.database.health()

        XCTAssertEqual(health.status, .healthy)
        XCTAssertEqual(health.journalMode.lowercased(), "wal")
        XCTAssertGreaterThan(health.walAutoCheckpointPages, 0)
        XCTAssertGreaterThan(health.pageSizeBytes, 0)
        XCTAssertGreaterThanOrEqual(health.pageCount, 0)
        XCTAssertGreaterThan(health.files.databaseBytes, 0)
        XCTAssertGreaterThanOrEqual(health.files.walBytes ?? 0, 0)
        XCTAssertGreaterThanOrEqual(health.files.shmBytes ?? 0, 0)
        XCTAssertEqual(health.quickCheck.status, .ok)
        XCTAssertEqual(health.foreignKeyCheck.status, .ok)
        XCTAssertNil(health.integrityCheck)
        XCTAssertNil(health.failure)
        XCTAssertFalse(String(describing: health).contains(temporary.fileURL.path))
    }

    func testPassiveCheckpointReturnsCountersAndDoesNotRemoveRuntimeStatusRows() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Health",
            streamType: "hls",
            source: "https://user:pass@example.test/live.m3u8?token=secret#frag",
            createdAt: "2026-05-01T10:00:00Z"
        )
        let store = AppStreamRuntimeStatusStore(database: temporary.database)
        try store.upsert(
            AppStreamRuntimeStatusUpdate(
                streamID: stream.id,
                phase: .running,
                attempt: 1,
                maxAttempts: 3,
                updatedAt: "2026-05-01T10:00:01Z"
            )
        )

        let before = try XCTUnwrap(try store.status(streamID: stream.id))
        let checkpoint = temporary.database.checkpoint()
        let after = try XCTUnwrap(try store.status(streamID: stream.id))

        XCTAssertEqual(before, after)
        XCTAssertEqual(checkpoint.status, .healthy)
        XCTAssertGreaterThanOrEqual(checkpoint.logFrameCount, 0)
        XCTAssertGreaterThanOrEqual(checkpoint.checkpointedFrameCount, 0)
        XCTAssertGreaterThanOrEqual(checkpoint.busyFrameCount, 0)
        XCTAssertNil(checkpoint.failure)
        XCTAssertFalse(String(describing: checkpoint).contains(temporary.fileURL.path))
    }

    func testIntegrityCheckCanBeRequestedExplicitly() throws {
        let temporary = try TemporarySoundingDatabase()

        let health = temporary.database.health(includeIntegrityCheck: true)

        XCTAssertEqual(health.status, .healthy)
        XCTAssertEqual(health.integrityCheck?.status, .ok)
        XCTAssertEqual(health.integrityCheck?.issueCount, 0)
    }

    func testOpenFailureIsClassifiedAndRedacted() throws {
        let secretURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("secret-token=synthetic-secret-")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("missing.sqlite")

        let health = SoundingDatabase.health(fileURL: secretURL)

        XCTAssertEqual(health.status, .unhealthy)
        XCTAssertEqual(health.failure?.phase, .open)
        XCTAssertEqual(health.failure?.guidance, .openDatabase)
        let described = String(describing: health)
        XCTAssertFalse(described.contains(secretURL.path))
        XCTAssertFalse(described.contains("synthetic-secret"))
        XCTAssertFalse(described.contains("token="))
    }

    func testCorruptDatabaseBytesAreClassifiedWithoutRawPathOrGRDBMessage() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-corrupt-token=synthetic-secret-\(UUID().uuidString).sqlite")
        try Data("not sqlite".utf8).write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(atPath: fileURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: fileURL.path + "-shm")
        }

        let health = SoundingDatabase.health(fileURL: fileURL)

        XCTAssertEqual(health.status, .unhealthy)
        XCTAssertEqual(health.failure?.phase, .open)
        XCTAssertEqual(health.failure?.guidance, .corruption)
        let described = String(describing: health)
        XCTAssertFalse(described.contains(fileURL.path))
        XCTAssertFalse(described.contains("synthetic-secret"))
        XCTAssertFalse(described.contains("SQLite error"))
        XCTAssertFalse(described.contains("GRDB"))
    }

    func testTemporaryDatabaseCleanupRemovesDashNamedSQLiteCompanionFiles() throws {
        var dbURL: URL?
        var walPath: String?
        var shmPath: String?

        do {
            let temporary = try TemporarySoundingDatabase()
            dbURL = temporary.fileURL
            walPath = temporary.fileURL.path + "-wal"
            shmPath = temporary.fileURL.path + "-shm"
            FileManager.default.createFile(atPath: try XCTUnwrap(walPath), contents: Data(), attributes: nil)
            FileManager.default.createFile(atPath: try XCTUnwrap(shmPath), contents: Data(), attributes: nil)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(dbURL).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(walPath)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(shmPath)))
    }
}
