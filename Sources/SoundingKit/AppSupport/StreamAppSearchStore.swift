import Foundation
import GRDB

public enum StreamAppSearchStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyPhrase
    case invalidLimit
    case invalidContext
    case invalidStreamIDs
    case invalidSpeakerLabels
    case invalidRunStartedAtRange
    case databaseReadFailed

    public var description: String {
        switch self {
        case .emptyPhrase:
            return "Search phrase must not be empty."
        case .invalidLimit:
            return "Search limit must be greater than zero."
        case .invalidContext:
            return "Search context segment count must not be negative."
        case .invalidStreamIDs:
            return "Search stream filters must contain valid stream identifiers."
        case .invalidSpeakerLabels:
            return "Search speaker filters must contain non-empty labels."
        case .invalidRunStartedAtRange:
            return "Search run date filters must be non-empty and ordered."
        case .databaseReadFailed:
            return "Transcript search database read failed."
        }
    }
}

public struct StreamAppSearchStore: Sendable {
    private let database: SoundingDatabase

    public init(database: SoundingDatabase) {
        self.database = database
    }

    public func snapshot(request: StreamAppSearchRequest) throws -> StreamAppSearchSnapshot {
        let results: [TranscriptQuery.SearchResult]
        do {
            results = try TranscriptQuery(database: database).search(
                phrase: request.phrase,
                options: TranscriptQuery.SearchOptions(
                    limit: request.limit,
                    contextSegments: request.contextSegments,
                    streamIDs: request.streamIDs,
                    speakerLabels: request.speakerLabels,
                    runStartedAtFrom: request.runStartedAtFrom,
                    runStartedAtThrough: request.runStartedAtThrough
                )
            )
        } catch let error as TranscriptQuery.QueryError {
            throw mapQueryError(error)
        } catch {
            throw StreamAppSearchStoreError.databaseReadFailed
        }

        do {
            return try database.read { db in
                let metadata = try fetchMetadata(results: results, db: db)
                let overridesByStream = try fetchOverridesByStream(results: results, db: db)
                let projected = results.map { result in
                    project(
                        result, metadata: metadata, overridesByStream: overridesByStream,
                        player: request.player)
                }
                let unseekableMessages = projected.compactMap(\.seekUnavailableMessage)
                let status: StreamAppSearchStatus = projected.isEmpty ? .empty : .results
                let message =
                    projected.isEmpty
                    ? "No transcript results found."
                    : "Found \(projected.count) transcript result(s)."
                let diagnostics = StreamAppSearchDiagnostics(
                    status: status,
                    statusMessage: message,
                    resultCount: projected.count,
                    refreshedAt: request.refreshedAt,
                    unseekableResultCount: projected.filter { !$0.isSeekable }.count,
                    bufferedSeekUnavailableMessages: unseekableMessages
                )
                return StreamAppSearchSnapshot(
                    request: request,
                    results: projected,
                    diagnostics: diagnostics
                )
            }
        } catch let error as StreamAppSearchStoreError {
            throw error
        } catch {
            throw StreamAppSearchStoreError.databaseReadFailed
        }
    }

    private struct RunMetadata: Equatable {
        var streamID: Int64
        var streamName: String?
        var streamType: String
        var sourceDescription: String
        var runStartedAt: String
    }

    private func fetchMetadata(
        results: [TranscriptQuery.SearchResult],
        db: Database
    ) throws -> [Int64: RunMetadata] {
        let runIDs = Array(Set(results.map(\.identity.runID))).sorted()
        guard !runIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: runIDs.count).joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    ingest_runs.id AS run_id,
                    ingest_runs.stream_id,
                    ingest_runs.started_at,
                    streams.name,
                    streams.stream_type,
                    streams.source
                FROM ingest_runs
                JOIN streams ON streams.id = ingest_runs.stream_id
                WHERE ingest_runs.id IN (\(placeholders))
                ORDER BY ingest_runs.id
                """,
            arguments: StatementArguments(runIDs)
        )

        var result: [Int64: RunMetadata] = [:]
        for row in rows {
            guard let runID: Int64 = row["run_id"] else {
                throw StreamAppSearchStoreError.databaseReadFailed
            }
            guard let streamID: Int64 = row["stream_id"] else {
                throw StreamAppSearchStoreError.databaseReadFailed
            }
            guard let startedAt: String = row["started_at"] else {
                throw StreamAppSearchStoreError.databaseReadFailed
            }
            guard let streamType: String = row["stream_type"] else {
                throw StreamAppSearchStoreError.databaseReadFailed
            }
            guard let source: String = row["source"] else {
                throw StreamAppSearchStoreError.databaseReadFailed
            }
            result[runID] = RunMetadata(
                streamID: streamID,
                streamName: row["name"],
                streamType: streamType,
                sourceDescription: IngestRedaction.sourceDescription(source),
                runStartedAt: startedAt
            )
        }
        return result
    }

    private func fetchOverridesByStream(
        results: [TranscriptQuery.SearchResult],
        db: Database
    ) throws -> [Int64: [String: StreamAppSpeakerDisplay]] {
        let streamIDs = Array(Set(results.map(\.identity.streamID))).sorted()
        var result: [Int64: [String: StreamAppSpeakerDisplay]] = [:]
        for streamID in streamIDs {
            do {
                result[streamID] = try StreamAppSpeakerDisplayProjection.overrides(
                    streamID: streamID,
                    db: db
                )
            } catch StreamAppSpeakerDisplayProjectionError.malformedRow {
                throw StreamAppSearchStoreError.databaseReadFailed
            }
        }
        return result
    }

    private func project(
        _ result: TranscriptQuery.SearchResult,
        metadata: [Int64: RunMetadata],
        overridesByStream: [Int64: [String: StreamAppSpeakerDisplay]],
        player: AppPlayerTimelineSnapshot?
    ) -> StreamAppSearchResult {
        let identity = result.identity
        let overrides = overridesByStream[identity.streamID] ?? [:]
        let display = StreamAppSpeakerDisplayProjection.display(
            rawLabel: identity.speakerLabel,
            overrides: overrides
        )
        let seek = seekability(
            seconds: result.startSeconds,
            streamID: identity.streamID,
            player: player
        )
        let context = result.context.map { context in
            let contextDisplay = StreamAppSpeakerDisplayProjection.display(
                rawLabel: context.identity.speakerLabel,
                overrides: overridesByStream[context.identity.streamID] ?? [:]
            )
            return StreamAppSearchContext(
                id: "context:\(context.identity.segmentID)",
                role: context.role,
                segmentID: context.identity.segmentID,
                sequence: context.identity.sequence,
                rawSpeakerLabel: context.identity.speakerLabel,
                speakerDisplay: contextDisplay,
                startSeconds: context.startSeconds,
                endSeconds: context.endSeconds,
                text: context.text
            )
        }
        let words = result.words.map { word in
            StreamAppTranscriptWord(
                id: word.id,
                segmentID: identity.segmentID,
                sequence: word.sequence,
                speakerDisplay: StreamAppSpeakerDisplayProjection.display(
                    rawLabel: word.speakerLabel,
                    overrides: overrides
                ),
                startSeconds: word.startSeconds,
                endSeconds: word.endSeconds,
                text: word.text,
                confidence: word.confidence
            )
        }
        let meta = metadata[identity.runID]
        return StreamAppSearchResult(
            id: "search:\(identity.segmentID)",
            streamID: identity.streamID,
            streamName: meta?.streamName,
            streamType: meta?.streamType ?? identity.streamType,
            sourceDescription: meta?.sourceDescription ?? identity.streamSource,
            runID: identity.runID,
            runStartedAt: meta?.runStartedAt,
            chunkID: identity.chunkID,
            segmentID: identity.segmentID,
            sequence: identity.sequence,
            rawSpeakerLabel: identity.speakerLabel,
            speakerDisplay: display,
            startSeconds: result.startSeconds,
            endSeconds: result.endSeconds,
            text: result.text,
            confidence: result.confidence,
            occurrenceCount: result.occurrenceCount,
            context: context,
            words: words,
            isSeekable: seek.isSeekable,
            seekUnavailableMessage: seek.message
        )
    }

    private func seekability(
        seconds: Double,
        streamID: Int64,
        player: AppPlayerTimelineSnapshot?
    ) -> (isSeekable: Bool, message: String?) {
        guard let player else {
            return (false, "Result is unavailable because no playback buffer is active.")
        }
        guard player.streamID == streamID else {
            return (false, "Result is unavailable because it is not in the active playback stream.")
        }
        if let start = player.bufferedStartSeconds, let end = player.bufferedEndSeconds {
            guard seconds >= start && seconds <= end else {
                return (
                    false,
                    "Result is outside the current playback buffer (available range \(start)-\(end)s)."
                )
            }
            return (true, nil)
        }
        if let range = player.rollingBuffer?.bufferedRange {
            guard seconds >= range.startSeconds && seconds <= range.endSeconds else {
                return (
                    false,
                    "Result is outside the current playback buffer (available range \(range.startSeconds)-\(range.endSeconds)s)."
                )
            }
            return (true, nil)
        }
        return (false, "Result is unavailable because no playback buffer is active.")
    }

    private func mapQueryError(_ error: TranscriptQuery.QueryError) -> StreamAppSearchStoreError {
        switch error {
        case .emptyPhrase:
            return .emptyPhrase
        case .invalidLimit:
            return .invalidLimit
        case .invalidContext:
            return .invalidContext
        case .invalidStreamIDs:
            return .invalidStreamIDs
        case .invalidSpeakerLabels:
            return .invalidSpeakerLabels
        case .invalidRunStartedAtRange:
            return .invalidRunStartedAtRange
        case .malformedRow, .databaseReadFailed:
            return .databaseReadFailed
        }
    }
}
