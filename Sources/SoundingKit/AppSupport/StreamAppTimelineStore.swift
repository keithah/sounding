import Foundation
import GRDB

public enum StreamAppTimelineStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidStreamID
    case streamNotFound
    case invalidLimit(String)
    case invalidWindow
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
                let paragraphs = segmentRows.map { row in
                    let display = speakerDisplay(rawLabel: row.speakerLabel, overrides: overrides)
                    return StreamAppTranscriptParagraph(
                        id: row.id,
                        streamID: request.streamID,
                        runID: row.runID,
                        chunkID: row.chunkID,
                        sequence: row.sequence,
                        speakerDisplay: display,
                        startSeconds: row.startSeconds,
                        endSeconds: row.endSeconds,
                        text: row.text,
                        confidence: row.confidence,
                        words: wordsBySegment[row.id] ?? []
                    )
                }
                let speakers = speakerDisplays(from: segmentRows, overrides: overrides)
                let songMetadata = try fetchSongMetadata(
                    request: request, lowerBound: lowerBound, db: db)
                let eventMetadata = try fetchEventMetadata(
                    request: request, lowerBound: lowerBound, db: db)
                let recentMetadata = Array(
                    (songMetadata + eventMetadata)
                        .sorted(by: metadataSort)
                        .prefix(request.metadataLimit)
                )
                let currentMetadata = currentMetadataItem(
                    in: songMetadata,
                    playerPosition: request.player?.positionSeconds
                )
                let timelineItems = makeTimelineItems(
                    paragraphs: paragraphs,
                    metadata: songMetadata + eventMetadata,
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

        return try rows.map { row in
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
        arguments += [max(request.metadataLimit, request.timelineLimit)]

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    song_plays.id,
                    song_plays.start_seconds,
                    song_plays.end_seconds,
                    song_plays.confidence,
                    songs.display_name,
                    songs.album
                FROM song_plays INDEXED BY song_plays_on_stream_run_time
                JOIN songs ON songs.id = song_plays.song_id
                WHERE song_plays.stream_id = ?
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
            return StreamAppMetadataItem(
                id: "song:\(id)",
                kind: .song,
                startSeconds: startSeconds,
                endSeconds: endSeconds,
                title: displayName,
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
                    ad_events.segment
                FROM ad_events
                JOIN ingest_runs ON ingest_runs.id = ad_events.run_id
                WHERE ingest_runs.stream_id = ?
                  AND ad_events.pts IS NOT NULL
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
            return StreamAppMetadataItem(
                id: "event:\(id)",
                kind: .event,
                startSeconds: pts,
                title: classification,
                subtitle: markerType
            )
        }
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
        StreamAppSpeakerDisplayProjection.displays(
            rawLabels: segmentRows.map(\.speakerLabel),
            overrides: overrides
        )
    }

    private func fallbackColorToken(for rawLabel: String) -> String {
        StreamAppSpeakerDisplayProjection.fallbackColorToken(for: rawLabel)
    }

    private func metadataSort(_ lhs: StreamAppMetadataItem, _ rhs: StreamAppMetadataItem) -> Bool {
        if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds > rhs.startSeconds }
        return lhs.id < rhs.id
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
        let transcriptItems = paragraphs.map { paragraph in
            StreamAppTimelineItem(
                id: "transcript:\(paragraph.id)",
                kind: .transcript,
                startSeconds: paragraph.startSeconds,
                endSeconds: paragraph.endSeconds,
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
                title: item.title,
                subtitle: item.subtitle,
                isSeekable: isSeekable(item.startSeconds, player: player)
            )
        }
        return Array((transcriptItems + metadataItems).sorted(by: timelineSort).prefix(limit))
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
            lagSeconds = max(
                0, (player?.liveEdgeSeconds ?? latestSegmentEndSeconds) - latestSegmentEndSeconds)
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
            refreshedAt: request.refreshedAt,
            validationErrors: [],
            bufferedSeekUnavailableMessage: player?.unavailableRangeMessage
        )
    }
}
