import GRDB
import XCTest
@testable import SoundingKit

final class SoundingDatabaseMigrationTests: XCTestCase {
    private let deferredPostM002Tables: Set<String> = [
        "marker" + "_events",
        "songs",
        "song_fingerprints",
        "fingerprints",
        "reports",
        "report_rows",
        "songs_fts"
    ]

    func testMigrationsCreateM001AndM002IngestTimelineTablesOnly() throws {
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
                "grdb_migrations"
            ]
        )
        XCTAssertTrue(tables.isDisjoint(with: deferredPostM002Tables))
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
                "speaker_turns": columnNames(in: "speaker_turns", db)
            ]
        }

        XCTAssertEqual(columnsByTable["streams"], [
            "id",
            "stream_type",
            "source",
            "created_at",
            "updated_at"
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
                "transcript_segments_fts": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments_fts")
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
            "transcript_segments_fts": 0
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

    private func columnNames(in table: String, _ db: Database) throws -> [String] {
        try db.columns(in: table).map(\.name)
    }
}
