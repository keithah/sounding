import Foundation
import GRDB

struct SongPlayStore {
    private let database: SoundingDatabase

    init(database: SoundingDatabase) {
        self.database = database
    }

    func activeTimedMetadataSongPlay(
        streamID: Int64,
        startSeconds: Double,
        endSeconds: Double,
        toleranceSeconds: Double = 15,
        inferredDurationToleranceSeconds: Double = 30
    ) throws -> SongPlayDraft? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        songs.song_key,
                        songs.title,
                        songs.artist,
                        songs.album,
                        songs.isrc,
                        songs.display_name,
                        songs.is_unknown,
                        song_plays.start_seconds AS play_start_seconds,
                        song_plays.confidence,
                        song_plays.source,
                        (
                            SELECT cache.duration_seconds
                            FROM acoustid_lookup_cache AS cache
                            WHERE cache.duration_seconds IS NOT NULL
                              AND cache.duration_seconds > 0
                              AND (
                                  (
                                      TRIM(COALESCE(songs.isrc, '')) <> ''
                                      AND LOWER(TRIM(COALESCE(cache.isrc, ''))) = LOWER(TRIM(songs.isrc))
                                  )
                                  OR (
                                      TRIM(COALESCE(songs.artist, '')) <> ''
                                      AND LOWER(TRIM(COALESCE(cache.title, ''))) = LOWER(TRIM(COALESCE(songs.title, songs.display_name)))
                                      AND LOWER(TRIM(COALESCE(cache.artist, ''))) = LOWER(TRIM(songs.artist))
                                  )
                              )
                            ORDER BY COALESCE(cache.score, 0) DESC, cache.updated_at DESC, cache.id DESC
                            LIMIT 1
                        ) AS expected_duration_seconds
                    FROM song_plays
                    JOIN songs ON songs.id = song_plays.song_id
                    WHERE song_plays.stream_id = ?
                      AND songs.is_unknown = 0
                      AND LOWER(REPLACE(song_plays.source, '-', '_')) IN (
                          'timed_id3', 'id3', 'scte35', 'scte', 'icy', 'icecast', 'icy_stream'
                      )
                      AND song_plays.end_seconds >= ?
                      AND song_plays.start_seconds <= ?
                    ORDER BY song_plays.end_seconds DESC, song_plays.id DESC
                    LIMIT 1
                    """,
                arguments: [
                    streamID,
                    startSeconds - toleranceSeconds,
                    endSeconds + toleranceSeconds
                ]
            ) else {
                return nil
            }
            guard let songKey: String = row["song_key"] else {
                throw SongPlayStoreError.missingSong("active timed metadata song")
            }
            if let durationSeconds: Double = row["expected_duration_seconds"],
               durationSeconds.isFinite,
               durationSeconds > 0,
               let playStartSeconds: Double = row["play_start_seconds"],
               startSeconds > playStartSeconds + durationSeconds + inferredDurationToleranceSeconds {
                return nil
            }
            let displayName: String = row["display_name"] ?? songKey
            return SongPlayDraft(
                song: UnresolvedSongDraft(
                    songKey: songKey,
                    title: row["title"],
                    artist: row["artist"],
                    album: row["album"],
                    isrc: row["isrc"],
                    displayName: displayName,
                    isUnknown: row["is_unknown"] ?? false
                ),
                startSeconds: startSeconds,
                endSeconds: endSeconds,
                confidence: row["confidence"],
                source: row["source"]
            )
        }
    }

    func persist(
        _ play: SongPlayDraft,
        streamID: Int64,
        timeline: IngestChunkTimeline,
        db: Database
    ) throws {
        let songID = try upsertSong(play.song, createdAt: timeline.createdAt, db: db)
        try upsertAdjacentSongPlay(
            play,
            songID: songID,
            streamID: streamID,
            timeline: timeline,
            db: db
        )
    }

    private func upsertSong(
        _ song: UnresolvedSongDraft,
        createdAt: String,
        db: Database
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO songs (
                    song_key, title, artist, album, isrc, display_name,
                    is_unknown, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(song_key) DO UPDATE SET
                    title = excluded.title,
                    artist = excluded.artist,
                    album = excluded.album,
                    isrc = excluded.isrc,
                    display_name = excluded.display_name,
                    is_unknown = excluded.is_unknown,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                song.songKey,
                song.title,
                song.artist,
                song.album,
                song.isrc,
                song.displayName,
                song.isUnknown,
                createdAt,
                createdAt
            ]
        )

        guard let songID = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM songs WHERE song_key = ?",
            arguments: [song.songKey]
        ) else {
            throw SongPlayStoreError.missingSong(song.songKey)
        }
        return songID
    }

    private func upsertAdjacentSongPlay(
        _ play: SongPlayDraft,
        songID: Int64,
        streamID: Int64,
        timeline: IngestChunkTimeline,
        db: Database
    ) throws {
        guard play.endSeconds >= play.startSeconds else {
            throw SongPlayStoreError.invalidTimelineInterval
        }

        if ProgramMetadataSource(raw: play.source).isTimedMetadata {
            try upsertTimedMetadataSongPlay(
                play,
                songID: songID,
                streamID: streamID,
                timeline: timeline,
                db: db
            )
            return
        }

        if let adjacentPlayID = try Int64.fetchOne(
            db,
            sql: """
                SELECT song_plays.id
                FROM song_plays
                JOIN ingest_chunks AS last_chunk ON last_chunk.id = song_plays.last_chunk_id
                JOIN ingest_chunks AS current_chunk ON current_chunk.id = ?
                WHERE song_plays.stream_id = ?
                  AND song_plays.song_id = ?
                  AND song_plays.run_id = ?
                  AND last_chunk.sequence = current_chunk.sequence - 1
                  AND song_plays.end_seconds >= ?
                ORDER BY song_plays.id DESC
                LIMIT 1
                """,
            arguments: [
                timeline.chunkID,
                streamID,
                songID,
                timeline.runID,
                play.startSeconds - 1.0
            ]
        ) {
            try db.execute(
                sql: """
                    UPDATE song_plays
                    SET last_chunk_id = ?,
                        end_seconds = MAX(end_seconds, ?),
                        confidence = COALESCE(?, confidence),
                        source = COALESCE(?, source),
                        updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    timeline.chunkID,
                    play.endSeconds,
                    play.confidence,
                    play.source,
                    timeline.createdAt,
                    adjacentPlayID
                ]
            )
            return
        }

        try insertNewSongPlay(
            play,
            songID: songID,
            streamID: streamID,
            timeline: timeline,
            db: db
        )
    }

    private func upsertTimedMetadataSongPlay(
        _ play: SongPlayDraft,
        songID: Int64,
        streamID: Int64,
        timeline: IngestChunkTimeline,
        db: Database
    ) throws {
        let normalizedSource = ProgramMetadataSource(raw: play.source).rawValue
        let adjacencyToleranceSeconds = 15.0
        if play.song.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            try promoteTitleOnlyTimedMetadataPlays(
                toSongID: songID,
                play: play,
                streamID: streamID,
                timeline: timeline,
                toleranceSeconds: adjacencyToleranceSeconds,
                db: db
            )
        }
        if let adjacentPlayID = try Int64.fetchOne(
            db,
            sql: """
                SELECT song_plays.id
                FROM song_plays
                WHERE song_plays.stream_id = ?
                  AND song_plays.song_id = ?
                  AND LOWER(REPLACE(song_plays.source, '-', '_')) IN (
                      'timed_id3', 'id3', 'scte35', 'scte', 'icy', 'icecast', 'icy_stream'
                  )
                  AND song_plays.end_seconds >= ?
                  AND song_plays.start_seconds <= ?
                ORDER BY song_plays.id DESC
                LIMIT 1
                """,
            arguments: [
                streamID,
                songID,
                play.startSeconds - adjacencyToleranceSeconds,
                play.endSeconds + adjacencyToleranceSeconds
            ]
        ) {
            try db.execute(
                sql: """
                    UPDATE song_plays
                    SET last_chunk_id = ?,
                        end_seconds = MAX(end_seconds, ?),
                        confidence = COALESCE(?, confidence),
                        source = ?,
                        updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    timeline.chunkID,
                    play.endSeconds,
                    play.confidence,
                    normalizedSource,
                    timeline.createdAt,
                    adjacentPlayID
                ]
            )
            return
        }

        var normalizedPlay = play
        normalizedPlay.source = normalizedSource
        try insertNewSongPlay(
            normalizedPlay,
            songID: songID,
            streamID: streamID,
            timeline: timeline,
            db: db
        )
    }

    private func promoteTitleOnlyTimedMetadataPlays(
        toSongID songID: Int64,
        play: SongPlayDraft,
        streamID: Int64,
        timeline: IngestChunkTimeline,
        toleranceSeconds: Double,
        db: Database
    ) throws {
        guard let title = play.song.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else {
            return
        }
        try db.execute(
            sql: """
                UPDATE song_plays
                SET song_id = ?,
                    last_chunk_id = ?,
                    end_seconds = MAX(end_seconds, ?),
                    confidence = COALESCE(?, confidence),
                    source = ?,
                    updated_at = ?
                WHERE stream_id = ?
                  AND LOWER(REPLACE(source, '-', '_')) IN (
                      'timed_id3', 'id3', 'scte35', 'scte', 'icy', 'icecast', 'icy_stream'
                  )
                  AND end_seconds >= ?
                  AND start_seconds <= ?
                  AND song_id IN (
                      SELECT id
                      FROM songs
                      WHERE LOWER(TRIM(COALESCE(title, display_name))) = LOWER(TRIM(?))
                        AND TRIM(COALESCE(artist, '')) = ''
                  )
                """,
            arguments: [
                songID,
                timeline.chunkID,
                play.endSeconds,
                play.confidence,
                ProgramMetadataSource(raw: play.source).rawValue,
                timeline.createdAt,
                streamID,
                play.startSeconds - toleranceSeconds,
                play.endSeconds + toleranceSeconds,
                title,
            ]
        )
    }

    private func insertNewSongPlay(
        _ play: SongPlayDraft,
        songID: Int64,
        streamID: Int64,
        timeline: IngestChunkTimeline,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO song_plays (
                    stream_id, run_id, song_id, first_chunk_id, last_chunk_id,
                    start_seconds, end_seconds, confidence, source,
                    created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                streamID,
                timeline.runID,
                songID,
                timeline.chunkID,
                timeline.chunkID,
                play.startSeconds,
                play.endSeconds,
                play.confidence,
                play.source,
                timeline.createdAt,
                timeline.createdAt
            ]
        )
    }
}

private enum SongPlayStoreError: Error, Equatable {
    case missingSong(String)
    case invalidTimelineInterval
}
