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
            return try database.write { db in
                guard try streamExists(request.streamID, db: db) else {
                    throw StreamAppTimelineStoreError.streamNotFound
                }

                let lowerBound = request.lookbackSeconds.flatMap { lookback -> Double? in
                    guard let player = request.player else { return nil }
                    return max(0, player.liveEdgeSeconds - lookback)
                }
                let liveWallClockLowerBound = liveWallClockLowerBound(for: request)
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
                    request: request,
                    lowerBound: lowerBound,
                    wallClockLowerBound: liveWallClockLowerBound,
                    db: db
                )
                let eventMetadata = try fetchEventMetadata(
                    request: request,
                    lowerBound: lowerBound,
                    wallClockLowerBound: liveWallClockLowerBound,
                    db: db
                )
                let projection = StreamAppTimelineProjection(
                    paragraphs: paragraphs,
                    metadata: songMetadata + eventMetadata,
                    player: request.player,
                    transcriptionPolicy: request.transcriptionPolicy
                )
                let recentMetadata = projection.recentMetadata(limit: request.metadataLimit)
                let currentMetadata = projection.currentMetadata()
                let timelineItems = projection.timelineItems(limit: request.timelineLimit)
                let adClassifications = try cachedTranscriptAdClassifications(
                    for: projection.paragraphs,
                    classifiedAt: request.refreshedAt,
                    db: db
                )
                let timelineRail = makeTimelineRail(
                    request: request,
                    metadata: projection.metadataChanges,
                    paragraphs: projection.paragraphs,
                    adClassifications: adClassifications
                )
                let latestSegmentEnd = try latestSegmentEndSeconds(
                    streamID: request.streamID, db: db)
                let diagnostics = makeDiagnostics(
                    request: request,
                    latestSegmentEndSeconds: latestSegmentEnd
                )

                return StreamAppTimelineSnapshot(
                    streamID: request.streamID,
                    transcriptParagraphs: projection.paragraphs,
                    speakers: speakers,
                    currentMetadata: currentMetadata,
                    recentMetadata: recentMetadata,
                    timelineItems: timelineItems,
                    timelineRail: timelineRail,
                    diagnostics: diagnostics
                )
            }
        } catch let error as StreamAppTimelineStoreError {
            throw error
        } catch {
            throw StreamAppTimelineStoreError.databaseReadFailed
        }
    }

    private func cachedTranscriptAdClassifications(
        for paragraphs: [StreamAppTranscriptParagraph],
        classifiedAt: String,
        db: Database
    ) throws -> [Int64: TranscriptAdClassificationCacheRow] {
        let segmentIDs = paragraphs.map(\.id)
        var cached = try TranscriptAdClassificationCache.fetch(segmentIDs: segmentIDs, db: db)
        let missingParagraphs = paragraphs.filter { cached[$0.id] == nil }
        guard !missingParagraphs.isEmpty else { return cached }

        let scores = TranscriptAdScorer.scores(for: paragraphs)
        for paragraph in missingParagraphs {
            let score = scores[paragraph.id] ?? TranscriptAdScorer.score(paragraph: paragraph, neighbors: [])
            try TranscriptAdClassificationCache.upsert(
                TranscriptAdClassificationCacheEntry(
                    identity: TranscriptAdClassificationCacheIdentity(
                        segmentID: paragraph.id,
                        classifier: TranscriptAdScorer.classifier,
                        classifierVersion: TranscriptAdScorer.classifierVersion
                    ),
                    isAd: score.confidence >= 0.50,
                    confidence: score.confidence,
                    signals: Self.cacheSignals(for: score),
                    classifiedAt: classifiedAt
                ),
                db: db
            )
        }
        cached = try TranscriptAdClassificationCache.fetch(segmentIDs: segmentIDs, db: db)
        return cached
    }

    private static func cacheSignals(for score: TranscriptAdScorer.Score) -> [String] {
        guard !score.signals.isEmpty else { return ["heuristic:no-signals"] }
        return score.signals
    }

    @discardableResult
    public func clearTranscript(streamID: Int64) throws -> Int {
        try clearTimeline(streamID: streamID)
    }

    @discardableResult
    public func clearTimeline(streamID: Int64) throws -> Int {
        try StreamAppTimelineMutationStore(database: database).clearTimeline(streamID: streamID)
    }

    public func updateSpeakerDisplay(
        streamID: Int64,
        rawLabel: String,
        displayLabel: String,
        colorToken: String? = nil,
        updatedAt: String? = nil
    ) throws {
        try StreamAppTimelineMutationStore(database: database).updateSpeakerDisplay(
            streamID: streamID,
            rawLabel: rawLabel,
            displayLabel: displayLabel,
            colorToken: colorToken,
            updatedAt: updatedAt
        )
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
        wallClockLowerBound: String?,
        db: Database
    ) throws -> [StreamAppMetadataItem] {
        var arguments: StatementArguments = [request.streamID]
        var windowClause = ""
        if let lowerBound {
            windowClause = "AND song_plays.end_seconds >= ?"
            arguments += [lowerBound]
        }
        var wallClockClause = ""
        if let wallClockLowerBound {
            wallClockClause = "AND ingest_runs.started_at >= ?"
            arguments += [wallClockLowerBound]
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
                SELECT * FROM (
                    SELECT
                        song_plays.id,
                        song_plays.start_seconds,
                        song_plays.end_seconds,
                        song_plays.confidence,
                        ingest_runs.started_at AS run_started_at,
                        song_plays.source,
                        songs.title,
                        songs.artist,
                        songs.display_name,
                        songs.album,
                        songs.is_unknown
                    FROM song_plays INDEXED BY song_plays_on_stream_start_id
                    JOIN ingest_runs ON ingest_runs.id = song_plays.run_id
                    JOIN songs ON songs.id = song_plays.song_id
                    WHERE song_plays.stream_id = ?
                      \(unknownFilterClause)
                      \(windowClause)
                      \(wallClockClause)
                    ORDER BY song_plays.start_seconds DESC, song_plays.id DESC
                    LIMIT ?
                ) AS bounded_song_metadata
                ORDER BY start_seconds, id
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
                confidence: row["confidence"],
                source: row["source"],
                isUnknown: row["is_unknown"] ?? false
            )
        }
    }

    private func fetchEventMetadata(
        request: StreamAppTimelineRequest,
        lowerBound: Double?,
        wallClockLowerBound: String?,
        db: Database
    ) throws -> [StreamAppMetadataItem] {
        var arguments: StatementArguments = [request.streamID]
        var windowClause = ""
        if let lowerBound {
            windowClause = "AND ad_events.pts IS NOT NULL AND ad_events.pts >= ?"
            arguments += [lowerBound]
        }
        var wallClockClause = ""
        if let wallClockLowerBound {
            wallClockClause = "AND ad_events.observed_at >= ?"
            arguments += [wallClockLowerBound]
        }
        arguments += [max(request.metadataLimit, request.timelineLimit)]
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM (
                    SELECT
                        ad_events.id,
                        ad_events.classification,
                        ad_events.marker_type,
                        ad_events.pts,
                        ad_events.segment,
                        ad_events.source,
                        ad_events.payload_json,
                        ingest_runs.started_at AS run_started_at,
                        CASE
                        WHEN ad_events.marker_type = 'SCTE35'
                          AND json_extract(ad_events.payload_json, '$.Tag') = '#EXT-X-CUE-OUT'
                        THEN 'Ad break start'
                        WHEN ad_events.marker_type = 'SCTE35'
                          AND json_extract(ad_events.payload_json, '$.Tag') = '#EXT-X-CUE-IN'
                        THEN 'Ad break end'
                        WHEN ad_events.marker_type = 'ID3'
                          AND lower(ad_events.payload_json) LIKE '%advertisement%'
                        THEN 'AD'
                        ELSE COALESCE(
                        json_extract(ad_events.payload_json, '$.Tags.TIT2'),
                        json_extract(ad_events.payload_json, '$.Tags.Title'),
                        json_extract(ad_events.payload_json, '$.Fields.TIT2'),
                        json_extract(ad_events.payload_json, '$.Fields.Title'),
                        json_extract(ad_events.payload_json, '$.Fields.title'),
                        json_extract(ad_events.payload_json, '$.Fields.StreamTitle'),
                        json_extract(ad_events.payload_json, '$.Fields.ProgramTitle'),
                        json_extract(ad_events.payload_json, '$.Fields.Program'),
                        json_extract(ad_events.payload_json, '$.Fields.SegmentationTypeName'),
                        json_extract(ad_events.payload_json, '$.Command.Title'),
                        json_extract(ad_events.payload_json, '$.Command.ProgramTitle')
                        )
                        END AS marker_title,
                        COALESCE(
                        json_extract(ad_events.payload_json, '$.Tags.TPE1'),
                        json_extract(ad_events.payload_json, '$.Tags.Artist'),
                        json_extract(ad_events.payload_json, '$.Fields.TPE1'),
                        json_extract(ad_events.payload_json, '$.Fields.Artist'),
                        json_extract(ad_events.payload_json, '$.Fields.artist'),
                        json_extract(ad_events.payload_json, '$.Fields.Performer'),
                        json_extract(ad_events.payload_json, '$.Fields.Provider'),
                        json_extract(ad_events.payload_json, '$.Command.Artist'),
                        json_extract(ad_events.payload_json, '$.Command.Provider')
                        ) AS marker_artist,
                        COALESCE(
                        json_extract(ad_events.payload_json, '$.Tags.TALB'),
                        json_extract(ad_events.payload_json, '$.Tags.Album'),
                        json_extract(ad_events.payload_json, '$.Fields.TALB'),
                        json_extract(ad_events.payload_json, '$.Fields.Album'),
                        json_extract(ad_events.payload_json, '$.Fields.album'),
                        json_extract(ad_events.payload_json, '$.Fields.Series'),
                        json_extract(ad_events.payload_json, '$.Command.Album')
                        ) AS marker_album,
                        COALESCE(
                        json_extract(ad_events.payload_json, '$.BreakDuration'),
                        json_extract(ad_events.payload_json, '$.Fields.BreakDuration'),
                        json_extract(ad_events.payload_json, '$.Command.BreakDuration'),
                        CAST(json_extract(ad_events.payload_json, '$.Fields.durationMilliseconds') AS REAL) / 1000.0,
                        CAST(json_extract(ad_events.payload_json, '$.Fields.DurationMilliseconds') AS REAL) / 1000.0,
                        CAST(json_extract(ad_events.payload_json, '$.Fields.durationMs') AS REAL) / 1000.0,
                        CAST(json_extract(ad_events.payload_json, '$.Fields.DurationMs') AS REAL) / 1000.0
                        ) AS marker_break_duration
                    FROM ad_events
                    JOIN ingest_runs ON ingest_runs.id = ad_events.run_id
                    WHERE ingest_runs.stream_id = ?
                      AND ad_events.pts IS NOT NULL
                      AND (
                        ad_events.marker_type != 'ID3'
                        OR json_extract(ad_events.payload_json, '$.Tags.TIT2') IS NOT NULL
                        OR json_extract(ad_events.payload_json, '$.Tags.TPE1') IS NOT NULL
                        OR json_extract(ad_events.payload_json, '$.Tags.TALB') IS NOT NULL
                        OR json_extract(ad_events.payload_json, '$.Fields.Title') IS NOT NULL
                        OR json_extract(ad_events.payload_json, '$.Fields.Artist') IS NOT NULL
                        OR lower(ad_events.payload_json) LIKE '%advertisement%'
                      )
                      \(windowClause)
                      \(wallClockClause)
                    ORDER BY ad_events.pts DESC, ad_events.observed_at DESC, ad_events.id DESC
                    LIMIT ?
                ) AS bounded_event_metadata
                ORDER BY pts, id
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
            let markerTitle: String? = row["marker_title"]
            let markerArtist: String? = row["marker_artist"]
            let markerAlbum: String? = row["marker_album"]
            let markerBreakDuration: Double? = row["marker_break_duration"]
            let source = timelineMetadataSource(
                markerType: markerType,
                rawSource: row["source"]
            )
            let markerPayload: String? = row["payload_json"]
            let safeMarkerPayload = markerPayload.map(IngestRedaction.diagnostic)
            let isAdvertisementMarker = markerPayload?
                .range(of: "advertisement", options: [.caseInsensitive, .diacriticInsensitive]) != nil
            let isPlaceholderAdMarker = isStingrayPlaceholderAdMarker(
                markerTitle: markerTitle,
                markerArtist: markerArtist
            )
            let displayTitle = eventDisplayTitle(
                classification: classification,
                markerType: markerType,
                markerTitle: markerTitle,
                isAdvertisementMarker: isAdvertisementMarker,
                isPlaceholderAdMarker: isPlaceholderAdMarker
            ) ?? classification
            let isAdBoundary = classification == MarkerClassification.adStart.rawValue
                || classification == MarkerClassification.adEnd.rawValue
                || displayTitle.caseInsensitiveCompare("AD") == .orderedSame
                || isAdvertisementMarker
                || isPlaceholderAdMarker
            let isMusicMetadata = !isAdBoundary
                && ProgramMetadataClassifier.isMusic(
                    title: displayTitle,
                    artist: markerArtist,
                    album: markerAlbum,
                    source: ProgramMetadataSource(raw: source),
                    isUnknown: false
                )
            let subtitle = metadataEventSubtitle(
                markerTitle: markerTitle,
                displayTitle: displayTitle,
                markerAlbum: markerAlbum,
                markerType: markerType,
                source: source,
                classification: classification,
                duration: markerBreakDuration,
                isAdvertisementMarker: isAdvertisementMarker,
                isAdBoundary: isAdBoundary
            )
            return StreamAppMetadataItem(
                id: "event:\(id)",
                kind: isMusicMetadata ? .song : .event,
                startSeconds: pts,
                startTimestamp: timestamp(runStartedAt: runStartedAt, offsetSeconds: pts),
                title: displayTitle,
                artist: markerArtist,
                subtitle: subtitle,
                source: source,
                rawMetadata: safeMarkerPayload
            )
        }
    }

    private func metadataEventSubtitle(
        markerTitle: String?,
        displayTitle: String,
        markerAlbum: String?,
        markerType: String,
        source: String?,
        classification: String,
        duration: Double?,
        isAdvertisementMarker: Bool,
        isAdBoundary: Bool
    ) -> String? {
        guard isAdBoundary else {
            return firstNonEmpty([
                markerAlbum,
                markerType
            ])
        }
        let parts = [
            adDurationSubtitle(for: classification, duration: duration),
            rawMarkerSubtitle(markerTitle, displayTitle: displayTitle),
            source,
            isAdvertisementMarker ? "Advertisement" : nil,
            markerAlbum
        ]
        .compactMap { value -> String? in
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }
        var seen: Set<String> = []
        let uniqueParts = parts.filter { part in
            let key = part.lowercased()
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
        return uniqueParts.isEmpty ? markerType : uniqueParts.joined(separator: " | ")
    }

    private func rawMarkerSubtitle(_ markerTitle: String?, displayTitle: String) -> String? {
        guard let markerTitle = markerTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !markerTitle.isEmpty,
              markerTitle.caseInsensitiveCompare(displayTitle) != .orderedSame,
              markerTitle.caseInsensitiveCompare("AD") != .orderedSame
        else {
            return nil
        }
        return markerTitle
    }

    private func adDurationSubtitle(for classification: String, duration: Double?) -> String? {
        guard classification == MarkerClassification.adStart.rawValue,
              let duration,
              duration.isFinite,
              duration > 0
        else {
            return nil
        }
        return String(format: "Duration %.3fs", duration)
    }

    private func eventDisplayTitle(
        classification: String,
        markerType: String,
        markerTitle: String?,
        isAdvertisementMarker: Bool,
        isPlaceholderAdMarker: Bool = false
    ) -> String? {
        if isPlaceholderAdMarker
            || genericAdvertisementTitle(markerTitle, isAdvertisementMarker: isAdvertisementMarker) {
            return "AD"
        }
        if let boundaryTitle = eventTitle(for: classification) {
            return boundaryTitle
        }
        return firstNonEmpty([markerTitle, markerType])
    }

    private func genericAdvertisementTitle(
        _ markerTitle: String?,
        isAdvertisementMarker: Bool
    ) -> Bool {
        guard isAdvertisementMarker else { return false }
        let normalizedTitle = markerTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedTitle == nil
            || normalizedTitle?.isEmpty == true
            || normalizedTitle == "ad"
            || normalizedTitle == "advertisement"
    }

    private func isStingrayPlaceholderAdMarker(
        markerTitle: String?,
        markerArtist: String?
    ) -> Bool {
        guard let markerTitle = markerTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !markerTitle.isEmpty
        else { return false }
        let normalizedArtist = markerArtist?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let titleIsPlaceholder = markerTitle.range(
            of: #"^(stingray\s*-\s*)?padultht[0-9]+$"#,
            options: [.regularExpression]
        ) != nil
        guard titleIsPlaceholder else { return false }
        return normalizedArtist?.contains("stingray") == true
            || markerTitle.hasPrefix("stingray")
    }

    private func eventTitle(for classification: String) -> String? {
        switch classification {
        case MarkerClassification.adStart.rawValue:
            return "Ad break start"
        case MarkerClassification.adEnd.rawValue:
            return "Ad break end"
        default:
            return nil
        }
    }

    private func timelineMetadataSource(markerType: String, rawSource: String?) -> String? {
        let markerSource = ProgramMetadataSource(raw: markerType)
        if markerSource != .other {
            return markerSource.rawValue
        }
        return firstNonEmpty([rawSource, markerType])
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        values.first { $0?.isEmpty == false } ?? nil
    }

    private func timestamp(runStartedAt: String, offsetSeconds: Double) -> String? {
        guard offsetSeconds.isFinite else { return nil }
        return StreamAppTimelineTimestampFormatter.timestamp(
            runStartedAt: runStartedAt,
            offsetSeconds: offsetSeconds
        )
    }

    private func liveWallClockLowerBound(for request: StreamAppTimelineRequest) -> String? {
        guard let player = request.player,
              request.lookbackSeconds == nil,
              player.liveEdgeSeconds.isFinite,
              player.liveEdgeSeconds > 0,
              playerBufferStartsAtSessionOrigin(player) else {
            return nil
        }
        return StreamAppTimelineTimestampFormatter.timestamp(
            from: request.refreshedAt,
            addingSeconds: -(player.liveEdgeSeconds + 120)
        )
    }

    private func playerBufferStartsAtSessionOrigin(_ player: AppPlayerTimelineSnapshot) -> Bool {
        if let bufferedStartSeconds = player.bufferedStartSeconds {
            return bufferedStartSeconds <= 1
        }
        if let range = player.rollingBuffer?.bufferedRange {
            return range.startSeconds <= 1
        }
        return false
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

    private func makeTimelineRail(
        request: StreamAppTimelineRequest,
        metadata: [StreamAppMetadataItem],
        paragraphs: [StreamAppTranscriptParagraph],
        adClassifications: [Int64: TranscriptAdClassificationCacheRow]
    ) -> StreamAppTimelineRailSnapshot {
        let itemEnd = metadata
            .map { $0.endSeconds ?? $0.startSeconds }
            .max()
        let itemStart = metadata.map(\.startSeconds).min()
        let visibleEnd = request.player?.liveEdgeSeconds ?? itemEnd ?? 0
        let visibleStart = request.lookbackSeconds.map { max(0, visibleEnd - $0) }
            ?? itemStart
            ?? 0
        return StreamAppTimelineRailProjection.project(
            metadata: metadata,
            paragraphs: paragraphs,
            adClassifications: adClassifications,
            visibleStartSeconds: visibleStart,
            visibleEndSeconds: visibleEnd
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
        var bestLabel: String?
        var bestOverlap = 0.0
        for turn in turns {
            let overlap = max(0, min(endSeconds, turn.endSeconds) - max(startSeconds, turn.startSeconds))
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestLabel = turn.speakerLabel
            }
        }
        return bestLabel
    }

    private func fallbackColorToken(for rawLabel: String) -> String {
        StreamAppSpeakerDisplayProjection.fallbackColorToken(for: rawLabel)
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

private final class StreamAppTimelineTimestampFormatter: @unchecked Sendable {
    private static let shared = StreamAppTimelineTimestampFormatter()

    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    static func timestamp(runStartedAt: String, offsetSeconds: Double) -> String? {
        shared.timestamp(runStartedAt: runStartedAt, offsetSeconds: offsetSeconds)
    }

    static func timestamp(from timestamp: String, addingSeconds seconds: Double) -> String? {
        shared.timestamp(from: timestamp, addingSeconds: seconds)
    }

    private func timestamp(runStartedAt: String, offsetSeconds: Double) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let runStart = formatter.date(from: runStartedAt) else { return nil }
        return formatter.string(from: runStart.addingTimeInterval(offsetSeconds))
    }

    private func timestamp(from timestamp: String, addingSeconds seconds: Double) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard seconds.isFinite, let date = formatter.date(from: timestamp) else { return nil }
        return formatter.string(from: date.addingTimeInterval(seconds))
    }
}
