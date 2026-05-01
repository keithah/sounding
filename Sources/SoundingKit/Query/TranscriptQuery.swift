import Foundation
import GRDB

/// Read-only transcript search/count service over the persisted M002 transcript timeline.
public struct TranscriptQuery {
    public enum QueryError: Error, Equatable, LocalizedError, Sendable {
        case emptyPhrase
        case invalidLimit
        case invalidContext
        case invalidStreamIDs
        case invalidSpeakerLabels
        case invalidRunStartedAtRange
        case malformedRow(String)
        case databaseReadFailed

        public var errorDescription: String? {
            switch self {
            case .emptyPhrase:
                return "Search phrase must not be empty."
            case .invalidLimit:
                return "Search limit must be greater than zero."
            case .invalidContext:
                return "Context segment count must not be negative."
            case .invalidStreamIDs:
                return "Transcript stream filters must contain positive stream IDs."
            case .invalidSpeakerLabels:
                return "Transcript speaker filters must contain non-empty labels."
            case .invalidRunStartedAtRange:
                return "Transcript run date filters must be non-empty and ordered."
            case .malformedRow(let field):
                return "Transcript query returned an unexpected row value for \(field)."
            case .databaseReadFailed:
                return "Transcript database read failed."
            }
        }
    }

    public struct SegmentIdentity: Codable, Equatable, Sendable {
        public var streamID: Int64
        public var streamType: String
        public var streamSource: String
        public var runID: Int64
        public var chunkID: Int64
        public var segmentID: Int64
        public var sequence: Int
        public var speakerLabel: String?

        public init(
            streamID: Int64,
            streamType: String,
            streamSource: String,
            runID: Int64,
            chunkID: Int64,
            segmentID: Int64,
            sequence: Int,
            speakerLabel: String?
        ) {
            self.streamID = streamID
            self.streamType = streamType
            self.streamSource = streamSource
            self.runID = runID
            self.chunkID = chunkID
            self.segmentID = segmentID
            self.sequence = sequence
            self.speakerLabel = speakerLabel
        }
    }

    public struct TranscriptWord: Codable, Equatable, Sendable {
        public var id: Int64
        public var sequence: Int
        public var speakerLabel: String?
        public var startSeconds: Double
        public var endSeconds: Double
        public var text: String
        public var confidence: Double?

        public init(
            id: Int64,
            sequence: Int,
            speakerLabel: String?,
            startSeconds: Double,
            endSeconds: Double,
            text: String,
            confidence: Double?
        ) {
            self.id = id
            self.sequence = sequence
            self.speakerLabel = speakerLabel
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.text = text
            self.confidence = confidence
        }
    }

    public enum ContextRole: String, Codable, Equatable, Sendable {
        case before
        case match
        case after
    }

    public struct ContextSegment: Codable, Equatable, Sendable {
        public var identity: SegmentIdentity
        public var startSeconds: Double
        public var endSeconds: Double
        public var text: String
        public var role: ContextRole

        public init(
            identity: SegmentIdentity,
            startSeconds: Double,
            endSeconds: Double,
            text: String,
            role: ContextRole
        ) {
            self.identity = identity
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.text = text
            self.role = role
        }
    }

    public struct SearchResult: Codable, Equatable, Sendable {
        public var identity: SegmentIdentity
        public var startSeconds: Double
        public var endSeconds: Double
        public var text: String
        public var confidence: Double?
        public var context: [ContextSegment]
        public var words: [TranscriptWord]
        public var occurrenceCount: Int

        public init(
            identity: SegmentIdentity,
            startSeconds: Double,
            endSeconds: Double,
            text: String,
            confidence: Double?,
            context: [ContextSegment],
            words: [TranscriptWord],
            occurrenceCount: Int
        ) {
            self.identity = identity
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.text = text
            self.confidence = confidence
            self.context = context
            self.words = words
            self.occurrenceCount = occurrenceCount
        }
    }

    public struct CountResult: Codable, Equatable, Sendable {
        public var streamID: Int64
        public var streamType: String
        public var streamSource: String
        public var runID: Int64
        public var speakerLabel: String?
        public var occurrenceCount: Int
        public var matchingSegmentCount: Int

        public init(
            streamID: Int64,
            streamType: String,
            streamSource: String,
            runID: Int64,
            speakerLabel: String?,
            occurrenceCount: Int,
            matchingSegmentCount: Int
        ) {
            self.streamID = streamID
            self.streamType = streamType
            self.streamSource = streamSource
            self.runID = runID
            self.speakerLabel = speakerLabel
            self.occurrenceCount = occurrenceCount
            self.matchingSegmentCount = matchingSegmentCount
        }
    }

    public struct SearchOptions: Equatable, Sendable {
        public var limit: Int
        public var contextSegments: Int
        public var streamIDs: [Int64]?
        public var speakerLabels: [String]?
        public var runStartedAtFrom: String?
        public var runStartedAtThrough: String?

        public init(
            limit: Int = 20,
            contextSegments: Int = 0,
            streamIDs: [Int64]? = nil,
            speakerLabels: [String]? = nil,
            runStartedAtFrom: String? = nil,
            runStartedAtThrough: String? = nil
        ) {
            self.limit = limit
            self.contextSegments = contextSegments
            self.streamIDs = streamIDs
            self.speakerLabels = speakerLabels
            self.runStartedAtFrom = runStartedAtFrom
            self.runStartedAtThrough = runStartedAtThrough
        }
    }

    private struct SearchFilters {
        var streamIDs: [Int64]
        var speakerLabels: [String]
        var runStartedAtFrom: String?
        var runStartedAtThrough: String?

        static let none = SearchFilters(
            streamIDs: [],
            speakerLabels: [],
            runStartedAtFrom: nil,
            runStartedAtThrough: nil
        )
    }

    private struct ValidatedSearchOptions {
        var limit: Int
        var contextSegments: Int
        var filters: SearchFilters
    }

    private struct SegmentRow {
        var identity: SegmentIdentity
        var startSeconds: Double
        var endSeconds: Double
        var text: String
        var confidence: Double?
        var rank: Double
    }

    private struct CountKey: Hashable {
        var streamID: Int64
        var streamType: String
        var streamSource: String
        var runID: Int64
        var speakerLabel: String?
    }

    private let database: SoundingDatabase

    public init(database: SoundingDatabase) {
        self.database = database
    }

    public func search(phrase: String, limit: Int = 20, contextSegments: Int = 0) throws
        -> [SearchResult]
    {
        try search(
            phrase: phrase,
            options: SearchOptions(limit: limit, contextSegments: contextSegments)
        )
    }

    public func search(phrase: String, options: SearchOptions = SearchOptions()) throws
        -> [SearchResult]
    {
        let normalizedPhrase = try normalizePhrase(phrase)
        let options = try validate(options)

        do {
            return try database.read { db in
                let candidates = try fetchCandidateSegments(
                    db,
                    phraseExpression: ftsPhraseExpression(for: normalizedPhrase),
                    limit: options.limit,
                    filters: options.filters
                )
                let matchingSegments = candidates.filter {
                    exactOccurrenceCount(of: normalizedPhrase, in: $0.text) > 0
                }
                let limitedSegments = Array(matchingSegments.prefix(options.limit))
                let wordsBySegmentID = try fetchWordsBySegmentID(
                    db,
                    segmentIDs: limitedSegments.map(\.identity.segmentID)
                )

                return try limitedSegments.map { segment in
                    SearchResult(
                        identity: segment.identity,
                        startSeconds: segment.startSeconds,
                        endSeconds: segment.endSeconds,
                        text: segment.text,
                        confidence: segment.confidence,
                        context: try fetchContextSegments(
                            db, around: segment, contextSegments: options.contextSegments),
                        words: wordsBySegmentID[segment.identity.segmentID] ?? [],
                        occurrenceCount: exactOccurrenceCount(
                            of: normalizedPhrase, in: segment.text)
                    )
                }
            }
        } catch let error as QueryError {
            throw error
        } catch {
            throw QueryError.databaseReadFailed
        }
    }

    public func count(phrase: String) throws -> [CountResult] {
        let normalizedPhrase = try normalizePhrase(phrase)

        do {
            return try database.read { db in
                let candidates = try fetchCandidateSegments(
                    db,
                    phraseExpression: ftsPhraseExpression(for: normalizedPhrase),
                    limit: nil,
                    filters: .none
                )
                var aggregates: [CountKey: (occurrences: Int, segments: Int)] = [:]

                for segment in candidates {
                    let occurrences = exactOccurrenceCount(of: normalizedPhrase, in: segment.text)
                    guard occurrences > 0 else { continue }
                    let key = CountKey(
                        streamID: segment.identity.streamID,
                        streamType: segment.identity.streamType,
                        streamSource: segment.identity.streamSource,
                        runID: segment.identity.runID,
                        speakerLabel: segment.identity.speakerLabel
                    )
                    let previous = aggregates[key] ?? (occurrences: 0, segments: 0)
                    aggregates[key] = (previous.occurrences + occurrences, previous.segments + 1)
                }

                return aggregates.map { key, value in
                    CountResult(
                        streamID: key.streamID,
                        streamType: key.streamType,
                        streamSource: key.streamSource,
                        runID: key.runID,
                        speakerLabel: key.speakerLabel,
                        occurrenceCount: value.occurrences,
                        matchingSegmentCount: value.segments
                    )
                }
                .sorted {
                    ($0.streamID, $0.runID, $0.speakerLabel ?? "", $0.streamType, $0.streamSource)
                        < (
                            $1.streamID, $1.runID, $1.speakerLabel ?? "", $1.streamType,
                            $1.streamSource
                        )
                }
            }
        } catch let error as QueryError {
            throw error
        } catch {
            throw QueryError.databaseReadFailed
        }
    }

    private func fetchCandidateSegments(
        _ db: Database,
        phraseExpression: String,
        limit: Int?,
        filters: SearchFilters
    ) throws -> [SegmentRow] {
        var whereClauses = ["transcript_segments_fts MATCH ?"]
        var arguments: StatementArguments = [phraseExpression]

        if !filters.streamIDs.isEmpty {
            whereClauses.append(
                "streams.id IN (\(sqlPlaceholders(count: filters.streamIDs.count)))")
            for streamID in filters.streamIDs {
                arguments += [streamID]
            }
        }

        if !filters.speakerLabels.isEmpty {
            whereClauses.append(
                "transcript_segments.speaker_label IN (\(sqlPlaceholders(count: filters.speakerLabels.count)))"
            )
            for speakerLabel in filters.speakerLabels {
                arguments += [speakerLabel]
            }
        }

        if let runStartedAtFrom = filters.runStartedAtFrom {
            whereClauses.append("ingest_runs.started_at >= ?")
            arguments += [runStartedAtFrom]
        }

        if let runStartedAtThrough = filters.runStartedAtThrough {
            whereClauses.append("ingest_runs.started_at <= ?")
            arguments += [runStartedAtThrough]
        }

        let whereClause = whereClauses.joined(separator: " AND ")
        let limitClause = limit == nil ? "" : "LIMIT ?"
        if let limit {
            arguments += [limit]
        }

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
                    transcript_segments_fts.rank AS rank
                FROM transcript_segments_fts
                JOIN transcript_segments ON transcript_segments.id = transcript_segments_fts.rowid
                JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
                JOIN streams ON streams.id = ingest_runs.stream_id
                WHERE \(whereClause)
                ORDER BY rank, streams.id, ingest_runs.id, transcript_segments.sequence
                \(limitClause)
                """,
            arguments: arguments
        )

        return try rows.map(segmentRow)
    }

    private func fetchContextSegments(
        _ db: Database,
        around segment: SegmentRow,
        contextSegments: Int
    ) throws -> [ContextSegment] {
        guard contextSegments > 0 else { return [] }
        let lowerBound = segment.identity.sequence - contextSegments
        let upperBound = segment.identity.sequence + contextSegments

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
                    0.0 AS rank
                FROM transcript_segments
                JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
                JOIN streams ON streams.id = ingest_runs.stream_id
                WHERE transcript_segments.run_id = ?
                  AND transcript_segments.sequence BETWEEN ? AND ?
                ORDER BY transcript_segments.sequence
                """,
            arguments: [segment.identity.runID, lowerBound, upperBound]
        )

        return try rows.map { row in
            let contextRow = try segmentRow(row)
            let role: ContextRole
            if contextRow.identity.segmentID == segment.identity.segmentID {
                role = .match
            } else if contextRow.identity.sequence < segment.identity.sequence {
                role = .before
            } else {
                role = .after
            }
            return ContextSegment(
                identity: contextRow.identity,
                startSeconds: contextRow.startSeconds,
                endSeconds: contextRow.endSeconds,
                text: contextRow.text,
                role: role
            )
        }
    }

    private func fetchWordsBySegmentID(_ db: Database, segmentIDs: [Int64]) throws -> [Int64:
        [TranscriptWord]]
    {
        guard !segmentIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: segmentIDs.count).joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, segment_id, sequence, speaker_label, start_seconds, end_seconds, text, confidence
                FROM transcript_words
                WHERE segment_id IN (\(placeholders))
                ORDER BY segment_id, sequence
                """,
            arguments: StatementArguments(segmentIDs)
        )

        var wordsBySegmentID: [Int64: [TranscriptWord]] = [:]
        for row in rows {
            guard let segmentID: Int64 = row["segment_id"] else {
                throw QueryError.malformedRow("segment_id")
            }
            let word = try transcriptWord(row)
            wordsBySegmentID[segmentID, default: []].append(word)
        }
        return wordsBySegmentID
    }

    private func segmentRow(_ row: Row) throws -> SegmentRow {
        guard let streamID: Int64 = row["stream_id"] else {
            throw QueryError.malformedRow("stream_id")
        }
        guard let streamType: String = row["stream_type"] else {
            throw QueryError.malformedRow("stream_type")
        }
        guard let streamSource: String = row["stream_source"] else {
            throw QueryError.malformedRow("stream_source")
        }
        guard let runID: Int64 = row["run_id"] else { throw QueryError.malformedRow("run_id") }
        guard let chunkID: Int64 = row["chunk_id"] else {
            throw QueryError.malformedRow("chunk_id")
        }
        guard let segmentID: Int64 = row["segment_id"] else {
            throw QueryError.malformedRow("segment_id")
        }
        guard let sequence: Int = row["sequence"] else { throw QueryError.malformedRow("sequence") }
        guard let startSeconds: Double = row["start_seconds"] else {
            throw QueryError.malformedRow("start_seconds")
        }
        guard let endSeconds: Double = row["end_seconds"] else {
            throw QueryError.malformedRow("end_seconds")
        }
        guard let text: String = row["text"] else { throw QueryError.malformedRow("text") }
        let speakerLabel: String? = row["speaker_label"]
        let confidence: Double? = row["confidence"]
        let rank: Double = row["rank"] ?? 0

        return SegmentRow(
            identity: SegmentIdentity(
                streamID: streamID,
                streamType: streamType,
                streamSource: streamSource,
                runID: runID,
                chunkID: chunkID,
                segmentID: segmentID,
                sequence: sequence,
                speakerLabel: speakerLabel
            ),
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            text: text,
            confidence: confidence,
            rank: rank
        )
    }

    private func transcriptWord(_ row: Row) throws -> TranscriptWord {
        guard let id: Int64 = row["id"] else { throw QueryError.malformedRow("word_id") }
        guard let sequence: Int = row["sequence"] else {
            throw QueryError.malformedRow("word_sequence")
        }
        guard let startSeconds: Double = row["start_seconds"] else {
            throw QueryError.malformedRow("word_start_seconds")
        }
        guard let endSeconds: Double = row["end_seconds"] else {
            throw QueryError.malformedRow("word_end_seconds")
        }
        guard let text: String = row["text"] else { throw QueryError.malformedRow("word_text") }
        let speakerLabel: String? = row["speaker_label"]
        let confidence: Double? = row["confidence"]

        return TranscriptWord(
            id: id,
            sequence: sequence,
            speakerLabel: speakerLabel,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            text: text,
            confidence: confidence
        )
    }

    private func validate(_ options: SearchOptions) throws -> ValidatedSearchOptions {
        guard options.limit > 0 else { throw QueryError.invalidLimit }
        guard options.contextSegments >= 0 else { throw QueryError.invalidContext }

        let streamIDs = options.streamIDs ?? []
        guard streamIDs.allSatisfy({ $0 > 0 }) else { throw QueryError.invalidStreamIDs }

        let speakerLabels = try (options.speakerLabels ?? []).map { label in
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw QueryError.invalidSpeakerLabels }
            return trimmed
        }

        let runStartedAtFrom = try normalizedDateFilter(options.runStartedAtFrom)
        let runStartedAtThrough = try normalizedDateFilter(options.runStartedAtThrough)
        if let runStartedAtFrom, let runStartedAtThrough, runStartedAtFrom > runStartedAtThrough {
            throw QueryError.invalidRunStartedAtRange
        }

        return ValidatedSearchOptions(
            limit: options.limit,
            contextSegments: options.contextSegments,
            filters: SearchFilters(
                streamIDs: streamIDs,
                speakerLabels: speakerLabels,
                runStartedAtFrom: runStartedAtFrom,
                runStartedAtThrough: runStartedAtThrough
            )
        )
    }

    private func normalizedDateFilter(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QueryError.invalidRunStartedAtRange }
        return trimmed
    }

    private func normalizePhrase(_ phrase: String) throws -> String {
        let normalized = phrase.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !normalized.isEmpty else { throw QueryError.emptyPhrase }
        return normalized
    }

    private func ftsPhraseExpression(for normalizedPhrase: String) -> String {
        "\"\(normalizedPhrase.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func sqlPlaceholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private func exactOccurrenceCount(of normalizedPhrase: String, in text: String) -> Int {
        let normalizedText = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var count = 0
        var searchRange = normalizedText.startIndex..<normalizedText.endIndex

        while let range = normalizedText.range(
            of: normalizedPhrase,
            options: [.caseInsensitive],
            range: searchRange
        ) {
            count += 1
            searchRange = range.upperBound..<normalizedText.endIndex
        }

        return count
    }
}
