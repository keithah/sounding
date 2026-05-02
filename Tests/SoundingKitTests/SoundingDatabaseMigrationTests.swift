import GRDB
import XCTest
@testable import SoundingKit

final class SoundingDatabaseMigrationTests: XCTestCase {
    private let deferredPostS01Tables: Set<String> = [
        "marker" + "_events",
        "song_fingerprints",
        "fingerprints",
        "reports",
        "report_rows",
        "songs_fts"
    ]

    func testMigrationsCreateIngestTranscriptAndSongTimelineTablesOnly() throws {
        let temporary = try TemporarySoundingDatabase()

        let tables = try temporary.database.read { db in
            try Set(String.fetchAll(db, sql: """
                SELECT name
                FROM sqlite_master
                WHERE type = 'table'
                  AND name NOT LIKE 'sqlite_%'
                  AND name NOT LIKE '%_data'
                  AND name NOT LIKE '%_idx'
                  AND name NOT LIKE '%_docsize'
                  AND name NOT LIKE '%_config'
                ORDER BY name
                """))
        }

        XCTAssertEqual(
            tables,
            [
                "streams",
                "ingest_runs",
                "ingest_chunks",
                "ad_events",
                "ingest_diagnostics",
                "transcript_segments",
                "transcript_words",
                "speaker_turns",
                "transcript_segments_fts",
                "audio_fingerprints",
                "songs",
                "song_plays",
                "acoustid_lookup_cache",
                "stream_app_speaker_overrides",
                "stream_runtime_status",
                "hls_ingest_segments",
                "grdb_migrations"
            ]
        )
        XCTAssertTrue(tables.isDisjoint(with: deferredPostS01Tables))
    }

    func testBaselineTablesExposeExpectedColumns() throws {
        let temporary = try TemporarySoundingDatabase()

        let columnsByTable = try temporary.database.read { db in
            try [
                "streams": columnNames(in: "streams", db),
                "ingest_runs": columnNames(in: "ingest_runs", db),
                "ingest_chunks": columnNames(in: "ingest_chunks", db),
                "ad_events": columnNames(in: "ad_events", db),
                "ingest_diagnostics": columnNames(in: "ingest_diagnostics", db),
                "transcript_segments": columnNames(in: "transcript_segments", db),
                "transcript_words": columnNames(in: "transcript_words", db),
                "speaker_turns": columnNames(in: "speaker_turns", db),
                "audio_fingerprints": columnNames(in: "audio_fingerprints", db),
                "songs": columnNames(in: "songs", db),
                "song_plays": columnNames(in: "song_plays", db),
                "acoustid_lookup_cache": columnNames(in: "acoustid_lookup_cache", db),
                "stream_app_speaker_overrides": columnNames(in: "stream_app_speaker_overrides", db),
                "stream_runtime_status": columnNames(in: "stream_runtime_status", db),
                "hls_ingest_segments": columnNames(in: "hls_ingest_segments", db)
            ]
        }

        XCTAssertEqual(columnsByTable["streams"], [
            "id",
            "stream_type",
            "source",
            "created_at",
            "updated_at",
            "name",
            "status",
            "paused_at",
            "resumed_at",
            "removed_at",
            "source_url"
        ])
        XCTAssertEqual(columnsByTable["ingest_runs"], [
            "id",
            "stream_id",
            "started_at",
            "ended_at",
            "status",
            "context_json"
        ])
        XCTAssertEqual(columnsByTable["ingest_chunks"], [
            "id",
            "run_id",
            "sequence",
            "segment_uri",
            "byte_count",
            "started_at",
            "ended_at",
            "context_json"
        ])
        XCTAssertEqual(columnsByTable["ad_events"], [
            "id",
            "run_id",
            "chunk_id",
            "classification",
            "marker_type",
            "source",
            "pts",
            "segment",
            "raw_base64",
            "payload_json",
            "observed_at"
        ])
        XCTAssertEqual(columnsByTable["ingest_diagnostics"], [
            "id",
            "stream_id",
            "run_id",
            "chunk_id",
            "phase",
            "severity",
            "reason",
            "source",
            "source_class",
            "stream_type",
            "context_json",
            "created_at"
        ])
        XCTAssertEqual(columnsByTable["transcript_segments"], [
            "id",
            "run_id",
            "chunk_id",
            "sequence",
            "speaker_label",
            "start_seconds",
            "end_seconds",
            "text",
            "confidence",
            "created_at"
        ])
        XCTAssertEqual(columnsByTable["transcript_words"], [
            "id",
            "segment_id",
            "chunk_id",
            "sequence",
            "speaker_label",
            "start_seconds",
            "end_seconds",
            "text",
            "confidence"
        ])
        XCTAssertEqual(columnsByTable["speaker_turns"], [
            "id",
            "run_id",
            "chunk_id",
            "speaker_label",
            "start_seconds",
            "end_seconds",
            "confidence",
            "created_at"
        ])
        XCTAssertEqual(columnsByTable["audio_fingerprints"], [
            "id",
            "stream_id",
            "run_id",
            "chunk_id",
            "algorithm",
            "algorithm_version",
            "fingerprint",
            "fingerprint_hash",
            "start_seconds",
            "end_seconds",
            "confidence",
            "created_at"
        ])
        XCTAssertEqual(columnsByTable["songs"], [
            "id",
            "song_key",
            "title",
            "artist",
            "album",
            "isrc",
            "display_name",
            "is_unknown",
            "created_at",
            "updated_at"
        ])
        XCTAssertEqual(columnsByTable["song_plays"], [
            "id",
            "stream_id",
            "run_id",
            "song_id",
            "first_chunk_id",
            "last_chunk_id",
            "start_seconds",
            "end_seconds",
            "confidence",
            "source",
            "created_at",
            "updated_at"
        ])
        XCTAssertEqual(columnsByTable["acoustid_lookup_cache"], [
            "id",
            "algorithm",
            "algorithm_version",
            "fingerprint_hash",
            "acoustid_id",
            "recording_id",
            "title",
            "artist",
            "album",
            "isrc",
            "duration_seconds",
            "score",
            "response_json",
            "created_at",
            "updated_at"
        ])
        XCTAssertEqual(columnsByTable["stream_app_speaker_overrides"], [
            "id",
            "stream_id",
            "raw_label",
            "display_label",
            "color_token",
            "created_at",
            "updated_at"
        ])
        XCTAssertEqual(columnsByTable["stream_runtime_status"], [
            "stream_id",
            "phase",
            "attempt",
            "max_attempts",
            "next_retry_seconds",
            "next_retry_at",
            "recent_failure_message",
            "recent_failure_at",
            "updated_at",
            "lifecycle_reason",
            "suspended_at",
            "recovery_started_at",
            "recovered_at",
            "recovery_latency_ms"
        ])
        XCTAssertEqual(columnsByTable["hls_ingest_segments"], [
            "id",
            "stream_id",
            "media_sequence",
            "segment_identity",
            "segment_identity_hash",
            "claimed_run_id",
            "chunk_id",
            "claimed_at",
            "finalized_at",
            "updated_at"
        ])
    }

    func testTimelineAndStreamManagementMigrationsCreateIndexes() throws {
        let temporary = try TemporarySoundingDatabase()

        let indexes = try temporary.database.read { db in
            try Set(String.fetchAll(db, sql: """
                SELECT name
                FROM sqlite_master
                WHERE type = 'index'
                  AND tbl_name IN ('streams', 'ingest_diagnostics', 'audio_fingerprints', 'songs', 'song_plays', 'acoustid_lookup_cache', 'stream_app_speaker_overrides', 'stream_runtime_status', 'hls_ingest_segments')
                ORDER BY name
                """))
        }

        XCTAssertTrue(indexes.isSuperset(of: [
            "streams_on_stream_type",
            "streams_on_source",
            "ingest_diagnostics_on_hls_decision_lookup",
            "streams_on_status",
            "streams_on_name",
            "streams_on_active_name",
            "audio_fingerprints_on_stream_run_time",
            "audio_fingerprints_on_chunk_id",
            "audio_fingerprints_on_fingerprint_hash",
            "songs_on_song_key",
            "songs_on_isrc",
            "songs_on_display_name",
            "song_plays_on_stream_run_time",
            "song_plays_on_run_time",
            "song_plays_on_song_id",
            "song_plays_on_last_chunk_id",
            "stream_app_speaker_overrides_on_stream_label",
            "stream_app_speaker_overrides_on_stream_id",
            "stream_runtime_status_on_phase",
            "stream_runtime_status_on_updated_at",
            "acoustid_lookup_cache_on_identity",
            "acoustid_lookup_cache_on_acoustid_id",
            "acoustid_lookup_cache_on_recording_id",
            "acoustid_lookup_cache_on_updated_at",
            "hls_ingest_segments_on_stream_sequence",
            "hls_ingest_segments_on_claimed_run_id",
            "hls_ingest_segments_on_chunk_id",
            "hls_ingest_segments_on_updated_at"
        ]))
    }

    func testStreamManagementMigrationDefaultsLegacyStreamRowsToActive() throws {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)

        let streamID = try writer.createStream(
            streamType: "hls",
            source: "https://example.test/live.m3u8",
            createdAt: "2026-05-01T10:00:00Z"
        )

        let row = try temporary.database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT name, status, paused_at, resumed_at, removed_at
                FROM streams
                WHERE id = ?
                """,
                arguments: [streamID]
            )
        }

        XCTAssertNil(row?["name"] as String?)
        XCTAssertEqual(row?["status"] as String?, "active")
        XCTAssertNil(row?["paused_at"] as String?)
        XCTAssertNil(row?["resumed_at"] as String?)
        XCTAssertNil(row?["removed_at"] as String?)
    }

    func testNewMigratedDatabaseStartsWithEmptyBaselineTables() throws {
        let temporary = try TemporarySoundingDatabase()

        let rowCounts = try temporary.database.read { db in
            try [
                "streams": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM streams"),
                "ingest_runs": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_runs"),
                "ingest_chunks": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_chunks"),
                "ad_events": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ad_events"),
                "ingest_diagnostics": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_diagnostics"),
                "transcript_segments": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments"),
                "transcript_words": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_words"),
                "speaker_turns": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_turns"),
                "transcript_segments_fts": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments_fts"),
                "audio_fingerprints": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audio_fingerprints"),
                "songs": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM songs"),
                "song_plays": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song_plays"),
                "acoustid_lookup_cache": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM acoustid_lookup_cache"),
                "stream_app_speaker_overrides": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stream_app_speaker_overrides"),
                "stream_runtime_status": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stream_runtime_status"),
                "hls_ingest_segments": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hls_ingest_segments")
            ]
        }

        XCTAssertEqual(rowCounts, [
            "streams": 0,
            "ingest_runs": 0,
            "ingest_chunks": 0,
            "ad_events": 0,
            "ingest_diagnostics": 0,
            "transcript_segments": 0,
            "transcript_words": 0,
            "speaker_turns": 0,
            "transcript_segments_fts": 0,
            "audio_fingerprints": 0,
            "songs": 0,
            "song_plays": 0,
            "acoustid_lookup_cache": 0,
            "stream_app_speaker_overrides": 0,
            "stream_runtime_status": 0,
            "hls_ingest_segments": 0
        ])
    }

    func testTemporaryDatabaseUsesUniqueFilesAndCleansThemUp() throws {
        var firstURL: URL?
        var secondURL: URL?

        do {
            let first = try TemporarySoundingDatabase()
            let second = try TemporarySoundingDatabase()
            firstURL = first.fileURL
            secondURL = second.fileURL

            XCTAssertNotEqual(first.fileURL, second.fileURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: first.fileURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: second.fileURL.path))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(firstURL).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(secondURL).path))
    }

    func testHLSIngestSegmentMigrationEnforcesStreamScopedMediaSequenceUniquenessAndCascade() throws {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)
        let streamID = try writer.createStream(streamType: "hls", source: "https://example.test/live.m3u8", createdAt: "2026-05-01T10:00:00Z")
        let runID = try writer.createRun(streamID: streamID, startedAt: "2026-05-01T10:00:01Z", status: .running)

        try temporary.database.write { db in
            try db.execute(sql: """
                INSERT INTO hls_ingest_segments (
                    stream_id, media_sequence, segment_identity, segment_identity_hash,
                    claimed_run_id, chunk_id, claimed_at, finalized_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, NULL, ?, NULL, ?)
                """, arguments: [streamID, 42, "https://example.test/segment.ts", "hash-42", runID, "2026-05-01T10:00:02Z", "2026-05-01T10:00:02Z"])
        }

        XCTAssertThrowsError(
            try temporary.database.write { db in
                try db.execute(sql: """
                    INSERT INTO hls_ingest_segments (
                        stream_id, media_sequence, segment_identity, segment_identity_hash,
                        claimed_run_id, chunk_id, claimed_at, finalized_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, NULL, ?, NULL, ?)
                    """, arguments: [streamID, 42, "https://example.test/other.ts", "hash-other", runID, "2026-05-01T10:00:03Z", "2026-05-01T10:00:03Z"])
            }
        )

        try temporary.database.write { db in
            try db.execute(sql: "DELETE FROM streams WHERE id = ?", arguments: [streamID])
        }
        let remaining = try temporary.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hls_ingest_segments")
        }
        XCTAssertEqual(remaining, 0)
    }

    func testStreamRuntimeLifecycleMigrationRejectsNegativeLatency() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Latency",
            streamType: "hls",
            source: "https://example.test/live.m3u8",
            createdAt: "2026-05-01T10:00:00Z"
        )

        XCTAssertThrowsError(
            try temporary.database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO stream_runtime_status (
                        stream_id, phase, attempt, max_attempts, updated_at, recovery_latency_ms
                    ) VALUES (?, ?, 0, 3, ?, -1)
                    """,
                    arguments: [stream.id, AppStreamRuntimeStatusPhase.recovering.rawValue, "2026-05-01T10:00:01Z"]
                )
            }
        )
    }

    private func columnNames(in table: String, _ db: Database) throws -> [String] {
        try db.columns(in: table).map(\.name)
    }
}
