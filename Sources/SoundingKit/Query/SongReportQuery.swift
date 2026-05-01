import Foundation
import GRDB

/// Read-only song play report service over the persisted M003 song timeline.
public struct SongReportQuery {
    public enum QueryError: Error, Equatable, LocalizedError, Sendable {
        case emptyStreamFilter
        case invalidTimeRange
        case nonFiniteTimeFilter(String)
        case malformedRow(String)
        case databaseReadFailed

        public var errorDescription: String? {
            switch self {
            case .emptyStreamFilter:
                return "Stream filter must not be empty."
            case .invalidTimeRange:
                return "Start time filter must be less than or equal to end time filter."
            case .nonFiniteTimeFilter(let field):
                return "Song report time filter for \(field) must be finite."
            case .malformedRow(let field):
                return "Song report query returned an unexpected row value for \(field)."
            case .databaseReadFailed:
                return "Song report database read failed."
            }
        }
    }

    public struct Filter: Equatable, Sendable {
        public var stream: String?
        public var startSeconds: Double?
        public var endSeconds: Double?

        public init(stream: String? = nil, startSeconds: Double? = nil, endSeconds: Double? = nil) {
            self.stream = stream
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
        }
    }

    public struct PlayIdentity: Codable, Equatable, Sendable {
        public var playID: Int64
        public var streamID: Int64
        public var streamType: String
        public var streamSource: String
        public var runID: Int64
        public var firstChunkID: Int64
        public var firstChunkSequence: Int
        public var lastChunkID: Int64
        public var lastChunkSequence: Int

        public init(
            playID: Int64,
            streamID: Int64,
            streamType: String,
            streamSource: String,
            runID: Int64,
            firstChunkID: Int64,
            firstChunkSequence: Int,
            lastChunkID: Int64,
            lastChunkSequence: Int
        ) {
            self.playID = playID
            self.streamID = streamID
            self.streamType = streamType
            self.streamSource = streamSource
            self.runID = runID
            self.firstChunkID = firstChunkID
            self.firstChunkSequence = firstChunkSequence
            self.lastChunkID = lastChunkID
            self.lastChunkSequence = lastChunkSequence
        }
    }

    public struct SongDisplay: Codable, Equatable, Sendable {
        public var songID: Int64
        public var songKey: String
        public var title: String?
        public var artist: String?
        public var album: String?
        public var isrc: String?
        public var displayName: String
        public var isUnknown: Bool

        public init(
            songID: Int64,
            songKey: String,
            title: String?,
            artist: String?,
            album: String?,
            isrc: String?,
            displayName: String,
            isUnknown: Bool
        ) {
            self.songID = songID
            self.songKey = songKey
            self.title = title
            self.artist = artist
            self.album = album
            self.isrc = isrc
            self.displayName = displayName
            self.isUnknown = isUnknown
        }
    }

    public struct PlayResult: Codable, Equatable, Sendable {
        public var identity: PlayIdentity
        public var song: SongDisplay
        public var startSeconds: Double
        public var endSeconds: Double
        public var durationSeconds: Double
        public var confidence: Double?
        public var source: String?
        public var createdAt: String
        public var updatedAt: String

        public init(
            identity: PlayIdentity,
            song: SongDisplay,
            startSeconds: Double,
            endSeconds: Double,
            durationSeconds: Double,
            confidence: Double?,
            source: String?,
            createdAt: String,
            updatedAt: String
        ) {
            self.identity = identity
            self.song = song
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.durationSeconds = durationSeconds
            self.confidence = confidence
            self.source = source
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    /// A deterministic group of repeated known song plays.
    ///
    /// M003 report fixtures are intentionally small, so repeats are derived by grouping the
    /// already-filtered play report in memory. If operator databases grow large enough to make
    /// unpaginated grouping expensive, this boundary can move to a SQL aggregate without changing
    /// the Codable result shape.
    public struct RepeatResult: Codable, Equatable, Sendable {
        public var groupKey: String
        public var song: SongDisplay
        public var repeatCount: Int
        public var totalDurationSeconds: Double
        public var firstStartSeconds: Double
        public var lastEndSeconds: Double
        public var plays: [PlayResult]

        public init(
            groupKey: String,
            song: SongDisplay,
            repeatCount: Int,
            totalDurationSeconds: Double,
            firstStartSeconds: Double,
            lastEndSeconds: Double,
            plays: [PlayResult]
        ) {
            self.groupKey = groupKey
            self.song = song
            self.repeatCount = repeatCount
            self.totalDurationSeconds = totalDurationSeconds
            self.firstStartSeconds = firstStartSeconds
            self.lastEndSeconds = lastEndSeconds
            self.plays = plays
        }
    }

    private struct RepeatGroupKey: Hashable {
        var rawValue: String
    }

    private let database: SoundingDatabase

    public init(database: SoundingDatabase) {
        self.database = database
    }

    public func plays(filter: Filter = Filter()) throws -> [PlayResult] {
        let normalized = try Self.validate(filter)

        do {
            return try database.read { db in
                var clauses: [String] = []
                var arguments = StatementArguments()

                if let stream = normalized.stream {
                    Self.appendStreamFilterClause(stream, clauses: &clauses, arguments: &arguments)
                }
                if let startSeconds = normalized.startSeconds {
                    clauses.append("song_plays.end_seconds >= ?")
                    arguments += [startSeconds]
                }
                if let endSeconds = normalized.endSeconds {
                    clauses.append("song_plays.start_seconds <= ?")
                    arguments += [endSeconds]
                }

                let whereClause =
                    clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT
                            song_plays.id AS play_id,
                            streams.id AS stream_id,
                            streams.stream_type,
                            streams.source AS stream_source,
                            ingest_runs.id AS run_id,
                            first_chunk.id AS first_chunk_id,
                            first_chunk.sequence AS first_chunk_sequence,
                            last_chunk.id AS last_chunk_id,
                            last_chunk.sequence AS last_chunk_sequence,
                            songs.id AS song_id,
                            songs.song_key,
                            songs.title,
                            songs.artist,
                            songs.album,
                            songs.isrc,
                            songs.display_name,
                            songs.is_unknown,
                            song_plays.start_seconds,
                            song_plays.end_seconds,
                            song_plays.confidence,
                            song_plays.source AS play_source,
                            song_plays.created_at,
                            song_plays.updated_at
                        FROM song_plays INDEXED BY song_plays_on_stream_run_time
                        JOIN songs ON songs.id = song_plays.song_id
                        JOIN streams ON streams.id = song_plays.stream_id
                        JOIN ingest_runs ON ingest_runs.id = song_plays.run_id
                        JOIN ingest_chunks AS first_chunk ON first_chunk.id = song_plays.first_chunk_id
                        JOIN ingest_chunks AS last_chunk ON last_chunk.id = song_plays.last_chunk_id
                        \(whereClause)
                        ORDER BY streams.id, ingest_runs.id, song_plays.start_seconds, song_plays.id
                        """,
                    arguments: arguments
                )

                return try rows.map(playResult)
            }
        } catch let error as QueryError {
            throw error
        } catch {
            throw QueryError.databaseReadFailed
        }
    }

    public func repeats(filter: Filter = Filter()) throws -> [RepeatResult] {
        let grouped = Dictionary(grouping: try plays(filter: filter).filter { !$0.song.isUnknown })
        {
            repeatGroupKey(for: $0.song)
        }

        return grouped.values.compactMap { group -> RepeatResult? in
            let orderedPlays = group.sorted(by: comparePlays)
            guard orderedPlays.count >= 2, let representative = orderedPlays.first else {
                return nil
            }

            return RepeatResult(
                groupKey: repeatGroupKey(for: representative.song).rawValue,
                song: representative.song,
                repeatCount: orderedPlays.count,
                totalDurationSeconds: orderedPlays.reduce(0) { $0 + $1.durationSeconds },
                firstStartSeconds: orderedPlays.map(\.startSeconds).min() ?? 0,
                lastEndSeconds: orderedPlays.map(\.endSeconds).max() ?? 0,
                plays: orderedPlays
            )
        }.sorted(by: compareRepeatResults)
    }

    static func validate(_ filter: Filter) throws -> Filter {
        let stream = filter.stream?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stream, stream.isEmpty {
            throw QueryError.emptyStreamFilter
        }
        if let start = filter.startSeconds, !start.isFinite {
            throw QueryError.nonFiniteTimeFilter("startSeconds")
        }
        if let end = filter.endSeconds, !end.isFinite {
            throw QueryError.nonFiniteTimeFilter("endSeconds")
        }
        if let start = filter.startSeconds, let end = filter.endSeconds, start > end {
            throw QueryError.invalidTimeRange
        }
        return Filter(
            stream: stream, startSeconds: filter.startSeconds, endSeconds: filter.endSeconds)
    }

    static func appendStreamFilterClause(
        _ stream: String,
        clauses: inout [String],
        arguments: inout StatementArguments
    ) {
        clauses.append(
            "(streams.id = ? OR streams.name = ? OR streams.stream_type = ? OR streams.source = ?)")
        arguments += [Int64(stream) ?? -1, stream, stream, stream]
    }

    private func repeatGroupKey(for song: SongDisplay) -> RepeatGroupKey {
        if let artist = normalizedRepeatComponent(song.artist),
            let title = normalizedRepeatComponent(song.title)
        {
            return RepeatGroupKey(rawValue: "artist-title:\(artist):\(title)")
        }

        return RepeatGroupKey(rawValue: "song-key:\(song.songKey)")
    }

    private func normalizedRepeatComponent(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized =
            value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return normalized.isEmpty ? nil : normalized
    }

    private func compareRepeatResults(_ lhs: RepeatResult, _ rhs: RepeatResult) -> Bool {
        if lhs.repeatCount != rhs.repeatCount { return lhs.repeatCount > rhs.repeatCount }
        if lhs.firstStartSeconds != rhs.firstStartSeconds {
            return lhs.firstStartSeconds < rhs.firstStartSeconds
        }
        if lhs.lastEndSeconds != rhs.lastEndSeconds {
            return lhs.lastEndSeconds < rhs.lastEndSeconds
        }
        if lhs.groupKey != rhs.groupKey { return lhs.groupKey < rhs.groupKey }
        return lhs.song.songID < rhs.song.songID
    }

    private func comparePlays(_ lhs: PlayResult, _ rhs: PlayResult) -> Bool {
        if lhs.identity.streamID != rhs.identity.streamID {
            return lhs.identity.streamID < rhs.identity.streamID
        }
        if lhs.identity.runID != rhs.identity.runID {
            return lhs.identity.runID < rhs.identity.runID
        }
        if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
        return lhs.identity.playID < rhs.identity.playID
    }

    private func playResult(_ row: Row) throws -> PlayResult {
        guard let playID: Int64 = row["play_id"] else { throw QueryError.malformedRow("play_id") }
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
        guard let firstChunkID: Int64 = row["first_chunk_id"] else {
            throw QueryError.malformedRow("first_chunk_id")
        }
        guard let firstChunkSequence: Int = row["first_chunk_sequence"] else {
            throw QueryError.malformedRow("first_chunk_sequence")
        }
        guard let lastChunkID: Int64 = row["last_chunk_id"] else {
            throw QueryError.malformedRow("last_chunk_id")
        }
        guard let lastChunkSequence: Int = row["last_chunk_sequence"] else {
            throw QueryError.malformedRow("last_chunk_sequence")
        }
        guard let songID: Int64 = row["song_id"] else { throw QueryError.malformedRow("song_id") }
        guard let songKey: String = row["song_key"] else {
            throw QueryError.malformedRow("song_key")
        }
        guard let displayName: String = row["display_name"] else {
            throw QueryError.malformedRow("display_name")
        }
        guard let isUnknown: Bool = row["is_unknown"] else {
            throw QueryError.malformedRow("is_unknown")
        }
        guard let startSeconds: Double = row["start_seconds"] else {
            throw QueryError.malformedRow("start_seconds")
        }
        guard let endSeconds: Double = row["end_seconds"] else {
            throw QueryError.malformedRow("end_seconds")
        }
        guard let createdAt: String = row["created_at"] else {
            throw QueryError.malformedRow("created_at")
        }
        guard let updatedAt: String = row["updated_at"] else {
            throw QueryError.malformedRow("updated_at")
        }

        return PlayResult(
            identity: PlayIdentity(
                playID: playID,
                streamID: streamID,
                streamType: streamType,
                streamSource: streamSource,
                runID: runID,
                firstChunkID: firstChunkID,
                firstChunkSequence: firstChunkSequence,
                lastChunkID: lastChunkID,
                lastChunkSequence: lastChunkSequence
            ),
            song: SongDisplay(
                songID: songID,
                songKey: songKey,
                title: row["title"],
                artist: row["artist"],
                album: row["album"],
                isrc: row["isrc"],
                displayName: displayName,
                isUnknown: isUnknown
            ),
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            durationSeconds: max(0, endSeconds - startSeconds),
            confidence: row["confidence"],
            source: row["play_source"],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
