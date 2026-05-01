import GRDB

enum SoundingDatabaseMigrator {
    static func migrate(_ writer: DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createIngestBaseline") { db in
            try db.create(table: "streams") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("stream_type", .text).notNull()
                table.column("source", .text).notNull()
                table.column("created_at", .text).notNull()
                table.column("updated_at", .text).notNull()
            }
            try db.create(index: "streams_on_stream_type", on: "streams", columns: ["stream_type"])
            try db.create(index: "streams_on_source", on: "streams", columns: ["source"])

            try db.create(table: "ingest_runs") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("stream_id", .integer)
                    .notNull()
                    .references("streams", onDelete: .cascade)
                table.column("started_at", .text).notNull()
                table.column("ended_at", .text)
                table.column("status", .text).notNull()
                table.column("context_json", .text)
            }
            try db.create(index: "ingest_runs_on_stream_id", on: "ingest_runs", columns: ["stream_id"])
            try db.create(index: "ingest_runs_on_status", on: "ingest_runs", columns: ["status"])

            try db.create(table: "ingest_chunks") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("run_id", .integer)
                    .notNull()
                    .references("ingest_runs", onDelete: .cascade)
                table.column("sequence", .integer).notNull()
                table.column("segment_uri", .text)
                table.column("byte_count", .integer)
                table.column("started_at", .text).notNull()
                table.column("ended_at", .text)
                table.column("context_json", .text)
                table.uniqueKey(["run_id", "sequence"])
            }
            try db.create(index: "ingest_chunks_on_run_id", on: "ingest_chunks", columns: ["run_id"])
            try db.create(index: "ingest_chunks_on_segment_uri", on: "ingest_chunks", columns: ["segment_uri"])

            try db.create(table: "ad_events") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("run_id", .integer)
                    .notNull()
                    .references("ingest_runs", onDelete: .cascade)
                table.column("chunk_id", .integer)
                    .references("ingest_chunks", onDelete: .setNull)
                table.column("classification", .text).notNull()
                table.column("marker_type", .text).notNull()
                table.column("source", .text).notNull()
                table.column("pts", .double)
                table.column("segment", .text)
                table.column("raw_base64", .text)
                table.column("payload_json", .text)
                table.column("observed_at", .text).notNull()
            }
            try db.create(index: "ad_events_on_run_id", on: "ad_events", columns: ["run_id"])
            try db.create(index: "ad_events_on_chunk_id", on: "ad_events", columns: ["chunk_id"])
            try db.create(index: "ad_events_on_classification", on: "ad_events", columns: ["classification"])

            try db.create(table: "ingest_diagnostics") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("stream_id", .integer)
                    .references("streams", onDelete: .setNull)
                table.column("run_id", .integer)
                    .references("ingest_runs", onDelete: .setNull)
                table.column("chunk_id", .integer)
                    .references("ingest_chunks", onDelete: .setNull)
                table.column("phase", .text).notNull()
                table.column("severity", .text).notNull()
                table.column("reason", .text).notNull()
                table.column("source", .text)
                table.column("source_class", .text).notNull()
                table.column("stream_type", .text).notNull()
                table.column("context_json", .text)
                table.column("created_at", .text).notNull()
            }
            try db.create(index: "ingest_diagnostics_on_stream_id", on: "ingest_diagnostics", columns: ["stream_id"])
            try db.create(index: "ingest_diagnostics_on_run_id", on: "ingest_diagnostics", columns: ["run_id"])
            try db.create(index: "ingest_diagnostics_on_chunk_id", on: "ingest_diagnostics", columns: ["chunk_id"])
            try db.create(index: "ingest_diagnostics_on_phase", on: "ingest_diagnostics", columns: ["phase"])
            try db.create(index: "ingest_diagnostics_on_severity", on: "ingest_diagnostics", columns: ["severity"])
        }

        migrator.registerMigration("addTranscriptTimeline") { db in
            try db.create(table: "transcript_segments") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("run_id", .integer)
                    .notNull()
                    .references("ingest_runs", onDelete: .cascade)
                table.column("chunk_id", .integer)
                    .notNull()
                    .references("ingest_chunks", onDelete: .cascade)
                table.column("sequence", .integer).notNull()
                table.column("speaker_label", .text)
                table.column("start_seconds", .double).notNull()
                table.column("end_seconds", .double).notNull()
                table.column("text", .text).notNull()
                table.column("confidence", .double)
                table.column("created_at", .text).notNull()
                table.uniqueKey(["run_id", "sequence"])
            }
            try db.create(index: "transcript_segments_on_run_id", on: "transcript_segments", columns: ["run_id"])
            try db.create(index: "transcript_segments_on_chunk_id", on: "transcript_segments", columns: ["chunk_id"])
            try db.create(index: "transcript_segments_on_speaker_label", on: "transcript_segments", columns: ["speaker_label"])
            try db.create(index: "transcript_segments_on_start_seconds", on: "transcript_segments", columns: ["start_seconds"])

            try db.create(table: "transcript_words") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("segment_id", .integer)
                    .notNull()
                    .references("transcript_segments", onDelete: .cascade)
                table.column("chunk_id", .integer)
                    .notNull()
                    .references("ingest_chunks", onDelete: .cascade)
                table.column("sequence", .integer).notNull()
                table.column("speaker_label", .text)
                table.column("start_seconds", .double).notNull()
                table.column("end_seconds", .double).notNull()
                table.column("text", .text).notNull()
                table.column("confidence", .double)
                table.uniqueKey(["segment_id", "sequence"])
            }
            try db.create(index: "transcript_words_on_segment_id", on: "transcript_words", columns: ["segment_id"])
            try db.create(index: "transcript_words_on_chunk_id", on: "transcript_words", columns: ["chunk_id"])
            try db.create(index: "transcript_words_on_speaker_label", on: "transcript_words", columns: ["speaker_label"])
            try db.create(index: "transcript_words_on_start_seconds", on: "transcript_words", columns: ["start_seconds"])

            try db.create(table: "speaker_turns") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("run_id", .integer)
                    .notNull()
                    .references("ingest_runs", onDelete: .cascade)
                table.column("chunk_id", .integer)
                    .notNull()
                    .references("ingest_chunks", onDelete: .cascade)
                table.column("speaker_label", .text).notNull()
                table.column("start_seconds", .double).notNull()
                table.column("end_seconds", .double).notNull()
                table.column("confidence", .double)
                table.column("created_at", .text).notNull()
            }
            try db.create(index: "speaker_turns_on_run_id", on: "speaker_turns", columns: ["run_id"])
            try db.create(index: "speaker_turns_on_chunk_id", on: "speaker_turns", columns: ["chunk_id"])
            try db.create(index: "speaker_turns_on_speaker_label", on: "speaker_turns", columns: ["speaker_label"])
            try db.create(index: "speaker_turns_on_start_seconds", on: "speaker_turns", columns: ["start_seconds"])

            try db.execute(sql: """
                CREATE VIRTUAL TABLE transcript_segments_fts
                USING fts5(text, speaker_label, content='transcript_segments', content_rowid='id')
                """)
        }

        try migrator.migrate(writer)
    }
}
