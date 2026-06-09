import Foundation
import GRDB

struct StreamAppTimelineMutationStore: Sendable {
    private let database: SoundingDatabase

    init(database: SoundingDatabase) {
        self.database = database
    }

    @discardableResult
    func clearTimeline(streamID: Int64) throws -> Int {
        guard streamID > 0 else { throw StreamAppTimelineStoreError.invalidStreamID }

        do {
            return try database.write { db in
                guard try streamExists(streamID, db: db) else {
                    throw StreamAppTimelineStoreError.streamNotFound
                }

                let runIDs = try Int64.fetchAll(
                    db,
                    sql: "SELECT id FROM ingest_runs WHERE stream_id = ?",
                    arguments: [streamID]
                )
                let segmentIDs = try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT transcript_segments.id
                        FROM transcript_segments
                        JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
                        WHERE ingest_runs.stream_id = ?
                    """,
                    arguments: [streamID]
                )
                var deletedCount = 0

                if !segmentIDs.isEmpty {
                    let placeholders = sqlPlaceholders(count: segmentIDs.count)
                    let arguments = StatementArguments(segmentIDs)
                    deletedCount += try deleteCounted(
                        table: "transcript_words",
                        whereClause: "segment_id IN (\(placeholders))",
                        arguments: arguments,
                        db: db
                    )
                    deletedCount += try deleteCounted(
                        table: "transcript_segments_fts",
                        whereClause: "rowid IN (\(placeholders))",
                        arguments: arguments,
                        db: db
                    )
                    deletedCount += try deleteCounted(
                        table: "transcript_segments",
                        whereClause: "id IN (\(placeholders))",
                        arguments: arguments,
                        db: db
                    )
                }

                if !runIDs.isEmpty {
                    let placeholders = sqlPlaceholders(count: runIDs.count)
                    let arguments = StatementArguments(runIDs)
                    deletedCount += try deleteCounted(
                        table: "speaker_turns",
                        whereClause: "run_id IN (\(placeholders))",
                        arguments: arguments,
                        db: db
                    )
                    deletedCount += try deleteCounted(
                        table: "ad_events",
                        whereClause: "run_id IN (\(placeholders))",
                        arguments: arguments,
                        db: db
                    )
                }

                deletedCount += try deleteCounted(
                    table: "song_plays",
                    whereClause: "stream_id = ?",
                    arguments: [streamID],
                    db: db
                )
                deletedCount += try deleteCounted(
                    table: "audio_fingerprints",
                    whereClause: "stream_id = ?",
                    arguments: [streamID],
                    db: db
                )
                return deletedCount
            }
        } catch let error as StreamAppTimelineStoreError {
            throw error
        } catch {
            throw StreamAppTimelineStoreError.databaseWriteFailed
        }
    }

    func updateSpeakerDisplay(
        streamID: Int64,
        rawLabel: String,
        displayLabel: String,
        colorToken: String?,
        updatedAt: String?
    ) throws {
        guard streamID > 0 else { throw StreamAppTimelineStoreError.invalidStreamID }
        let rawLabel = try validateRawSpeakerLabel(rawLabel)
        let displayLabel = try validateDisplayLabel(displayLabel)
        let colorToken = try validateColorToken(colorToken ?? fallbackColorToken(for: rawLabel))
        let updatedAt = updatedAt ?? SoundingTimestampClock.timestamp()

        do {
            try database.write { db in
                guard try streamExists(streamID, db: db) else {
                    throw StreamAppTimelineStoreError.streamNotFound
                }
                try db.execute(
                    sql: """
                        INSERT INTO stream_app_speaker_overrides (
                            stream_id, raw_label, display_label, color_token, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(stream_id, raw_label) DO UPDATE SET
                            display_label = excluded.display_label,
                            color_token = excluded.color_token,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [streamID, rawLabel, displayLabel, colorToken, updatedAt, updatedAt]
                )
            }
        } catch let error as StreamAppTimelineStoreError {
            throw error
        } catch {
            throw StreamAppTimelineStoreError.databaseWriteFailed
        }
    }

    private func deleteCounted(
        table: String,
        whereClause: String,
        arguments: StatementArguments,
        db: Database
    ) throws -> Int {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM \(table) WHERE \(whereClause)",
            arguments: arguments
        ) ?? 0
        guard count > 0 else { return 0 }
        try db.execute(
            sql: "DELETE FROM \(table) WHERE \(whereClause)",
            arguments: arguments
        )
        return count
    }

    private func validateRawSpeakerLabel(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StreamAppTimelineStoreError.emptyRawSpeakerLabel }
        return trimmed
    }

    private func validateDisplayLabel(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StreamAppTimelineStoreError.emptyDisplayLabel }
        guard trimmed.count <= StreamAppTimelineStore.maximumDisplayLabelLength else {
            throw StreamAppTimelineStoreError.displayLabelTooLong(
                max: StreamAppTimelineStore.maximumDisplayLabelLength)
        }
        return trimmed
    }

    private func validateColorToken(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard StreamAppTimelineStore.allowedColorTokens.contains(trimmed) else {
            throw StreamAppTimelineStoreError.invalidColorToken(value)
        }
        return trimmed
    }

    private func streamExists(_ streamID: Int64, db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM streams WHERE id = ?)",
            arguments: [streamID]
        ) ?? false
    }

    private func sqlPlaceholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private func fallbackColorToken(for rawLabel: String) -> String {
        StreamAppSpeakerDisplayProjection.fallbackColorToken(for: rawLabel)
    }
}
