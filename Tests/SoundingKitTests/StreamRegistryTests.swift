import GRDB
import XCTest
@testable import SoundingKit

final class StreamRegistryTests: XCTestCase {
    func testAddListAndFindStoreRedactedSourceDescription() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)

        let record = try registry.add(
            name: "  Main Stream  ",
            streamType: " hls ",
            source: "https://user:pass@example.test/private/live.m3u8?token=secret#frag",
            createdAt: "2026-05-01T10:00:00Z"
        )

        XCTAssertEqual(record.name, "Main Stream")
        XCTAssertEqual(record.streamType, "hls")
        XCTAssertEqual(record.sourceDescription, "https://example.test/private/live.m3u8")
        XCTAssertEqual(record.status, .active)
        XCTAssertFalse(record.diarizationEnabled)
        XCTAssertEqual(record.createdAt, "2026-05-01T10:00:00Z")
        XCTAssertEqual(record.updatedAt, "2026-05-01T10:00:00Z")
        XCTAssertNil(record.pausedAt)
        XCTAssertNil(record.resumedAt)
        XCTAssertNil(record.removedAt)

        XCTAssertEqual(try registry.list(), [record])
        XCTAssertEqual(try registry.find(id: record.id), record)
        XCTAssertEqual(try registry.find(name: "Main Stream"), record)

        let stored = try temporary.database.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT source, source_url FROM streams WHERE id = ?",
                arguments: [record.id]
            )
        }
        XCTAssertEqual(stored?["source"] as String?, "https://example.test/private/live.m3u8")
        XCTAssertEqual(
            stored?["source_url"] as String?,
            "https://user:pass@example.test/private/live.m3u8?token=secret#frag"
        )
    }

    func testTypedStreamTypeOverloadsPersistRawRegistryValue() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)

        let record = try registry.add(
            name: "Typed",
            streamType: .hls,
            source: "https://example.test/live.m3u8"
        )
        let reconnect = try XCTUnwrap(registry.reconnectSource(id: record.id))

        XCTAssertEqual(record.streamType, "hls")
        XCTAssertEqual(record.resolvedStreamType, .hls)
        XCTAssertEqual(reconnect.streamType, "hls")
        XCTAssertEqual(reconnect.resolvedStreamType, .hls)

        let updated = try registry.update(
            id: record.id,
            name: "Typed",
            streamType: .icy,
            source: "https://example.test/live.icy"
        )

        XCTAssertTrue(updated.changed)
        XCTAssertEqual(updated.record.streamType, "icy")
        XCTAssertEqual(updated.record.resolvedStreamType, .icy)
    }

    func testDiarizationSettingIsPerStreamAndPersists() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)

        let first = try registry.add(
            name: "Main",
            streamType: "hls",
            source: "https://example.test/main.m3u8",
            createdAt: "2026-05-01T10:00:00Z"
        )
        let second = try registry.add(
            name: "Backup",
            streamType: "hls",
            source: "https://example.test/backup.m3u8",
            createdAt: "2026-05-01T10:00:00Z"
        )

        let enabled = try registry.setDiarizationEnabled(
            id: first.id,
            isEnabled: true,
            updatedAt: "2026-05-01T10:01:00Z"
        )

        XCTAssertTrue(enabled.changed)
        XCTAssertTrue(enabled.record.diarizationEnabled)
        XCTAssertEqual(enabled.record.updatedAt, "2026-05-01T10:01:00Z")
        XCTAssertTrue(try XCTUnwrap(registry.find(id: first.id)).diarizationEnabled)
        XCTAssertFalse(try XCTUnwrap(registry.find(id: second.id)).diarizationEnabled)
        XCTAssertTrue(try XCTUnwrap(registry.reconnectSource(id: first.id)).diarizationEnabled)

        let enabledAgain = try registry.setDiarizationEnabled(
            id: first.id,
            isEnabled: true,
            updatedAt: "2026-05-01T10:02:00Z"
        )
        XCTAssertFalse(enabledAgain.changed)
        XCTAssertEqual(enabledAgain.record.updatedAt, "2026-05-01T10:01:00Z")
    }

    func testAudioArchiveSettingIsPerStreamAndPersists() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "JFL",
            streamType: .hls,
            source: "https://example.test/live.m3u8"
        )

        XCTAssertFalse(stream.audioArchiveEnabled)

        let enabled = try registry.updateAudioArchive(
            streamID: stream.id,
            isEnabled: true,
            updatedAt: "2026-05-01T10:01:00Z"
        )
        XCTAssertTrue(enabled.record.audioArchiveEnabled)
        XCTAssertTrue(enabled.changed)
        XCTAssertEqual(enabled.record.updatedAt, "2026-05-01T10:01:00Z")

        let unchanged = try registry.updateAudioArchive(
            streamID: stream.id,
            isEnabled: true,
            updatedAt: "2026-05-01T10:02:00Z"
        )
        XCTAssertTrue(unchanged.record.audioArchiveEnabled)
        XCTAssertFalse(unchanged.changed)
        XCTAssertEqual(unchanged.record.updatedAt, "2026-05-01T10:01:00Z")

        XCTAssertTrue(try XCTUnwrap(registry.find(id: stream.id)).audioArchiveEnabled)
        XCTAssertTrue(try XCTUnwrap(registry.reconnectSource(id: stream.id)).audioArchiveEnabled)
    }

    func testReconnectSourceExposesRawSourceWithoutChangingListRedaction() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let rawSource = "https://user:pass@example.test/private/live.m3u8?token=secret#frag"

        let record = try registry.add(
            name: "Main",
            streamType: "hls",
            source: rawSource,
            createdAt: "2026-05-01T10:00:00Z"
        )

        XCTAssertEqual(try registry.find(id: record.id)?.sourceDescription, "https://example.test/private/live.m3u8")
        XCTAssertEqual(try registry.list().first?.sourceDescription, "https://example.test/private/live.m3u8")

        let reconnect = try XCTUnwrap(registry.reconnectSource(id: record.id))
        XCTAssertEqual(reconnect.streamID, record.id)
        XCTAssertEqual(reconnect.name, "Main")
        XCTAssertEqual(reconnect.streamType, "hls")
        XCTAssertEqual(reconnect.source, rawSource)
        XCTAssertEqual(reconnect.sourceDescription, "https://example.test/private/live.m3u8")
    }

    func testUpdateChangesEditableStreamFieldsAndKeepsRawSourcePrivate() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let record = try registry.add(
            name: "Main",
            streamType: "hls",
            source: "https://example.test/old.m3u8",
            createdAt: "2026-05-01T10:00:00Z"
        )

        let result = try registry.update(
            id: record.id,
            name: "  Renamed  ",
            streamType: " icy ",
            source: "https://user:pass@example.test/private/live?token=secret",
            updatedAt: "2026-05-01T10:05:00Z"
        )

        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.record.name, "Renamed")
        XCTAssertEqual(result.record.streamType, "icy")
        XCTAssertEqual(result.record.sourceDescription, "https://example.test/private/live")
        XCTAssertEqual(result.record.updatedAt, "2026-05-01T10:05:00Z")
        XCTAssertEqual(try registry.list().map(\.name), ["Renamed"])
        XCTAssertEqual(
            try registry.reconnectSource(id: record.id)?.source,
            "https://user:pass@example.test/private/live?token=secret"
        )
    }

    func testReconnectSourceFallsBackToRedactedCompatibilitySourceForLegacyRows() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)

        try temporary.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO streams (name, stream_type, source, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "Legacy",
                    "hls",
                    "https://example.test/legacy.m3u8",
                    StreamStatus.active.rawValue,
                    "2026-05-01T10:00:00Z",
                    "2026-05-01T10:00:00Z"
                ]
            )
        }

        let reconnect = try XCTUnwrap(registry.reconnectSource(id: 1))
        XCTAssertEqual(reconnect.source, "https://example.test/legacy.m3u8")
        XCTAssertEqual(reconnect.sourceDescription, "https://example.test/legacy.m3u8")
    }

    func testRejectsEmptyInputsAndMalformedIDsBeforeMutation() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)

        XCTAssertThrowsError(try registry.add(name: " ", streamType: "hls", source: "https://example.test/live")) { error in
            XCTAssertEqual(error as? StreamRegistryError, .invalidName)
        }
        XCTAssertThrowsError(try registry.add(name: "Main", streamType: " ", source: "https://example.test/live")) { error in
            XCTAssertEqual(error as? StreamRegistryError, .invalidStreamType)
        }
        XCTAssertThrowsError(try registry.add(name: "Main", streamType: "hls", source: " ")) { error in
            XCTAssertEqual(error as? StreamRegistryError, .invalidSource)
        }
        XCTAssertThrowsError(try registry.find(id: 0)) { error in
            XCTAssertEqual(error as? StreamRegistryError, .invalidID)
        }
        XCTAssertThrowsError(try registry.pause(id: -1)) { error in
            XCTAssertEqual(error as? StreamRegistryError, .invalidID)
        }

        let count = try temporary.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM streams WHERE name IS NOT NULL")
        }
        XCTAssertEqual(count, 0)
    }

    func testDuplicateActiveNamesFailButRemovedNamesCanBeReused() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)

        let first = try registry.add(
            name: "Main",
            streamType: "hls",
            source: "https://example.test/one.m3u8",
            createdAt: "2026-05-01T10:00:00Z"
        )

        XCTAssertThrowsError(
            try registry.add(name: "Main", streamType: "icy", source: "https://example.test/two")
        ) { error in
            XCTAssertEqual(error as? StreamRegistryError, .duplicateName)
        }

        let removal = try registry.remove(id: first.id, removedAt: "2026-05-01T10:01:00Z")
        XCTAssertTrue(removal.changed)
        XCTAssertEqual(removal.record.status, .removed)

        let second = try registry.add(
            name: "Main",
            streamType: "icy",
            source: "https://example.test/two",
            createdAt: "2026-05-01T10:02:00Z"
        )
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.status, .active)
    }

    func testPauseResumeAndRemoveExposeChangedFlagForIdempotence() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let record = try registry.add(
            name: "Main",
            streamType: "hls",
            source: "https://example.test/live.m3u8",
            createdAt: "2026-05-01T10:00:00Z"
        )

        let paused = try registry.pause(id: record.id, pausedAt: "2026-05-01T10:01:00Z")
        XCTAssertTrue(paused.changed)
        XCTAssertEqual(paused.record.status, .paused)
        XCTAssertEqual(paused.record.pausedAt, "2026-05-01T10:01:00Z")

        let pausedAgain = try registry.pause(id: record.id, pausedAt: "2026-05-01T10:02:00Z")
        XCTAssertFalse(pausedAgain.changed)
        XCTAssertEqual(pausedAgain.record.status, .paused)
        XCTAssertEqual(pausedAgain.record.pausedAt, "2026-05-01T10:01:00Z")

        let resumed = try registry.resume(id: record.id, resumedAt: "2026-05-01T10:03:00Z")
        XCTAssertTrue(resumed.changed)
        XCTAssertEqual(resumed.record.status, .active)
        XCTAssertEqual(resumed.record.resumedAt, "2026-05-01T10:03:00Z")

        let resumedAgain = try registry.resume(id: record.id, resumedAt: "2026-05-01T10:04:00Z")
        XCTAssertFalse(resumedAgain.changed)
        XCTAssertEqual(resumedAgain.record.status, .active)
        XCTAssertEqual(resumedAgain.record.resumedAt, "2026-05-01T10:03:00Z")

        let removed = try registry.remove(id: record.id, removedAt: "2026-05-01T10:05:00Z")
        XCTAssertTrue(removed.changed)
        XCTAssertEqual(removed.record.status, .removed)
        XCTAssertEqual(removed.record.removedAt, "2026-05-01T10:05:00Z")

        let removedAgain = try registry.remove(id: record.id, removedAt: "2026-05-01T10:06:00Z")
        XCTAssertFalse(removedAgain.changed)
        XCTAssertEqual(removedAgain.record.status, .removed)
        XCTAssertEqual(removedAgain.record.removedAt, "2026-05-01T10:05:00Z")
    }

    func testMissingAndRemovedStreamsAreHandledDeterministically() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)

        XCTAssertNil(try registry.find(id: 99_999))
        XCTAssertNil(try registry.find(name: "Missing"))
        XCTAssertThrowsError(try registry.pause(id: 99_999)) { error in
            XCTAssertEqual(error as? StreamRegistryError, .streamNotFound)
        }

        let record = try registry.add(
            name: "Main",
            streamType: "hls",
            source: "https://example.test/live.m3u8",
            createdAt: "2026-05-01T10:00:00Z"
        )
        _ = try registry.remove(id: record.id, removedAt: "2026-05-01T10:01:00Z")

        XCTAssertNil(try registry.find(id: record.id))
        XCTAssertEqual(try registry.find(id: record.id, includeRemoved: true)?.status, .removed)
        XCTAssertEqual(try registry.list(), [])
        XCTAssertEqual(try registry.list(includeRemoved: true).map(\.id), [record.id])
        XCTAssertThrowsError(try registry.pause(id: record.id, pausedAt: "2026-05-01T10:02:00Z")) { error in
            XCTAssertEqual(error as? StreamRegistryError, .streamRemoved)
        }
        XCTAssertThrowsError(try registry.resume(id: record.id, resumedAt: "2026-05-01T10:02:00Z")) { error in
            XCTAssertEqual(error as? StreamRegistryError, .streamRemoved)
        }
    }

    func testSoftRemovePreservesHistoricalIngestRows() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let persistence = IngestPersistence(database: temporary.database)

        let stream = try registry.add(
            name: "Main",
            streamType: "hls",
            source: "https://example.test/live.m3u8",
            createdAt: "2026-05-01T10:00:00Z"
        )
        let runID = try persistence.createRun(
            streamID: stream.id,
            startedAt: "2026-05-01T10:00:01Z",
            status: .running
        )
        let chunkID = try persistence.createChunk(
            runID: runID,
            sequence: 0,
            startedAt: "2026-05-01T10:00:02Z"
        )

        _ = try registry.remove(id: stream.id, removedAt: "2026-05-01T10:01:00Z")

        let counts = try temporary.database.read { db in
            try [
                "streams": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM streams WHERE id = ?", arguments: [stream.id]),
                "runs": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_runs WHERE id = ? AND stream_id = ?", arguments: [runID, stream.id]),
                "chunks": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_chunks WHERE id = ? AND run_id = ?", arguments: [chunkID, runID])
            ]
        }

        XCTAssertEqual(counts, ["streams": 1, "runs": 1, "chunks": 1])
    }

    func testSourceRedactionCoversCredentialsQueryFragmentsAndPathLikeInputs() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)

        let credential = try registry.add(
            name: "Credential",
            streamType: "hls",
            source: "https://user:pass@example.test/live.m3u8",
            createdAt: "2026-05-01T10:00:00Z"
        )
        let query = try registry.add(
            name: "Query",
            streamType: "hls",
            source: "https://example.test/live.m3u8?token=secret",
            createdAt: "2026-05-01T10:00:01Z"
        )
        let fragment = try registry.add(
            name: "Fragment",
            streamType: "hls",
            source: "https://example.test/live.m3u8#private",
            createdAt: "2026-05-01T10:00:02Z"
        )
        let path = try registry.add(
            name: "Path",
            streamType: "file",
            source: "/Users/alice/private/live.m3u8",
            createdAt: "2026-05-01T10:00:03Z"
        )

        XCTAssertEqual(credential.sourceDescription, "https://example.test/live.m3u8")
        XCTAssertEqual(query.sourceDescription, "https://example.test/live.m3u8")
        XCTAssertEqual(fragment.sourceDescription, "https://example.test/live.m3u8")
        XCTAssertEqual(path.sourceDescription, "[redacted-path]")

        for record in [credential, query, fragment, path] {
            XCTAssertFalse(record.sourceDescription.contains("user:pass"))
            XCTAssertFalse(record.sourceDescription.contains("token=secret"))
            XCTAssertFalse(record.sourceDescription.contains("#private"))
            XCTAssertFalse(record.sourceDescription.contains("/Users/alice"))
        }
    }
}
