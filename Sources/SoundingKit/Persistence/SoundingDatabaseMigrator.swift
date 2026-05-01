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

        try migrator.migrate(writer)
    }
}
