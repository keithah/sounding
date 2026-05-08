import Foundation
import GRDB

public enum StreamAppTimelineStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidStreamID
    case streamNotFound
    case invalidLimit(String)
    case invalidWindow
    case invalidFocusedSegmentID
    case focusedSegmentNotFound
    case emptyRawSpeakerLabel
    case emptyDisplayLabel
    case displayLabelTooLong(max: Int)
    case invalidColorToken(String)
    case databaseReadFailed
    case databaseWriteFailed
    case malformedRow(String)

    public var description: String {
        switch self {
        case .invalidStreamID:
            return "Stream timeline requires a valid stream identifier."
        case .streamNotFound:
            return "The selected stream was not found."
        case .invalidLimit(let field):
            return "Stream timeline limit \(field) must be greater than zero."
        case .invalidWindow:
            return "Stream timeline lookback window must be finite and non-negative."
        case .invalidFocusedSegmentID:
            return "Focused transcript refresh requires a valid segment identifier."
        case .focusedSegmentNotFound:
            return "Focused transcript segment was not found for the selected stream."
        case .emptyRawSpeakerLabel:
            return "Speaker label must not be empty."
        case .emptyDisplayLabel:
            return "Speaker display label must not be empty."
        case .displayLabelTooLong(let max):
            return "Speaker display label must be \(max) characters or fewer."
        case .invalidColorToken:
            return "Speaker color token is not supported."
        case .databaseReadFailed:
            return "Stream timeline database read failed."
        case .databaseWriteFailed:
            return "Stream timeline database write failed."
        case .malformedRow(let field):
            return "Stream timeline query returned an unexpected row value for \(field)."
        }
    }
}

public struct StreamAppTimelineStore: Sendable {
    public static let maximumDisplayLabelLength = 64
    public static let allowedColorTokens = StreamAppSpeakerDisplayProjection.allowedColorTokens

    private let database: SoundingDatabase

    public init(database: SoundingDatabase) {
        self.database = database
    }

    public func snapshot(request: StreamAppTimelineRequest) throws -> StreamAppTimelineSnapshot {
        try validate(request)
        do {
            return try database.read { db in
                guard try streamExists(request.streamID, db: db) else {
                    throw StreamAppTimelineStoreError.streamNotFound
                }

                let lowerBound = request.lookbackSeconds.flatMap { lookback -> Double? in
                    guard let player = request.player else { return nil }
                    return max(0, player.liveEdgeSeconds - lookback)
                }
                let overrides = try speakerOverrides(streamID: request.streamID, db: db)
                let segmentRows = try fetchSegmentRows(
                    request: request, lowerBound: lowerBound, db: db)
                let segmentIDs = segmentRows.map(\.id)
                let wordsBySegment = try fetchWords(
                    segmentIDs: segmentIDs,
                    wordLimitPerParagraph: request.wordLimitPerParagraph,
                    overrides: overrides,
                    db: db
                )
                let speakerLabelsBySegment = try fetchSpeakerLabels(
                    for: segmentRows,
                    db: db
                )
                let paragraphs = segmentRows.map { row in
                    let rawSpeakerLabel = firstNonEmpty([
                        row.speakerLabel,
                        speakerLabelsBySegment[row.id],
                    ])
                    let display = speakerDisplay(rawLabel: rawSpeakerLabel, overrides: overrides)
                    return StreamAppTranscriptParagraph(
                        id: row.id,
                        streamID: request.streamID,
                        runID: row.runID,
                        chunkID: row.chunkID,
                        sequence: row.sequence,
                        speakerDisplay: display,
                        startSeconds: row.startSeconds,
                        endSeconds: row.endSeconds,
                        startTimestamp: timestamp(
                            runStartedAt: row.runStartedAt,
                            offsetSeconds: row.startSeconds
                        ),
                        endTimestamp: timestamp(
                            runStartedAt: row.runStartedAt,
                            offsetSeconds: row.endSeconds
                        ),
                        text: row.text,
                        confidence: row.confidence,
                        words: wordsBySegment[row.id] ?? []
                    )
                }
                let speakers = speakerDisplays(
                    rawLabels: segmentRows.map { row in
                        firstNonEmpty([row.speakerLabel, speakerLabelsBySegment[row.id]])
                    },
                    overrides: overrides
                )
                let songMetadata = try fetchSongMetadata(
                    request: request, lowerBound: lowerBound, db: db)
                let eventMetadata = try fetchEventMetadata(
                    request: request, lowerBound: lowerBound, db: db)
                let metadata = coalescedMetadataChanges(songMetadata + eventMetadata)
                let recentMetadata = Array(
                    metadata
                        .filter { $0.kind == .song }
                        .sorted(by: metadataSort)
                        .prefix(request.metadataLimit)
                )
                let currentMetadata = currentMetadataItem(
                    in: metadata.filter { $0.kind == .song },
                    playerPosition: request.player?.positionSeconds
                )
                let timelineItems = makeTimelineItems(
                    paragraphs: paragraphs,
                    metadata: metadata,
                    player: request.player,
                    limit: request.timelineLimit
                )
                let latestSegmentEnd = try latestSegmentEndSeconds(
                    streamID: request.streamID, db: db)
                let diagnostics = makeDiagnostics(
                    request: request,
                    latestSegmentEndSeconds: latestSegmentEnd
                )

                return StreamAppTimelineSnapshot(
                    streamID: request.streamID,
                    transcriptParagraphs: paragraphs,
                    speakers: speakers,
                    currentMetadata: currentMetadata,
                    recentMetadata: recentMetadata,
                    timelineItems: timelineItems,
                    diagnostics: diagnostics
                )
            }
        } catch let error as StreamAppTimelineStoreError {
            throw error
        } catch {
            throw StreamAppTimelineStoreError.databaseReadFailed
        }
    }

    @discardableResult
    public func clearTranscript(streamID: Int64) throws -> Int {
        try clearTimeline(streamID: streamID)
    }

    @discardableResult
    public func clearTimeline(streamID: Int64) throws -> Int {
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
                    deletedCount += try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM transcript_words WHERE segment_id IN (\(placeholders))",
                        arguments: arguments
                    ) ?? 0
                    try db.execute(
                        sql: "DELETE FROM transcript_words WHERE segment_id IN (\(placeholders))",
                        arguments: arguments
                    )
                    deletedCount += try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM transcript_segments_fts WHERE rowid IN (\(placeholders))",
                        arguments: arguments
                    ) ?? 0
                    try db.execute(
                        sql: "DELETE FROM transcript_segments_fts WHERE rowid IN (\(placeholders))",
                        arguments: arguments
                    )
                    deletedCount += segmentIDs.count
                    try db.execute(
                        sql: "DELETE FROM transcript_segments WHERE id IN (\(placeholders))",
                        arguments: arguments
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
                deletedCount += try deleteCounted(
                    table: "hls_ingest_segments",
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

    public func updateSpeakerDisplay(
        streamID: Int64,
        rawLabel: String,
        displayLabel: String,
        colorToken: String? = nil,
        updatedAt: String? = nil
    ) throws {
        guard streamID > 0 else { throw StreamAppTimelineStoreError.invalidStreamID }
        let rawLabel = try validateRawSpeakerLabel(rawLabel)
        let displayLabel = try validateDisplayLabel(displayLabel)
        let colorToken = try validateColorToken(colorToken ?? fallbackColorToken(for: rawLabel))
        let updatedAt = updatedAt ?? ISO8601DateFormatter().string(from: Date())

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

    private func validate(_ request: StreamAppTimelineRequest) throws {
        guard request.streamID > 0 else { throw StreamAppTimelineStoreError.invalidStreamID }
        if request.paragraphLimit <= 0 {
            throw StreamAppTimelineStoreError.invalidLimit("paragraphLimit")
        }
        if request.wordLimitPerParagraph <= 0 {
            throw StreamAppTimelineStoreError.invalidLimit("wordLimitPerParagraph")
        }
        if request.metadataLimit <= 0 {
            throw StreamAppTimelineStoreError.invalidLimit("metadataLimit")
        }
        if request.timelineLimit <= 0 {
            throw StreamAppTimelineStoreError.invalidLimit("timelineLimit")
        }
        if let lookback = request.lookbackSeconds, !lookback.isFinite || lookback < 0 {
            throw StreamAppTimelineStoreError.invalidWindow
        }
        if let focusedSegmentID = request.focusedSegmentID, focusedSegmentID <= 0 {
            throw StreamAppTimelineStoreError.invalidFocusedSegmentID
        }
    }

    private func validateRawSpeakerLabel(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StreamAppTimelineStoreError.emptyRawSpeakerLabel }
        return trimmed
    }

    private func validateDisplayLabel(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StreamAppTimelineStoreError.emptyDisplayLabel }
        guard trimmed.count <= Self.maximumDisplayLabelLength else {
            throw StreamAppTimelineStoreError.displayLabelTooLong(
                max: Self.maximumDisplayLabelLength)
        }
        return trimmed
    }

    private func validateColorToken(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.allowedColorTokens.contains(trimmed) else {
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

    private struct SegmentRow {
        var id: Int64
        var runID: Int64
        var chunkID: Int64
        var sequence: Int
        var runStartedAt: String
        var speakerLabel: String?
        var startSeconds: Double
        var endSeconds: Double
        var text: String
        var confidence: Double?
    }

    private func fetchSegmentRows(
        request: StreamAppTimelineRequest,
        lowerBound: Double?,
        db: Database
    ) throws -> [SegmentRow] {
        if let focusedSegmentID = request.focusedSegmentID {
            return try fetchFocusedSegmentRows(
                request: request,
                focusedSegmentID: focusedSegmentID,
                db: db
            )
        }

        var arguments: StatementArguments = [request.streamID]
        var windowClause = ""
        if let lowerBound {
            windowClause = "AND transcript_segments.end_seconds >= ?"
            arguments += [lowerBound]
        }
        arguments += [request.paragraphLimit]

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM (
                    SELECT
                        transcript_segments.id,
                        transcript_segments.run_id,
                        transcript_segments.chunk_id,
                        transcript_segments.sequence,
                        ingest_runs.started_at AS run_started_at,
                        transcript_segments.speaker_label,
                        transcript_segments.start_seconds,
                        transcript_segments.end_seconds,
                        transcript_segments.text,
                        transcript_segments.confidence
                    FROM transcript_segments
                    JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
                    WHERE ingest_runs.stream_id = ?
                      \(windowClause)
                    ORDER BY transcript_segments.end_seconds DESC,
                             transcript_segments.start_seconds DESC,
                             transcript_segments.id DESC
                    LIMIT ?
                ) AS bounded_segments
                ORDER BY start_seconds, id
                """,
            arguments: arguments
        )

        return try decodeSegmentRows(rows)
    }

    private func fetchFocusedSegmentRows(
        request: StreamAppTimelineRequest,
        focusedSegmentID: Int64,
        db: Database
    ) throws -> [SegmentRow] {
        let focusExists = try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM transcript_segments
                    JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
                    WHERE ingest_runs.stream_id = ?
                      AND transcript_segments.id = ?
                )
                """,
            arguments: [request.streamID, focusedSegmentID]
        ) ?? false
        guard focusExists else {
            throw StreamAppTimelineStoreError.focusedSegmentNotFound
        }

        let rows = try Row.fetchAll(
            db,
            sql: """
                WITH ordered_segments AS (
                    SELECT
                        transcript_segments.id,
                        transcript_segments.run_id,
                        transcript_segments.chunk_id,
                        transcript_segments.sequence,
                        ingest_runs.started_at AS run_started_at,
                        transcript_segments.speaker_label,
                        transcript_segments.start_seconds,
                        transcript_segments.end_seconds,
                        transcript_segments.text,
                        transcript_segments.confidence,
                        ROW_NUMBER() OVER (
                            ORDER BY transcript_segments.start_seconds, transcript_segments.id
                        ) AS segment_rank
                    FROM transcript_segments
                    JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
                    WHERE ingest_runs.stream_id = ?
                ),
                focused_segment AS (
                    SELECT segment_rank AS focus_rank
                    FROM ordered_segments
                    WHERE id = ?
                )
                SELECT * FROM (
                    SELECT
                        ordered_segments.id,
                        ordered_segments.run_id,
                        ordered_segments.chunk_id,
                        ordered_segments.sequence,
                        ordered_segments.run_started_at,
                        ordered_segments.speaker_label,
                        ordered_segments.start_seconds,
                        ordered_segments.end_seconds,
                        ordered_segments.text,
                        ordered_segments.confidence
                    FROM ordered_segments, focused_segment
                    ORDER BY ABS(ordered_segments.segment_rank - focused_segment.focus_rank),
                             ordered_segments.segment_rank
                    LIMIT ?
                ) AS focused_window
                ORDER BY start_seconds, id
                """,
            arguments: [request.streamID, focusedSegmentID, request.paragraphLimit]
        )

        return try decodeSegmentRows(rows)
    }

    private func decodeSegmentRows(_ rows: [Row]) throws -> [SegmentRow] {
        try rows.map { row in
            guard let id: Int64 = row["id"] else {
                throw StreamAppTimelineStoreError.malformedRow("segment_id")
            }
            guard let runID: Int64 = row["run_id"] else {
                throw StreamAppTimelineStoreError.malformedRow("run_id")
            }
            guard let chunkID: Int64 = row["chunk_id"] else {
                throw StreamAppTimelineStoreError.malformedRow("chunk_id")
            }
            guard let sequence: Int = row["sequence"] else {
                throw StreamAppTimelineStoreError.malformedRow("sequence")
            }
            guard let runStartedAt: String = row["run_started_at"] else {
                throw StreamAppTimelineStoreError.malformedRow("run_started_at")
            }
            guard let startSeconds: Double = row["start_seconds"] else {
                throw StreamAppTimelineStoreError.malformedRow("start_seconds")
            }
            guard let endSeconds: Double = row["end_seconds"] else {
                throw StreamAppTimelineStoreError.malformedRow("end_seconds")
            }
            guard let text: String = row["text"] else {
                throw StreamAppTimelineStoreError.malformedRow("text")
            }
            return SegmentRow(
                id: id,
                runID: runID,
                chunkID: chunkID,
                sequence: sequence,
                runStartedAt: runStartedAt,
                speakerLabel: row["speaker_label"],
                startSeconds: startSeconds,
                endSeconds: endSeconds,
                text: text,
                confidence: row["confidence"]
            )
        }
    }

    private func fetchWords(
        segmentIDs: [Int64],
        wordLimitPerParagraph: Int,
        overrides: [String: StreamAppSpeakerDisplay],
        db: Database
    ) throws -> [Int64: [StreamAppTranscriptWord]] {
        guard !segmentIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: segmentIDs.count).joined(separator: ",")
        var arguments = StatementArguments(segmentIDs)
        arguments += [wordLimitPerParagraph]
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM (
                    SELECT
                        transcript_words.id,
                        transcript_words.segment_id,
                        transcript_words.sequence,
                        transcript_words.speaker_label,
                        transcript_words.start_seconds,
                        transcript_words.end_seconds,
                        transcript_words.text,
                        transcript_words.confidence,
                        ROW_NUMBER() OVER (
                            PARTITION BY transcript_words.segment_id
                            ORDER BY transcript_words.sequence, transcript_words.id
                        ) AS word_rank
                    FROM transcript_words
                    WHERE transcript_words.segment_id IN (\(placeholders))
                ) AS ranked_words
                WHERE word_rank <= ?
                ORDER BY segment_id, sequence, id
                """,
            arguments: arguments
        )

        var result: [Int64: [StreamAppTranscriptWord]] = [:]
        for row in rows {
            guard let id: Int64 = row["id"] else {
                throw StreamAppTimelineStoreError.malformedRow("word_id")
            }
            guard let segmentID: Int64 = row["segment_id"] else {
                throw StreamAppTimelineStoreError.malformedRow("segment_id")
            }
            guard let sequence: Int = row["sequence"] else {
                throw StreamAppTimelineStoreError.malformedRow("word_sequence")
            }
            guard let startSeconds: Double = row["start_seconds"] else {
                throw StreamAppTimelineStoreError.malformedRow("word_start_seconds")
            }
            guard let endSeconds: Double = row["end_seconds"] else {
                throw StreamAppTimelineStoreError.malformedRow("word_end_seconds")
            }
            guard let text: String = row["text"] else {
                throw StreamAppTimelineStoreError.malformedRow("word_text")
            }
            let display = speakerDisplay(rawLabel: row["speaker_label"], overrides: overrides)
            result[segmentID, default: []].append(
                StreamAppTranscriptWord(
                    id: id,
                    segmentID: segmentID,
                    sequence: sequence,
                    speakerDisplay: display,
                    startSeconds: startSeconds,
                    endSeconds: endSeconds,
                    text: text,
                    confidence: row["confidence"]
                )
            )
        }
        return result
    }

    private struct SpeakerTurnRow {
        var chunkID: Int64
        var speakerLabel: String
        var startSeconds: Double
        var endSeconds: Double
    }

    private func fetchSpeakerLabels(
        for segmentRows: [SegmentRow],
        db: Database
    ) throws -> [Int64: String] {
        let chunkIDs = Array(Set(segmentRows.map(\.chunkID))).sorted()
        guard !chunkIDs.isEmpty else { return [:] }
        let placeholders = sqlPlaceholders(count: chunkIDs.count)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT chunk_id, speaker_label, start_seconds, end_seconds
                FROM speaker_turns
                WHERE chunk_id IN (\(placeholders))
                ORDER BY chunk_id, start_seconds, end_seconds, speaker_label
                """,
            arguments: StatementArguments(chunkIDs)
        )
        var turnsByChunk: [Int64: [SpeakerTurnRow]] = [:]
        for row in rows {
            guard let chunkID: Int64 = row["chunk_id"] else {
                throw StreamAppTimelineStoreError.malformedRow("speaker_turn_chunk_id")
            }
            guard let speakerLabel: String = row["speaker_label"] else {
                throw StreamAppTimelineStoreError.malformedRow("speaker_turn_speaker_label")
            }
            guard let startSeconds: Double = row["start_seconds"] else {
                throw StreamAppTimelineStoreError.malformedRow("speaker_turn_start_seconds")
            }
            guard let endSeconds: Double = row["end_seconds"] else {
                throw StreamAppTimelineStoreError.malformedRow("speaker_turn_end_seconds")
            }
            turnsByChunk[chunkID, default: []].append(
                SpeakerTurnRow(
                    chunkID: chunkID,
                    speakerLabel: speakerLabel,
                    startSeconds: startSeconds,
                    endSeconds: endSeconds
                )
            )
        }

        var labels: [Int64: String] = [:]
        for segment in segmentRows {
            guard let label = speakerLabel(
                forStart: segment.startSeconds,
                end: segment.endSeconds,
                in: turnsByChunk[segment.chunkID] ?? []
            ) else { continue }
            labels[segment.id] = label
        }
        return labels
    }

    private func fetchSongMetadata(
        request: StreamAppTimelineRequest,
        lowerBound: Double?,
        db: Database
    ) throws -> [StreamAppMetadataItem] {
        var arguments: StatementArguments = [request.streamID]
        var windowClause = ""
        if let lowerBound {
            windowClause = "AND song_plays.end_seconds >= ?"
            arguments += [lowerBound]
        }
        var unknownFilterClause = ""
        if request.hideDeterministicUnknownSongs {
            unknownFilterClause = """
                AND NOT (
                  song_plays.source IN ('deterministic_fingerprint', 'chromaprint')
                  AND songs.is_unknown = 1
                  AND songs.song_key LIKE 'fingerprint:%'
                )
                """
        }
        arguments += [max(request.metadataLimit, request.timelineLimit)]

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    song_plays.id,
                    song_plays.start_seconds,
                    song_plays.end_seconds,
                    song_plays.confidence,
                    ingest_runs.started_at AS run_started_at,
                    songs.title,
                    songs.artist,
                    songs.display_name,
                    songs.album
                FROM song_plays INDEXED BY song_plays_on_stream_run_time
                JOIN ingest_runs ON ingest_runs.id = song_plays.run_id
                JOIN songs ON songs.id = song_plays.song_id
                WHERE song_plays.stream_id = ?
                  \(unknownFilterClause)
                  \(windowClause)
                ORDER BY song_plays.start_seconds, song_plays.id
                LIMIT ?
                """,
            arguments: arguments
        )

        return try rows.map { row in
            guard let id: Int64 = row["id"] else {
                throw StreamAppTimelineStoreError.malformedRow("song_play_id")
            }
            guard let startSeconds: Double = row["start_seconds"] else {
                throw StreamAppTimelineStoreError.malformedRow("song_start_seconds")
            }
            guard let endSeconds: Double = row["end_seconds"] else {
                throw StreamAppTimelineStoreError.malformedRow("song_end_seconds")
            }
            guard let displayName: String = row["display_name"] else {
                throw StreamAppTimelineStoreError.malformedRow("song_display_name")
            }
            guard let runStartedAt: String = row["run_started_at"] else {
                throw StreamAppTimelineStoreError.malformedRow("song_run_started_at")
            }
            let songTitle: String? = row["title"]
            let artist: String? = row["artist"]
            return StreamAppMetadataItem(
                id: "song:\(id)",
                kind: .song,
                startSeconds: startSeconds,
                endSeconds: endSeconds,
                startTimestamp: timestamp(runStartedAt: runStartedAt, offsetSeconds: startSeconds),
                endTimestamp: timestamp(runStartedAt: runStartedAt, offsetSeconds: endSeconds),
                title: firstNonEmpty([songTitle, displayName]) ?? displayName,
                artist: artist,
                subtitle: row["album"],
                confidence: row["confidence"]
            )
        }
    }

    private func fetchEventMetadata(
        request: StreamAppTimelineRequest,
        lowerBound: Double?,
        db: Database
    ) throws -> [StreamAppMetadataItem] {
        var arguments: StatementArguments = [request.streamID]
        var windowClause = ""
        if let lowerBound {
            windowClause = "AND ad_events.pts IS NOT NULL AND ad_events.pts >= ?"
            arguments += [lowerBound]
        }
        arguments += [max(request.metadataLimit, request.timelineLimit)]
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    ad_events.id,
                    ad_events.classification,
                    ad_events.marker_type,
                    ad_events.pts,
                    ad_events.segment,
                    ingest_runs.started_at AS run_started_at,
                    json_extract(ad_events.payload_json, '$.Tags.TIT2') AS id3_title,
                    json_extract(ad_events.payload_json, '$.Tags.TPE1') AS id3_artist,
                    json_extract(ad_events.payload_json, '$.Tags.TALB') AS id3_album
                FROM ad_events
                JOIN ingest_runs ON ingest_runs.id = ad_events.run_id
                WHERE ingest_runs.stream_id = ?
                  AND ad_events.pts IS NOT NULL
                  AND (
                    ad_events.marker_type != 'ID3'
                    OR json_extract(ad_events.payload_json, '$.Tags.TIT2') IS NOT NULL
                    OR json_extract(ad_events.payload_json, '$.Tags.TPE1') IS NOT NULL
                    OR json_extract(ad_events.payload_json, '$.Tags.TALB') IS NOT NULL
                  )
                  \(windowClause)
                ORDER BY ad_events.pts, ad_events.observed_at, ad_events.id
                LIMIT ?
                """,
            arguments: arguments
        )

        return try rows.map { row in
            guard let id: Int64 = row["id"] else {
                throw StreamAppTimelineStoreError.malformedRow("event_id")
            }
            guard let classification: String = row["classification"] else {
                throw StreamAppTimelineStoreError.malformedRow("event_classification")
            }
            guard let markerType: String = row["marker_type"] else {
                throw StreamAppTimelineStoreError.malformedRow("event_marker_type")
            }
            guard let pts: Double = row["pts"] else {
                throw StreamAppTimelineStoreError.malformedRow("event_pts")
            }
            guard let runStartedAt: String = row["run_started_at"] else {
                throw StreamAppTimelineStoreError.malformedRow("event_run_started_at")
            }
            let id3Title: String? = row["id3_title"]
            let id3Artist: String? = row["id3_artist"]
            let id3Album: String? = row["id3_album"]
            let hasSongMetadata = id3Title?.isEmpty == false
            return StreamAppMetadataItem(
                id: "event:\(id)",
                kind: hasSongMetadata ? .song : .event,
                startSeconds: pts,
                startTimestamp: timestamp(runStartedAt: runStartedAt, offsetSeconds: pts),
                title: id3Title?.isEmpty == false ? id3Title! : classification,
                artist: id3Artist,
                subtitle: firstNonEmpty([id3Album, markerType])
            )
        }
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        values.first { $0?.isEmpty == false } ?? nil
    }

    private func timestamp(runStartedAt: String, offsetSeconds: Double) -> String? {
        guard offsetSeconds.isFinite else { return nil }
        guard let runStart = ISO8601DateFormatter().date(from: runStartedAt) else { return nil }
        return ISO8601DateFormatter().string(from: runStart.addingTimeInterval(offsetSeconds))
    }

    private func sqlPlaceholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private func latestSegmentEndSeconds(streamID: Int64, db: Database) throws -> Double? {
        try Double.fetchOne(
            db,
            sql: """
                SELECT MAX(transcript_segments.end_seconds)
                FROM transcript_segments
                JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
                WHERE ingest_runs.stream_id = ?
                """,
            arguments: [streamID]
        )
    }

    private func speakerOverrides(streamID: Int64, db: Database) throws -> [String:
        StreamAppSpeakerDisplay]
    {
        do {
            return try StreamAppSpeakerDisplayProjection.overrides(streamID: streamID, db: db)
        } catch StreamAppSpeakerDisplayProjectionError.malformedRow(let field) {
            throw StreamAppTimelineStoreError.malformedRow(field)
        }
    }

    private func speakerDisplay(
        rawLabel: String?,
        overrides: [String: StreamAppSpeakerDisplay]
    ) -> StreamAppSpeakerDisplay {
        StreamAppSpeakerDisplayProjection.display(rawLabel: rawLabel, overrides: overrides)
    }

    private func speakerDisplays(
        from segmentRows: [SegmentRow],
        overrides: [String: StreamAppSpeakerDisplay]
    ) -> [StreamAppSpeakerDisplay] {
        speakerDisplays(rawLabels: segmentRows.map(\.speakerLabel), overrides: overrides)
    }

    private func speakerDisplays(
        rawLabels: [String?],
        overrides: [String: StreamAppSpeakerDisplay]
    ) -> [StreamAppSpeakerDisplay] {
        StreamAppSpeakerDisplayProjection.displays(
            rawLabels: rawLabels,
            overrides: overrides
        )
    }

    private func speakerLabel(
        forStart startSeconds: Double,
        end endSeconds: Double,
        in turns: [SpeakerTurnRow]
    ) -> String? {
        let midpoint = (startSeconds + endSeconds) / 2
        if let containing = turns.first(where: {
            $0.startSeconds <= midpoint && $0.endSeconds >= midpoint
        }) {
            return containing.speakerLabel
        }
        return turns
            .map { turn -> (label: String, overlap: Double) in
                let overlap = max(0, min(endSeconds, turn.endSeconds) - max(startSeconds, turn.startSeconds))
                return (turn.speakerLabel, overlap)
            }
            .filter { $0.overlap > 0 }
            .max { $0.overlap < $1.overlap }?
            .label
    }

    private func fallbackColorToken(for rawLabel: String) -> String {
        StreamAppSpeakerDisplayProjection.fallbackColorToken(for: rawLabel)
    }

    private func metadataSort(_ lhs: StreamAppMetadataItem, _ rhs: StreamAppMetadataItem) -> Bool {
        if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds > rhs.startSeconds }
        return lhs.id < rhs.id
    }

    private func coalescedMetadataChanges(_ items: [StreamAppMetadataItem]) -> [StreamAppMetadataItem] {
        let eventItems = items.filter { $0.kind != .song }
        let songItems = items.filter { $0.kind == .song }
        let samplesByTimestamp = Dictionary(grouping: songItems) { item in
            Int((item.startSeconds * 10).rounded())
        }
        let sorted = (samplesByTimestamp.values.compactMap(preferredMetadataSample) + eventItems).sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.id < $1.id
        }
        var coalesced: [StreamAppMetadataItem] = []
        for item in sorted {
            if item.kind != .song {
                coalesced.append(item)
                continue
            }
            if let last = coalesced.last {
                if isSameMetadataChange(last, item) {
                    coalesced[coalesced.count - 1].endSeconds = max(
                        coalesced[coalesced.count - 1].endSeconds ?? last.startSeconds,
                        item.endSeconds ?? item.startSeconds
                    )
                    coalesced[coalesced.count - 1].endTimestamp = item.endTimestamp
                    continue
                }
                coalesced[coalesced.count - 1].endSeconds = item.startSeconds
                coalesced[coalesced.count - 1].endTimestamp = item.startTimestamp
            }
            var next = item
            next.endSeconds = item.endSeconds ?? item.startSeconds + 8
            coalesced.append(next)
        }
        return coalesced
    }

    private func preferredMetadataSample(_ items: [StreamAppMetadataItem]) -> StreamAppMetadataItem? {
        items.max { lhs, rhs in
            let lhsScore = metadataPreferenceScore(lhs)
            let rhsScore = metadataPreferenceScore(rhs)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
            return metadataIDNumber(lhs.id) < metadataIDNumber(rhs.id)
        }
    }

    private func metadataPreferenceScore(_ item: StreamAppMetadataItem) -> Int {
        var score = item.kind == .song ? 100 : 0
        if firstNonEmpty([item.artist]) != nil { score += 20 }
        if !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 10 }
        if firstNonEmpty([item.subtitle]) != nil { score += 1 }
        return score
    }

    private func metadataIDNumber(_ id: String) -> Int64 {
        Int64(id.split(separator: ":").last ?? "") ?? 0
    }

    private func isSameMetadataChange(
        _ lhs: StreamAppMetadataItem,
        _ rhs: StreamAppMetadataItem
    ) -> Bool {
        lhs.kind == rhs.kind
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.subtitle == rhs.subtitle
    }

    private func currentMetadataItem(
        in items: [StreamAppMetadataItem],
        playerPosition: Double?
    ) -> StreamAppMetadataItem? {
        guard let playerPosition else {
            return items.sorted(by: metadataSort).first
        }
        return
            items
            .filter { item in
                item.startSeconds <= playerPosition
                    && (item.endSeconds ?? item.startSeconds) >= playerPosition
            }
            .sorted(by: metadataSort)
            .first
    }

    private func makeTimelineItems(
        paragraphs: [StreamAppTranscriptParagraph],
        metadata: [StreamAppMetadataItem],
        player: AppPlayerTimelineSnapshot?,
        limit: Int
    ) -> [StreamAppTimelineItem] {
        let transcriptItems = coalescedTranscriptParagraphs(
            transcriptParagraphsWithMetadataSpeakers(paragraphs, metadata: metadata),
            metadata: metadata
        ).map { paragraph in
            StreamAppTimelineItem(
                id: "transcript:\(paragraph.id)",
                kind: .transcript,
                startSeconds: paragraph.startSeconds,
                endSeconds: paragraph.endSeconds,
                startTimestamp: paragraph.startTimestamp,
                endTimestamp: paragraph.endTimestamp,
                title: paragraph.speakerDisplay.displayLabel,
                subtitle: paragraph.text,
                speakerDisplay: paragraph.speakerDisplay,
                isSeekable: isSeekable(paragraph.startSeconds, player: player)
            )
        }
        let metadataItems = metadata.map { item in
            StreamAppTimelineItem(
                id: item.id,
                kind: item.kind == .song ? .song : .event,
                startSeconds: item.startSeconds,
                endSeconds: item.endSeconds,
                startTimestamp: item.startTimestamp,
                endTimestamp: item.endTimestamp,
                title: item.title,
                subtitle: item.subtitle,
                speakerDisplay: metadataSpeakerDisplay(for: item),
                isSeekable: isSeekable(item.startSeconds, player: player)
            )
        }
        return Array(
            coalescedTimelineMetadataRuns(transcriptItems + metadataItems)
                .sorted(by: timelineSort)
                .prefix(limit)
        )
    }

    private func coalescedTimelineMetadataRuns(
        _ items: [StreamAppTimelineItem]
    ) -> [StreamAppTimelineItem] {
        let sorted = items.sorted(by: timelineSort)
        var result: [StreamAppTimelineItem] = []
        for item in sorted {
            if item.kind == .song, result.last?.kind == .song {
                result[result.count - 1] = item
            } else {
                result.append(item)
            }
        }
        return result
    }

    private func coalescedTranscriptParagraphs(
        _ paragraphs: [StreamAppTranscriptParagraph],
        metadata: [StreamAppMetadataItem]
    ) -> [StreamAppTranscriptParagraph] {
        let sorted = paragraphs.sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.id < $1.id
        }
        var result: [StreamAppTranscriptParagraph] = []
        for paragraph in sorted {
            guard let last = result.last else {
                result.append(paragraph)
                continue
            }
            let sameSpeaker = last.speakerDisplay == paragraph.speakerDisplay
            let smallGap = paragraph.startSeconds - last.endSeconds <= 12
            let boundedDuration = paragraph.endSeconds - last.startSeconds <= 60
            let noMetadataBoundary = !hasMetadataBoundary(
                after: last.endSeconds,
                before: paragraph.startSeconds,
                metadata: metadata
            )
            if sameSpeaker && smallGap && boundedDuration && noMetadataBoundary {
                result[result.count - 1] = mergedTranscriptParagraph(last, paragraph)
            } else {
                result.append(paragraph)
            }
        }
        return result
    }

    private func hasMetadataBoundary(
        after lowerBound: Double,
        before upperBound: Double,
        metadata: [StreamAppMetadataItem]
    ) -> Bool {
        metadata.contains { item in
            item.kind == .song
                && item.startSeconds > lowerBound
                && item.startSeconds <= upperBound
        }
    }

    private func transcriptParagraphsWithMetadataSpeakers(
        _ paragraphs: [StreamAppTranscriptParagraph],
        metadata: [StreamAppMetadataItem]
    ) -> [StreamAppTranscriptParagraph] {
        paragraphs.map { paragraph in
            guard let metadataItem = metadataSpeakerMetadata(for: paragraph, metadata: metadata),
                  let speaker = metadataSpeakerDisplay(for: metadataItem) else {
                return paragraph
            }
            var updated = paragraph
            updated.speakerDisplay = speaker
            updated.words = updated.words.map { word in
                var updatedWord = word
                updatedWord.speakerDisplay = speaker
                return updatedWord
            }
            return updated
        }
    }

    private func metadataSpeakerMetadata(
        for paragraph: StreamAppTranscriptParagraph,
        metadata: [StreamAppMetadataItem]
    ) -> StreamAppMetadataItem? {
        let midpoint = (paragraph.startSeconds + paragraph.endSeconds) / 2
        let songMetadata = metadata.filter { $0.kind == .song && firstNonEmpty([$0.artist]) != nil }
        return songMetadata
            .filter({ item in
                let endSeconds = item.endSeconds ?? item.startSeconds + 8
                return item.startSeconds <= midpoint && endSeconds >= midpoint
            })
            .sorted(by: metadataSort)
            .first
    }

    private func isUnknownSpeaker(_ speaker: StreamAppSpeakerDisplay) -> Bool {
        speaker.rawLabel == StreamAppSpeakerDisplayProjection.unknownSpeakerLabel
            || speaker.displayLabel == StreamAppSpeakerDisplayProjection.unknownSpeakerLabel
    }

    private func mergedTranscriptParagraph(
        _ lhs: StreamAppTranscriptParagraph,
        _ rhs: StreamAppTranscriptParagraph
    ) -> StreamAppTranscriptParagraph {
        StreamAppTranscriptParagraph(
            id: lhs.id,
            streamID: lhs.streamID,
            runID: lhs.runID,
            chunkID: lhs.chunkID,
            sequence: lhs.sequence,
            speakerDisplay: lhs.speakerDisplay,
            startSeconds: lhs.startSeconds,
            endSeconds: rhs.endSeconds,
            startTimestamp: lhs.startTimestamp,
            endTimestamp: rhs.endTimestamp,
            text: joinedTranscriptText(lhs.text, rhs.text),
            confidence: [lhs.confidence, rhs.confidence].compactMap { $0 }.min(),
            words: lhs.words + rhs.words
        )
    }

    private func joinedTranscriptText(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }

    private func metadataSpeakerDisplay(for item: StreamAppMetadataItem) -> StreamAppSpeakerDisplay? {
        guard item.kind == .song, let artist = firstNonEmpty([item.artist]) else { return nil }
        return StreamAppSpeakerDisplay(
            rawLabel: artist,
            displayLabel: artist,
            colorToken: fallbackColorToken(for: artist)
        )
    }

    private func timelineSort(_ lhs: StreamAppTimelineItem, _ rhs: StreamAppTimelineItem) -> Bool {
        if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id < rhs.id
    }

    private func isSeekable(_ seconds: Double, player: AppPlayerTimelineSnapshot?) -> Bool {
        guard let player, player.streamID != nil else { return false }
        if let start = player.bufferedStartSeconds, let end = player.bufferedEndSeconds {
            return seconds >= start && seconds <= end
        }
        if let range = player.rollingBuffer?.bufferedRange {
            return seconds >= range.startSeconds && seconds <= range.endSeconds
        }
        return false
    }

    private func makeDiagnostics(
        request: StreamAppTimelineRequest,
        latestSegmentEndSeconds: Double?
    ) -> StreamAppTimelineDiagnostics {
        let player = request.player
        let lagSeconds: Double?
        if let latestSegmentEndSeconds {
            if let player {
                lagSeconds = max(0, player.liveEdgeSeconds - player.positionSeconds)
            } else {
                lagSeconds = max(0, latestSegmentEndSeconds)
            }
        } else if let player {
            lagSeconds = max(0, player.liveEdgeSeconds - player.positionSeconds)
        } else {
            lagSeconds = nil
        }
        return StreamAppTimelineDiagnostics(
            latestSegmentEndSeconds: latestSegmentEndSeconds,
            playerPositionSeconds: player?.positionSeconds,
            playerLiveEdgeSeconds: player?.liveEdgeSeconds,
            lagSeconds: lagSeconds,
            focusedSegmentID: request.focusedSegmentID,
            refreshedAt: request.refreshedAt,
            validationErrors: [],
            bufferedSeekUnavailableMessage: player?.unavailableRangeMessage
        )
    }
}
