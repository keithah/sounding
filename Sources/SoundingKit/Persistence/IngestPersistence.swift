import Foundation
import GRDB

/// GRDB-backed writer for M002 ingest state.
///
/// The writer uses one database transaction per public write call. `persistTimeline`
/// intentionally writes all rows for a decoded chunk together, so partial segment,
/// word, speaker, marker, or diagnostic rows roll back when any row violates a
/// constraint.
public struct IngestPersistence {
    private let database: SoundingDatabase
    private let jsonEncoder: JSONEncoder

    public init(database: SoundingDatabase) {
        self.database = database
        self.jsonEncoder = JSONEncoder()
    }

    public func createStream(
        streamType: String,
        source: String,
        createdAt: String,
        updatedAt: String? = nil
    ) throws -> Int64 {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO streams (stream_type, source, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [streamType, source, createdAt, updatedAt ?? createdAt]
            )
            return db.lastInsertedRowID
        }
    }

    public func createRun(
        streamID: Int64,
        startedAt: String,
        status: IngestRunStatus,
        context: [String: JSONValue]? = nil
    ) throws -> Int64 {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO ingest_runs (stream_id, started_at, ended_at, status, context_json)
                    VALUES (?, ?, NULL, ?, ?)
                    """,
                arguments: [streamID, startedAt, status.rawValue, try jsonString(context)]
            )
            return db.lastInsertedRowID
        }
    }

    public func finishRun(
        runID: Int64,
        endedAt: String,
        status: IngestRunStatus,
        context: [String: JSONValue]? = nil
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE ingest_runs
                    SET ended_at = ?, status = ?, context_json = COALESCE(?, context_json)
                    WHERE id = ?
                    """,
                arguments: [endedAt, status.rawValue, try jsonString(context), runID]
            )
        }
    }

    public func createChunk(
        runID: Int64,
        sequence: Int,
        segmentURI: String? = nil,
        byteCount: Int? = nil,
        startedAt: String,
        endedAt: String? = nil,
        context: [String: JSONValue]? = nil
    ) throws -> Int64 {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO ingest_chunks (run_id, sequence, segment_uri, byte_count, started_at, ended_at, context_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    runID,
                    sequence,
                    segmentURI,
                    byteCount,
                    startedAt,
                    endedAt,
                    try jsonString(context)
                ]
            )
            return db.lastInsertedRowID
        }
    }

    public func persistTimeline(_ timeline: IngestChunkTimeline) throws {
        try database.write { db in
            for segment in timeline.segments {
                let segmentID = try insertSegment(segment, timeline: timeline, db: db)
                try insertSearchText(forSegmentID: segmentID, segment: segment, db: db)
                for word in segment.words {
                    try insertWord(word, segmentID: segmentID, chunkID: timeline.chunkID, db: db)
                }
            }

            for speakerTurn in timeline.speakerTurns {
                try insertSpeakerTurn(speakerTurn, timeline: timeline, db: db)
            }

            for marker in timeline.adMarkers {
                try insertAdMarker(marker, timeline: timeline, db: db)
            }

            for diagnostic in timeline.diagnostics {
                try insertDiagnostic(diagnostic, timeline: timeline, db: db)
            }
        }
    }

    private func insertSegment(
        _ segment: TranscriptSegmentDraft,
        timeline: IngestChunkTimeline,
        db: Database
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO transcript_segments (
                    run_id, chunk_id, sequence, speaker_label, start_seconds,
                    end_seconds, text, confidence, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                timeline.runID,
                timeline.chunkID,
                segment.sequence,
                segment.speakerLabel,
                segment.startSeconds,
                segment.endSeconds,
                segment.text,
                segment.confidence,
                timeline.createdAt
            ]
        )
        return db.lastInsertedRowID
    }

    private func insertSearchText(
        forSegmentID segmentID: Int64,
        segment: TranscriptSegmentDraft,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO transcript_segments_fts (rowid, text, speaker_label)
                VALUES (?, ?, ?)
                """,
            arguments: [segmentID, segment.text, segment.speakerLabel]
        )
    }

    private func insertWord(
        _ word: TranscriptWordDraft,
        segmentID: Int64,
        chunkID: Int64,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO transcript_words (
                    segment_id, chunk_id, sequence, speaker_label, start_seconds,
                    end_seconds, text, confidence
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                segmentID,
                chunkID,
                word.sequence,
                word.speakerLabel,
                word.startSeconds,
                word.endSeconds,
                word.text,
                word.confidence
            ]
        )
    }

    private func insertSpeakerTurn(
        _ turn: SpeakerTurnDraft,
        timeline: IngestChunkTimeline,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO speaker_turns (
                    run_id, chunk_id, speaker_label, start_seconds,
                    end_seconds, confidence, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                timeline.runID,
                timeline.chunkID,
                turn.speakerLabel,
                turn.startSeconds,
                turn.endSeconds,
                turn.confidence,
                timeline.createdAt
            ]
        )
    }

    private func insertAdMarker(
        _ marker: AdMarker,
        timeline: IngestChunkTimeline,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO ad_events (
                    run_id, chunk_id, classification, marker_type, source, pts,
                    segment, raw_base64, payload_json, observed_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                timeline.runID,
                timeline.chunkID,
                marker.classification.rawValue,
                marker.type,
                marker.source,
                marker.pts,
                marker.segment,
                marker.rawBase64,
                try jsonString(marker),
                marker.timestamp ?? timeline.createdAt
            ]
        )
    }

    private func insertDiagnostic(
        _ diagnostic: IngestDiagnosticDraft,
        timeline: IngestChunkTimeline,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO ingest_diagnostics (
                    stream_id, run_id, chunk_id, phase, severity, reason, source,
                    source_class, stream_type, context_json, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                diagnostic.streamID,
                timeline.runID,
                timeline.chunkID,
                diagnostic.phase.rawValue,
                diagnostic.severity.rawValue,
                diagnostic.reason,
                diagnostic.source,
                diagnostic.sourceClass,
                diagnostic.streamType,
                try jsonString(diagnostic.context),
                diagnostic.createdAt
            ]
        )
    }

    private func jsonString<Value: Encodable>(_ value: Value?) throws -> String? {
        guard let value else { return nil }
        let data = try jsonEncoder.encode(value)
        return String(data: data, encoding: .utf8)
    }
}
