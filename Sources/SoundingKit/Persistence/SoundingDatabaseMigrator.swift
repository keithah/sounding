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

        migrator.registerMigration("addSongTimeline") { db in
            try db.create(table: "audio_fingerprints") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("stream_id", .integer)
                    .notNull()
                    .references("streams", onDelete: .cascade)
                table.column("run_id", .integer)
                    .notNull()
                    .references("ingest_runs", onDelete: .cascade)
                table.column("chunk_id", .integer)
                    .notNull()
                    .references("ingest_chunks", onDelete: .cascade)
                table.column("algorithm", .text).notNull()
                    .check(sql: "length(algorithm) > 0")
                table.column("algorithm_version", .text).notNull()
                    .check(sql: "length(algorithm_version) > 0")
                table.column("fingerprint", .text).notNull()
                    .check(sql: "length(fingerprint) > 0")
                table.column("fingerprint_hash", .text).notNull()
                    .check(sql: "length(fingerprint_hash) > 0")
                table.column("start_seconds", .double).notNull()
                table.column("end_seconds", .double).notNull()
                table.column("confidence", .double)
                table.column("created_at", .text).notNull()
                table.check(sql: "end_seconds >= start_seconds")
                table.uniqueKey(["run_id", "chunk_id", "algorithm", "algorithm_version", "fingerprint_hash"])
            }
            try db.create(index: "audio_fingerprints_on_stream_run_time", on: "audio_fingerprints", columns: ["stream_id", "run_id", "start_seconds"])
            try db.create(index: "audio_fingerprints_on_chunk_id", on: "audio_fingerprints", columns: ["chunk_id"])
            try db.create(index: "audio_fingerprints_on_fingerprint_hash", on: "audio_fingerprints", columns: ["fingerprint_hash"])

            try db.create(table: "songs") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("song_key", .text).notNull()
                    .check(sql: "length(song_key) > 0")
                    .unique()
                table.column("title", .text)
                table.column("artist", .text)
                table.column("album", .text)
                table.column("isrc", .text)
                table.column("display_name", .text).notNull()
                    .check(sql: "length(display_name) > 0")
                table.column("is_unknown", .boolean).notNull().defaults(to: false)
                table.column("created_at", .text).notNull()
                table.column("updated_at", .text).notNull()
            }
            try db.create(index: "songs_on_song_key", on: "songs", columns: ["song_key"])
            try db.create(index: "songs_on_isrc", on: "songs", columns: ["isrc"])
            try db.create(index: "songs_on_display_name", on: "songs", columns: ["display_name"])

            try db.create(table: "song_plays") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("stream_id", .integer)
                    .notNull()
                    .references("streams", onDelete: .cascade)
                table.column("run_id", .integer)
                    .notNull()
                    .references("ingest_runs", onDelete: .cascade)
                table.column("song_id", .integer)
                    .notNull()
                    .references("songs", onDelete: .restrict)
                table.column("first_chunk_id", .integer)
                    .notNull()
                    .references("ingest_chunks", onDelete: .cascade)
                table.column("last_chunk_id", .integer)
                    .notNull()
                    .references("ingest_chunks", onDelete: .cascade)
                table.column("start_seconds", .double).notNull()
                table.column("end_seconds", .double).notNull()
                table.column("confidence", .double)
                table.column("source", .text)
                table.column("created_at", .text).notNull()
                table.column("updated_at", .text).notNull()
                table.check(sql: "end_seconds >= start_seconds")
            }
            try db.create(index: "song_plays_on_stream_run_time", on: "song_plays", columns: ["stream_id", "run_id", "start_seconds"])
            try db.create(index: "song_plays_on_run_time", on: "song_plays", columns: ["run_id", "start_seconds"])
            try db.create(index: "song_plays_on_song_id", on: "song_plays", columns: ["song_id"])
            try db.create(index: "song_plays_on_last_chunk_id", on: "song_plays", columns: ["last_chunk_id"])
        }

        migrator.registerMigration("addAcoustIDLookupCache") { db in
            try db.create(table: "acoustid_lookup_cache") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("algorithm", .text).notNull()
                    .check(sql: "length(algorithm) > 0")
                table.column("algorithm_version", .text).notNull()
                    .check(sql: "length(algorithm_version) > 0")
                table.column("fingerprint_hash", .text).notNull()
                    .check(sql: "length(fingerprint_hash) > 0")
                table.column("acoustid_id", .text)
                table.column("recording_id", .text)
                table.column("title", .text)
                table.column("artist", .text)
                table.column("album", .text)
                table.column("isrc", .text)
                table.column("duration_seconds", .double)
                table.column("score", .double)
                table.column("response_json", .text)
                table.column("created_at", .text).notNull()
                table.column("updated_at", .text).notNull()
                table.uniqueKey(["algorithm", "algorithm_version", "fingerprint_hash"])
            }
            try db.create(index: "acoustid_lookup_cache_on_identity", on: "acoustid_lookup_cache", columns: ["algorithm", "algorithm_version", "fingerprint_hash"])
            try db.create(index: "acoustid_lookup_cache_on_acoustid_id", on: "acoustid_lookup_cache", columns: ["acoustid_id"])
            try db.create(index: "acoustid_lookup_cache_on_recording_id", on: "acoustid_lookup_cache", columns: ["recording_id"])
            try db.create(index: "acoustid_lookup_cache_on_updated_at", on: "acoustid_lookup_cache", columns: ["updated_at"])
        }

        migrator.registerMigration("addStreamManagement") { db in
            try db.alter(table: "streams") { table in
                table.add(column: "name", .text)
                table.add(column: "status", .text)
                    .notNull()
                    .defaults(to: "active")
                    .check(sql: "status IN ('active', 'paused', 'removed')")
                table.add(column: "paused_at", .text)
                table.add(column: "resumed_at", .text)
                table.add(column: "removed_at", .text)
            }
            try db.create(index: "streams_on_status", on: "streams", columns: ["status"])
            try db.create(index: "streams_on_name", on: "streams", columns: ["name"])
            try db.execute(sql: """
                CREATE UNIQUE INDEX streams_on_active_name
                ON streams(name)
                WHERE name IS NOT NULL
                  AND removed_at IS NULL
                """)
        }

        migrator.registerMigration("addStreamReconnectSource") { db in
            try db.alter(table: "streams") { table in
                table.add(column: "source_url", .text)
            }
        }

        migrator.registerMigration("addStreamAppSpeakerOverrides") { db in
            try db.create(table: "stream_app_speaker_overrides") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("stream_id", .integer)
                    .notNull()
                    .references("streams", onDelete: .cascade)
                table.column("raw_label", .text).notNull()
                    .check(sql: "length(trim(raw_label)) > 0")
                table.column("display_label", .text).notNull()
                    .check(sql: "length(trim(display_label)) > 0")
                    .check(sql: "length(display_label) <= 64")
                table.column("color_token", .text).notNull()
                    .check(sql: "length(trim(color_token)) > 0")
                table.column("created_at", .text).notNull()
                table.column("updated_at", .text).notNull()
                table.uniqueKey(["stream_id", "raw_label"])
            }
            try db.create(
                index: "stream_app_speaker_overrides_on_stream_label",
                on: "stream_app_speaker_overrides",
                columns: ["stream_id", "raw_label"]
            )
            try db.create(
                index: "stream_app_speaker_overrides_on_stream_id",
                on: "stream_app_speaker_overrides",
                columns: ["stream_id"]
            )
        }

        migrator.registerMigration("addStreamRuntimeStatus") { db in
            try db.create(table: "stream_runtime_status") { table in
                table.column("stream_id", .integer)
                    .notNull()
                    .primaryKey(onConflict: .replace)
                    .references("streams", onDelete: .cascade)
                table.column("phase", .text).notNull()
                    .check(sql: "length(trim(phase)) > 0")
                table.column("attempt", .integer).notNull().defaults(to: 0)
                    .check(sql: "attempt >= 0")
                table.column("max_attempts", .integer).notNull().defaults(to: 0)
                    .check(sql: "max_attempts >= 0")
                table.column("next_retry_seconds", .integer)
                    .check(sql: "next_retry_seconds IS NULL OR next_retry_seconds >= 0")
                table.column("next_retry_at", .text)
                table.column("recent_failure_message", .text)
                table.column("recent_failure_at", .text)
                table.column("updated_at", .text).notNull()
            }
            try db.create(
                index: "stream_runtime_status_on_phase",
                on: "stream_runtime_status",
                columns: ["phase"]
            )
            try db.create(
                index: "stream_runtime_status_on_updated_at",
                on: "stream_runtime_status",
                columns: ["updated_at"]
            )
        }

        migrator.registerMigration("addStreamRuntimeLifecycleStatus") { db in
            try db.alter(table: "stream_runtime_status") { table in
                table.add(column: "lifecycle_reason", .text)
                table.add(column: "suspended_at", .text)
                table.add(column: "recovery_started_at", .text)
                table.add(column: "recovered_at", .text)
                table.add(column: "recovery_latency_ms", .integer)
                    .check(sql: "recovery_latency_ms IS NULL OR recovery_latency_ms >= 0")
            }
        }

        migrator.registerMigration("addHLSSegmentState") { db in
            try db.create(table: "hls_ingest_segments") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("stream_id", .integer)
                    .notNull()
                    .references("streams", onDelete: .cascade)
                table.column("media_sequence", .integer).notNull()
                    .check(sql: "media_sequence >= 0")
                table.column("segment_identity", .text).notNull()
                    .check(sql: "length(trim(segment_identity)) > 0")
                table.column("segment_identity_hash", .text).notNull()
                    .check(sql: "length(trim(segment_identity_hash)) > 0")
                table.column("claimed_run_id", .integer)
                    .references("ingest_runs", onDelete: .setNull)
                table.column("chunk_id", .integer)
                    .references("ingest_chunks", onDelete: .setNull)
                table.column("claimed_at", .text).notNull()
                table.column("finalized_at", .text)
                table.column("updated_at", .text).notNull()
                table.uniqueKey(["stream_id", "media_sequence"])
            }
            try db.create(
                index: "hls_ingest_segments_on_stream_sequence",
                on: "hls_ingest_segments",
                columns: ["stream_id", "media_sequence"]
            )
            try db.create(
                index: "hls_ingest_segments_on_claimed_run_id",
                on: "hls_ingest_segments",
                columns: ["claimed_run_id"]
            )
            try db.create(
                index: "hls_ingest_segments_on_chunk_id",
                on: "hls_ingest_segments",
                columns: ["chunk_id"]
            )
            try db.create(
                index: "hls_ingest_segments_on_updated_at",
                on: "hls_ingest_segments",
                columns: ["updated_at"]
            )
        }

        migrator.registerMigration("addHLSIngestDiagnosticsLookupIndex") { db in
            try db.create(
                index: "ingest_diagnostics_on_hls_decision_lookup",
                on: "ingest_diagnostics",
                columns: ["stream_id", "source_class", "stream_type", "reason", "id"]
            )
        }

        migrator.registerMigration("addPerStreamDiarizationSetting") { db in
            try db.alter(table: "streams") { table in
                table.add(column: "diarization_enabled", .boolean)
                    .notNull()
                    .defaults(to: false)
            }
        }

        migrator.registerMigration("addStreamAudioArchiveSetting") { db in
            try db.alter(table: "streams") { table in
                table.add(column: "audio_archive_enabled", .boolean)
                    .notNull()
                    .defaults(to: false)
            }
        }

        migrator.registerMigration("addStreamTranscriptionPolicy") { db in
            try db.alter(table: "streams") { table in
                table.add(column: "transcription_policy", .text)
                    .notNull()
                    .defaults(to: StreamTranscriptionPolicy.defaultValue.rawValue)
            }
        }

        migrator.registerMigration("addAudioArchiveSegments") { db in
            try db.create(table: "audio_archive_segments") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("stream_id", .integer)
                    .notNull()
                    .references("streams", onDelete: .cascade)
                table.column("run_id", .integer)
                    .notNull()
                    .references("ingest_runs", onDelete: .cascade)
                table.column("chunk_id", .integer)
                    .notNull()
                    .references("ingest_chunks", onDelete: .cascade)
                table.column("sequence", .integer).notNull()
                table.column("start_seconds", .double).notNull()
                table.column("end_seconds", .double).notNull()
                table.column("sample_rate", .double).notNull()
                table.column("channel_count", .integer).notNull()
                table.column("byte_count", .integer).notNull()
                table.column("sha256", .text).notNull()
                table.column("relative_path", .text).notNull()
                table.column("created_at", .text).notNull()
                table.check(sql: "end_seconds >= start_seconds")
                table.uniqueKey(["stream_id", "run_id", "chunk_id", "sequence"])
            }
            try db.create(
                index: "audio_archive_segments_on_stream_time",
                on: "audio_archive_segments",
                columns: ["stream_id", "start_seconds", "end_seconds"]
            )
            try db.create(
                index: "audio_archive_segments_on_run_chunk",
                on: "audio_archive_segments",
                columns: ["run_id", "chunk_id"]
            )
        }

        migrator.registerMigration("addAppTimelinePerformanceIndexes") { db in
            try db.create(
                index: "transcript_segments_on_run_end_start_id",
                on: "transcript_segments",
                columns: ["run_id", "end_seconds", "start_seconds", "id"]
            )
            try db.create(
                index: "transcript_segments_on_run_start_id",
                on: "transcript_segments",
                columns: ["run_id", "start_seconds", "id"]
            )
            try db.create(
                index: "transcript_words_on_segment_sequence_id",
                on: "transcript_words",
                columns: ["segment_id", "sequence", "id"]
            )
            try db.create(
                index: "speaker_turns_on_chunk_start_end",
                on: "speaker_turns",
                columns: ["chunk_id", "start_seconds", "end_seconds"]
            )
            try db.create(
                index: "ad_events_on_run_pts_observed_id",
                on: "ad_events",
                columns: ["run_id", "pts", "observed_at", "id"]
            )
            try db.create(
                index: "song_plays_on_stream_start_id",
                on: "song_plays",
                columns: ["stream_id", "start_seconds", "id"]
            )
        }

        migrator.registerMigration("addTranscriptAdClassificationCache") { db in
            try db.create(table: "transcript_ad_classification_cache") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("segment_id", .integer)
                    .notNull()
                    .references("transcript_segments", onDelete: .cascade)
                table.column("classifier", .text).notNull()
                    .check(sql: "length(trim(classifier)) > 0")
                table.column("classifier_version", .text).notNull()
                    .check(sql: "length(trim(classifier_version)) > 0")
                table.column("is_ad", .boolean).notNull()
                table.column("confidence", .double).notNull()
                    .check(sql: "confidence >= 0 AND confidence <= 1")
                table.column("signals_json", .text).notNull()
                    .check(sql: "length(trim(signals_json)) > 0")
                table.column("created_at", .text).notNull()
                table.column("updated_at", .text).notNull()
                table.uniqueKey(["segment_id", "classifier", "classifier_version"])
            }
            try db.create(
                index: "transcript_ad_classification_cache_on_identity",
                on: "transcript_ad_classification_cache",
                columns: ["segment_id", "classifier", "classifier_version"]
            )
            try db.create(
                index: "transcript_ad_classification_cache_on_updated_at",
                on: "transcript_ad_classification_cache",
                columns: ["updated_at"]
            )
        }

        migrator.registerMigration("addTranscriptAdClassificationAttribution") { db in
            try db.alter(table: "transcript_ad_classification_cache") { table in
                table.add(column: "verdict", .text)
                table.add(column: "ad_type", .text)
                table.add(column: "brand", .text)
                table.add(column: "product", .text)
                table.add(column: "reason", .text)
                table.add(column: "model_identifier", .text)
            }
            try db.create(
                index: "transcript_ad_classification_cache_on_brand",
                on: "transcript_ad_classification_cache",
                columns: ["brand"]
            )
        }

        try migrator.migrate(writer)
    }
}
