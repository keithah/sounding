import Foundation
import GRDB

/// Read-only transcript timeline export service over the persisted M002 transcript tables.
///
/// This query intentionally returns raw persisted values. Executable targets are responsible for
/// redaction and user-facing output shaping.
public struct TranscriptExportQuery {
    public struct SegmentExportRow: Codable, Equatable, Sendable {
        public var identity: TranscriptQuery.SegmentIdentity
        public var startSeconds: Double
        public var endSeconds: Double
        public var text: String
        public var confidence: Double?
        public var createdAt: String?
        public var words: [TranscriptQuery.TranscriptWord]

        public init(
            identity: TranscriptQuery.SegmentIdentity,
            startSeconds: Double,
            endSeconds: Double,
            text: String,
            confidence: Double?,
            createdAt: String?,
            words: [TranscriptQuery.TranscriptWord]
        ) {
            self.identity = identity
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.text = text
            self.confidence = confidence
            self.createdAt = createdAt
            self.words = words
        }
    }

    private struct SegmentRow {
        var identity: TranscriptQuery.SegmentIdentity
        var startSeconds: Double
        var endSeconds: Double
        var text: String
        var confidence: Double?
        var createdAt: String?
    }

    private let database: SoundingDatabase

    public init(database: SoundingDatabase) {
        self.database = database
    }

    public func segments(filter: SongReportQuery.Filter = SongReportQuery.Filter()) throws
        -> [SegmentExportRow]
    {
        let normalized = try SongReportQuery.validate(filter)

        do {
            return try database.read { db in
                var clauses: [String] = []
                var arguments = StatementArguments()

                if let stream = normalized.stream {
                    SongReportQuery.appendStreamFilterClause(
                        stream, clauses: &clauses, arguments: &arguments)
                }
                if let startSeconds = normalized.startSeconds {
                    clauses.append("transcript_segments.end_seconds >= ?")
                    arguments += [startSeconds]
                }
                if let endSeconds = normalized.endSeconds {
                    clauses.append("transcript_segments.start_seconds <= ?")
                    arguments += [endSeconds]
                }

                let whereClause =
                    clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT
                            streams.id AS stream_id,
                            streams.stream_type,
                            streams.source AS stream_source,
                            ingest_runs.id AS run_id,
                            transcript_segments.chunk_id,
                            transcript_segments.id AS segment_id,
                            transcript_segments.sequence,
                            transcript_segments.speaker_label,
                            transcript_segments.start_seconds,
                            transcript_segments.end_seconds,
                            transcript_segments.text,
                            transcript_segments.confidence,
                            transcript_segments.created_at
                        FROM transcript_segments
                        JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
                        JOIN streams ON streams.id = ingest_runs.stream_id
                        \(whereClause)
                        ORDER BY streams.id, ingest_runs.id, transcript_segments.sequence, transcript_segments.id
                        """,
                    arguments: arguments
                )

                let segments = try rows.map(segmentRow)
                let wordsBySegmentID = try fetchWordsBySegmentID(
                    db,
                    segmentIDs: segments.map(\.identity.segmentID)
                )

                return segments.map { segment in
                    SegmentExportRow(
                        identity: segment.identity,
                        startSeconds: segment.startSeconds,
                        endSeconds: segment.endSeconds,
                        text: segment.text,
                        confidence: segment.confidence,
                        createdAt: segment.createdAt,
                        words: wordsBySegmentID[segment.identity.segmentID] ?? []
                    )
                }
            }
        } catch let error as SongReportQuery.QueryError {
            throw error
        } catch let error as TranscriptQuery.QueryError {
            throw error
        } catch {
            throw TranscriptQuery.QueryError.databaseReadFailed
        }
    }

    private func fetchWordsBySegmentID(
        _ db: Database,
        segmentIDs: [Int64]
    ) throws -> [Int64: [TranscriptQuery.TranscriptWord]] {
        guard !segmentIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: segmentIDs.count).joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, segment_id, sequence, speaker_label, start_seconds, end_seconds, text, confidence
                FROM transcript_words
                WHERE segment_id IN (\(placeholders))
                ORDER BY segment_id, sequence, id
                """,
            arguments: StatementArguments(segmentIDs)
        )

        var wordsBySegmentID: [Int64: [TranscriptQuery.TranscriptWord]] = [:]
        for row in rows {
            guard let segmentID: Int64 = row["segment_id"] else {
                throw TranscriptQuery.QueryError.malformedRow("segment_id")
            }
            let word = try transcriptWord(row)
            wordsBySegmentID[segmentID, default: []].append(word)
        }
        return wordsBySegmentID
    }

    private func segmentRow(_ row: Row) throws -> SegmentRow {
        guard let streamID: Int64 = row["stream_id"] else {
            throw TranscriptQuery.QueryError.malformedRow("stream_id")
        }
        guard let streamType: String = row["stream_type"] else {
            throw TranscriptQuery.QueryError.malformedRow("stream_type")
        }
        guard let streamSource: String = row["stream_source"] else {
            throw TranscriptQuery.QueryError.malformedRow("stream_source")
        }
        guard let runID: Int64 = row["run_id"] else {
            throw TranscriptQuery.QueryError.malformedRow("run_id")
        }
        guard let chunkID: Int64 = row["chunk_id"] else {
            throw TranscriptQuery.QueryError.malformedRow("chunk_id")
        }
        guard let segmentID: Int64 = row["segment_id"] else {
            throw TranscriptQuery.QueryError.malformedRow("segment_id")
        }
        guard let sequence: Int = row["sequence"] else {
            throw TranscriptQuery.QueryError.malformedRow("sequence")
        }
        guard let startSeconds: Double = row["start_seconds"] else {
            throw TranscriptQuery.QueryError.malformedRow("start_seconds")
        }
        guard let endSeconds: Double = row["end_seconds"] else {
            throw TranscriptQuery.QueryError.malformedRow("end_seconds")
        }
        guard let text: String = row["text"] else {
            throw TranscriptQuery.QueryError.malformedRow("text")
        }

        return SegmentRow(
            identity: TranscriptQuery.SegmentIdentity(
                streamID: streamID,
                streamType: streamType,
                streamSource: streamSource,
                runID: runID,
                chunkID: chunkID,
                segmentID: segmentID,
                sequence: sequence,
                speakerLabel: row["speaker_label"]
            ),
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            text: text,
            confidence: row["confidence"],
            createdAt: row["created_at"]
        )
    }

    private func transcriptWord(_ row: Row) throws -> TranscriptQuery.TranscriptWord {
        guard let id: Int64 = row["id"] else {
            throw TranscriptQuery.QueryError.malformedRow("word_id")
        }
        guard let sequence: Int = row["sequence"] else {
            throw TranscriptQuery.QueryError.malformedRow("word_sequence")
        }
        guard let startSeconds: Double = row["start_seconds"] else {
            throw TranscriptQuery.QueryError.malformedRow("word_start_seconds")
        }
        guard let endSeconds: Double = row["end_seconds"] else {
            throw TranscriptQuery.QueryError.malformedRow("word_end_seconds")
        }
        guard let text: String = row["text"] else {
            throw TranscriptQuery.QueryError.malformedRow("word_text")
        }

        return TranscriptQuery.TranscriptWord(
            id: id,
            sequence: sequence,
            speakerLabel: row["speaker_label"],
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            text: text,
            confidence: row["confidence"]
        )
    }
}
