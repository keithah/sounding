import GRDB
import XCTest
@testable import SoundingKit

final class AppStreamRuntimeStatusStoreTests: XCTestCase {
    func testUpsertAndReadStatusSnapshotRedactsRegistryAndFailureDetails() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Main",
            streamType: "hls",
            source: "https://user:pass@example.test/private/live.m3u8?token=secret#frag",
            createdAt: "2026-05-01T10:00:00Z"
        )
        let store = AppStreamRuntimeStatusStore(database: temporary.database)

        try store.upsert(
            AppStreamRuntimeStatusUpdate(
                streamID: stream.id,
                phase: .reconnecting,
                attempt: 2,
                maxAttempts: 3,
                nextRetrySeconds: 8,
                nextRetryAt: "2026-05-01T10:00:08Z",
                updatedAt: "2026-05-01T10:00:01Z",
                recentFailure: AppStreamRuntimeRecentFailure(
                    message: "Decoder failed for https://user:pass@example.test/private/live.m3u8?token=secret#frag at /Users/alice/private/evidence.wav api_key=secret",
                    occurredAt: "2026-05-01T10:00:01Z"
                )
            )
        )

        let snapshot = try XCTUnwrap(try store.status(streamID: stream.id))
        XCTAssertEqual(snapshot.streamID, stream.id)
        XCTAssertEqual(snapshot.name, "Main")
        XCTAssertEqual(snapshot.streamType, "hls")
        XCTAssertEqual(snapshot.sourceDescription, "https://example.test/private/live.m3u8")
        XCTAssertEqual(snapshot.phase, .reconnecting)
        XCTAssertEqual(snapshot.attempt, 2)
        XCTAssertEqual(snapshot.maxAttempts, 3)
        XCTAssertEqual(snapshot.nextRetrySeconds, 8)
        XCTAssertEqual(snapshot.nextRetryAt, "2026-05-01T10:00:08Z")
        XCTAssertEqual(snapshot.updatedAt, "2026-05-01T10:00:01Z")
        XCTAssertEqual(snapshot.recentFailure?.occurredAt, "2026-05-01T10:00:01Z")

        let described = String(describing: snapshot)
        XCTAssertFalse(described.contains("user:pass"))
        XCTAssertFalse(described.contains("token=secret"))
        XCTAssertFalse(described.contains("#frag"))
        XCTAssertFalse(described.contains("/Users/alice"))
        XCTAssertFalse(described.contains("api_key=secret"))
        XCTAssertTrue(described.contains("api_key=[redacted]"))
        XCTAssertTrue(described.contains("[redacted-path]"))
    }

    func testMalformedPersistedPhaseDecodesToActionableRedactedFailure() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Malformed",
            streamType: "hls",
            source: "https://user:pass@example.test/live.m3u8?token=secret",
            createdAt: "2026-05-01T10:00:00Z"
        )
        let store = AppStreamRuntimeStatusStore(database: temporary.database)

        try temporary.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO stream_runtime_status (
                    stream_id, phase, attempt, max_attempts, updated_at, recent_failure_message
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    stream.id,
                    "raw https://user:pass@example.test/live.m3u8?token=secret /Users/alice/private",
                    0,
                    3,
                    "2026-05-01T10:00:01Z",
                    "stored failure with token=secret at /Users/alice/private"
                ]
            )
        }

        let snapshot = try XCTUnwrap(try store.status(streamID: stream.id))
        XCTAssertEqual(snapshot.phase, .error)
        XCTAssertEqual(
            snapshot.recentFailure?.message,
            "Runtime status row contains an unsupported phase value. Clear or refresh the status row."
        )
        XCTAssertEqual(snapshot.recentFailure?.occurredAt, "2026-05-01T10:00:01Z")
        XCTAssertFalse(String(describing: snapshot).contains("token=secret"))
        XCTAssertFalse(String(describing: snapshot).contains("/Users/alice"))
        XCTAssertFalse(String(describing: snapshot).contains("user:pass"))
    }


    func testInspectionsExposeLatestRedactedHLSDecisionAndIgnoreMalformedContext() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let alpha = try registry.add(
            name: "Alpha",
            streamType: "hls",
            source: "https://user:pass@example.test/private/live.m3u8?token=synthetic-secret#frag",
            createdAt: "2026-05-01T10:00:00Z"
        )
        _ = try registry.add(
            name: "Beta",
            streamType: "hls",
            source: "https://example.test/beta.m3u8?token=synthetic-secret",
            createdAt: "2026-05-01T10:00:00Z"
        )
        let store = AppStreamRuntimeStatusStore(database: temporary.database)

        try temporary.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO ingest_diagnostics (
                    stream_id, phase, severity, reason, source, source_class, stream_type, context_json, created_at
                ) VALUES (?, 'persist', 'warning', 'hls-media-sequence-gap', NULL, 'hls_segment', 'hls', ?, ?)
                """,
                arguments: [
                    alpha.id,
                    "not-json https://user:pass@example.test/raw.m3u8?token=synthetic-secret#frag /Users/alice/private",
                    "2026-05-01T10:00:01Z"
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO ingest_diagnostics (
                    stream_id, run_id, chunk_id, phase, severity, reason, source, source_class, stream_type, context_json, created_at
                ) VALUES (?, ?, ?, 'persist', 'info', 'hls-segment-duplicate', NULL, 'hls_segment', 'hls', ?, ?)
                """,
                arguments: [
                    alpha.id,
                    42,
                    99,
                    """
                    {"decision":"duplicate-skip","mediaSequence":12,"segmentIdentity":"https://example.test/private/seg12.ts","segmentIdentityHash":"abc123","existingRunID":7,"existingChunkID":8,"currentRunID":42}
                    """,
                    "2026-05-01T10:00:02Z"
                ]
            )
        }

        let inspections = try store.inspections()
        XCTAssertEqual(inspections.map(\.name), ["Alpha", "Beta"])
        let alphaDecision = try XCTUnwrap(inspections.first?.latestHLSDecision)
        XCTAssertEqual(alphaDecision.reason, "hls-segment-duplicate")
        XCTAssertEqual(alphaDecision.severity, "info")
        XCTAssertEqual(alphaDecision.decision, "duplicate-skip")
        XCTAssertEqual(alphaDecision.mediaSequence, 12)
        XCTAssertEqual(alphaDecision.segmentIdentity, "https://example.test/private/seg12.ts")
        XCTAssertEqual(alphaDecision.segmentIdentityHash, "abc123")
        XCTAssertEqual(alphaDecision.currentRunID, 42)
        XCTAssertEqual(alphaDecision.existingRunID, 7)
        XCTAssertEqual(alphaDecision.existingChunkID, 8)
        XCTAssertEqual(alphaDecision.createdAt, "2026-05-01T10:00:02Z")
        XCTAssertNil(inspections.last?.latestHLSDecision)

        let described = String(describing: inspections)
        XCTAssertFalse(described.contains("user:pass"))
        XCTAssertFalse(described.contains("synthetic-secret"))
        XCTAssertFalse(described.contains("token="))
        XCTAssertFalse(described.contains("#frag"))
        XCTAssertFalse(described.contains("/Users/alice"))
    }

    func testMissingStreamJoinReturnsNoStatusRow() throws {
        let temporary = try TemporarySoundingDatabase()
        let persistence = IngestPersistence(database: temporary.database)
        let legacyStreamID = try persistence.createStream(
            streamType: "hls",
            source: "https://user:pass@example.test/legacy.m3u8?token=secret",
            createdAt: "2026-05-01T10:00:00Z"
        )
        let store = AppStreamRuntimeStatusStore(database: temporary.database)

        try temporary.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO stream_runtime_status (stream_id, phase, attempt, max_attempts, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [legacyStreamID, AppStreamRuntimeStatusPhase.running.rawValue, 0, 3, "2026-05-01T10:00:01Z"]
            )
        }

        XCTAssertNil(try store.status(streamID: legacyStreamID))
        XCTAssertEqual(try store.statuses(), [])
    }

    func testRepeatedUpdatesReplaceSingleStatusRow() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Replace",
            streamType: "hls",
            source: "https://example.test/live.m3u8",
            createdAt: "2026-05-01T10:00:00Z"
        )
        let store = AppStreamRuntimeStatusStore(database: temporary.database)

        try store.upsert(
            AppStreamRuntimeStatusUpdate(
                streamID: stream.id,
                phase: .connecting,
                attempt: 0,
                maxAttempts: 3,
                updatedAt: "2026-05-01T10:00:01Z"
            )
        )
        try store.upsert(
            AppStreamRuntimeStatusUpdate(
                streamID: stream.id,
                phase: .running,
                attempt: 1,
                maxAttempts: 3,
                updatedAt: "2026-05-01T10:00:02Z"
            )
        )

        let count = try temporary.database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM stream_runtime_status WHERE stream_id = ?",
                arguments: [stream.id]
            )
        }
        XCTAssertEqual(count, 1)
        let snapshot = try XCTUnwrap(try store.status(streamID: stream.id))
        XCTAssertEqual(snapshot.phase, .running)
        XCTAssertEqual(snapshot.attempt, 1)
        XCTAssertEqual(snapshot.updatedAt, "2026-05-01T10:00:02Z")
    }

    func testWriteForMissingStreamThrowsRedactedError() throws {
        let temporary = try TemporarySoundingDatabase()
        let store = AppStreamRuntimeStatusStore(database: temporary.database)

        XCTAssertThrowsError(
            try store.upsert(
                AppStreamRuntimeStatusUpdate(
                    streamID: 99_999,
                    phase: .running,
                    updatedAt: "2026-05-01T10:00:00Z",
                    recentFailure: AppStreamRuntimeRecentFailure(
                        message: "https://user:pass@example.test/live.m3u8?token=secret /Users/alice/private",
                        occurredAt: "2026-05-01T10:00:00Z"
                    )
                )
            )
        ) { error in
            XCTAssertEqual(error as? AppStreamRuntimeStatusStoreError, .streamNotFound)
            XCTAssertFalse(String(describing: error).contains("token=secret"))
            XCTAssertFalse(String(describing: error).contains("/Users/alice"))
        }
    }
}
