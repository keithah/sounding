import GRDB
import XCTest
@testable import SoundingKit

final class SongTimelinePersistenceTests: XCTestCase {
    func testPersistsFingerprintsSongsAndFirstPlayRows() throws {
        let fixture = try makeFixture()

        try fixture.writer.persistTimeline(
            IngestChunkTimeline(
                runID: fixture.runID,
                chunkID: fixture.firstChunkID,
                fingerprints: [
                    AudioFingerprintDraft(
                        algorithm: "chromaprint",
                        algorithmVersion: "1.5.1",
                        fingerprint: "AQADtEmG",
                        fingerprintHash: "fp-hash-001",
                        startSeconds: 0,
                        endSeconds: 10,
                        confidence: 0.98
                    )
                ],
                songPlays: [
                    SongPlayDraft(
                        song: knownSong,
                        startSeconds: 0,
                        endSeconds: 10,
                        confidence: 0.92,
                        source: "local_fingerprint"
                    )
                ],
                createdAt: "2026-05-01T10:00:03Z"
            )
        )

        let rows = try fixture.temporary.database.read { db in
            try (
                fingerprints: Row.fetchAll(db, sql: "SELECT stream_id, run_id, chunk_id, algorithm, algorithm_version, fingerprint, fingerprint_hash, start_seconds, end_seconds FROM audio_fingerprints"),
                songs: Row.fetchAll(db, sql: "SELECT song_key, title, artist, display_name, is_unknown FROM songs"),
                plays: Row.fetchAll(db, sql: "SELECT stream_id, run_id, song_id, first_chunk_id, last_chunk_id, start_seconds, end_seconds, source FROM song_plays")
            )
        }

        XCTAssertEqual(rows.fingerprints.count, 1)
        XCTAssertEqual(rows.fingerprints[0]["stream_id"] as Int64, fixture.streamID)
        XCTAssertEqual(rows.fingerprints[0]["run_id"] as Int64, fixture.runID)
        XCTAssertEqual(rows.fingerprints[0]["chunk_id"] as Int64, fixture.firstChunkID)
        XCTAssertEqual(rows.fingerprints[0]["algorithm"] as String, "chromaprint")
        XCTAssertEqual(rows.fingerprints[0]["algorithm_version"] as String, "1.5.1")
        XCTAssertEqual(rows.fingerprints[0]["fingerprint"] as String, "AQADtEmG")
        XCTAssertEqual(rows.fingerprints[0]["fingerprint_hash"] as String, "fp-hash-001")
        XCTAssertEqual(rows.fingerprints[0]["start_seconds"] as Double, 0)
        XCTAssertEqual(rows.fingerprints[0]["end_seconds"] as Double, 10)

        XCTAssertEqual(rows.songs.count, 1)
        XCTAssertEqual(rows.songs[0]["song_key"] as String, knownSong.songKey)
        XCTAssertEqual(rows.songs[0]["title"] as String, knownSong.title)
        XCTAssertEqual(rows.songs[0]["artist"] as String, knownSong.artist)
        XCTAssertEqual(rows.songs[0]["display_name"] as String, knownSong.displayName)
        XCTAssertEqual(rows.songs[0]["is_unknown"] as Bool, false)

        XCTAssertEqual(rows.plays.count, 1)
        XCTAssertEqual(rows.plays[0]["stream_id"] as Int64, fixture.streamID)
        XCTAssertEqual(rows.plays[0]["run_id"] as Int64, fixture.runID)
        XCTAssertEqual(rows.plays[0]["first_chunk_id"] as Int64, fixture.firstChunkID)
        XCTAssertEqual(rows.plays[0]["last_chunk_id"] as Int64, fixture.firstChunkID)
        XCTAssertEqual(rows.plays[0]["start_seconds"] as Double, 0)
        XCTAssertEqual(rows.plays[0]["end_seconds"] as Double, 10)
        XCTAssertEqual(rows.plays[0]["source"] as String, "local_fingerprint")
    }

    func testAdjacentSameSongChunksExtendExistingPlay() throws {
        let fixture = try makeFixture()

        try fixture.writer.persistTimeline(
            IngestChunkTimeline(
                runID: fixture.runID,
                chunkID: fixture.firstChunkID,
                songPlays: [SongPlayDraft(song: knownSong, startSeconds: 0, endSeconds: 10, confidence: 0.90)],
                createdAt: "2026-05-01T10:00:03Z"
            )
        )
        try fixture.writer.persistTimeline(
            IngestChunkTimeline(
                runID: fixture.runID,
                chunkID: fixture.secondChunkID,
                songPlays: [SongPlayDraft(song: knownSong, startSeconds: 10, endSeconds: 20, confidence: 0.91)],
                createdAt: "2026-05-01T10:00:13Z"
            )
        )

        let plays = try fixture.temporary.database.read { db in
            try Row.fetchAll(db, sql: "SELECT first_chunk_id, last_chunk_id, start_seconds, end_seconds, updated_at FROM song_plays")
        }

        XCTAssertEqual(plays.count, 1)
        XCTAssertEqual(plays[0]["first_chunk_id"] as Int64, fixture.firstChunkID)
        XCTAssertEqual(plays[0]["last_chunk_id"] as Int64, fixture.secondChunkID)
        XCTAssertEqual(plays[0]["start_seconds"] as Double, 0)
        XCTAssertEqual(plays[0]["end_seconds"] as Double, 20)
        XCTAssertEqual(plays[0]["updated_at"] as String, "2026-05-01T10:00:13Z")
    }

    func testAdjacentSameSongChunksExtendExistingPlayAcrossRuns() throws {
        let fixture = try makeFixture()
        let secondRunID = try fixture.writer.createRun(
            streamID: fixture.streamID,
            startedAt: "2026-05-01T10:00:11Z",
            status: .running
        )
        let secondRunChunkID = try fixture.writer.createChunk(
            runID: secondRunID,
            sequence: 1001,
            segmentURI: "segment-1001.ts",
            startedAt: "2026-05-01T10:00:12Z",
            endedAt: "2026-05-01T10:00:18Z"
        )

        try fixture.writer.persistTimeline(
            IngestChunkTimeline(
                runID: fixture.runID,
                chunkID: fixture.firstChunkID,
                songPlays: [SongPlayDraft(song: knownSong, startSeconds: 60, endSeconds: 66, confidence: 1, source: "ID3")],
                createdAt: "2026-05-01T10:00:06Z"
            )
        )
        try fixture.writer.persistTimeline(
            IngestChunkTimeline(
                runID: secondRunID,
                chunkID: secondRunChunkID,
                songPlays: [SongPlayDraft(song: knownSong, startSeconds: 66, endSeconds: 72, confidence: 1, source: "ID3")],
                createdAt: "2026-05-01T10:00:12Z"
            )
        )

        let plays = try fixture.temporary.database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT run_id, first_chunk_id, last_chunk_id, start_seconds, end_seconds, source FROM song_plays")
        }

        XCTAssertEqual(plays.count, 1)
        XCTAssertEqual(plays[0]["run_id"] as Int64, fixture.runID)
        XCTAssertEqual(plays[0]["first_chunk_id"] as Int64, fixture.firstChunkID)
        XCTAssertEqual(plays[0]["last_chunk_id"] as Int64, secondRunChunkID)
        XCTAssertEqual(plays[0]["start_seconds"] as Double, 60)
        XCTAssertEqual(plays[0]["end_seconds"] as Double, 72)
        XCTAssertEqual(plays[0]["source"] as String, "timed_id3")
    }

    func testTimedID3SongRefreshesMergeAcrossCadenceGap() throws {
        let fixture = try makeFixture()
        let secondRunID = try fixture.writer.createRun(
            streamID: fixture.streamID,
            startedAt: "2026-05-01T10:00:20Z",
            status: .running
        )
        let secondRunChunkID = try fixture.writer.createChunk(
            runID: secondRunID,
            sequence: 1002,
            segmentURI: "segment-1002.ts",
            startedAt: "2026-05-01T10:00:24Z",
            endedAt: "2026-05-01T10:00:30Z"
        )

        try fixture.writer.persistTimeline(
            IngestChunkTimeline(
                runID: fixture.runID,
                chunkID: fixture.firstChunkID,
                songPlays: [SongPlayDraft(song: knownSong, startSeconds: 60, endSeconds: 66, confidence: 1, source: "ID3")],
                createdAt: "2026-05-01T10:00:06Z"
            )
        )
        try fixture.writer.persistTimeline(
            IngestChunkTimeline(
                runID: secondRunID,
                chunkID: secondRunChunkID,
                songPlays: [SongPlayDraft(song: knownSong, startSeconds: 78, endSeconds: 84, confidence: 1, source: "ID3")],
                createdAt: "2026-05-01T10:00:24Z"
            )
        )

        let plays = try fixture.temporary.database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT first_chunk_id, last_chunk_id, start_seconds, end_seconds FROM song_plays")
        }

        XCTAssertEqual(plays.count, 1)
        XCTAssertEqual(plays[0]["first_chunk_id"] as Int64, fixture.firstChunkID)
        XCTAssertEqual(plays[0]["last_chunk_id"] as Int64, secondRunChunkID)
        XCTAssertEqual(plays[0]["start_seconds"] as Double, 60)
        XCTAssertEqual(plays[0]["end_seconds"] as Double, 84)
    }

    func testAdjacentSameSongChunksWithTimelineGapRemainSeparatePlays() throws {
        let fixture = try makeFixture()

        try fixture.writer.persistTimeline(
            IngestChunkTimeline(
                runID: fixture.runID,
                chunkID: fixture.firstChunkID,
                songPlays: [SongPlayDraft(song: knownSong, startSeconds: 0, endSeconds: 10, confidence: 0.90)],
                createdAt: "2026-05-01T10:00:03Z"
            )
        )
        try fixture.writer.persistTimeline(
            IngestChunkTimeline(
                runID: fixture.runID,
                chunkID: fixture.secondChunkID,
                songPlays: [SongPlayDraft(song: knownSong, startSeconds: 22, endSeconds: 30, confidence: 0.91)],
                createdAt: "2026-05-01T10:00:23Z"
            )
        )

        let plays = try fixture.temporary.database.read { db in
            try Row.fetchAll(db, sql: "SELECT first_chunk_id, last_chunk_id, start_seconds, end_seconds FROM song_plays ORDER BY start_seconds")
        }

        XCTAssertEqual(plays.count, 2)
        XCTAssertEqual(plays[0]["first_chunk_id"] as Int64, fixture.firstChunkID)
        XCTAssertEqual(plays[0]["last_chunk_id"] as Int64, fixture.firstChunkID)
        XCTAssertEqual(plays[0]["start_seconds"] as Double, 0)
        XCTAssertEqual(plays[0]["end_seconds"] as Double, 10)
        XCTAssertEqual(plays[1]["first_chunk_id"] as Int64, fixture.secondChunkID)
        XCTAssertEqual(plays[1]["last_chunk_id"] as Int64, fixture.secondChunkID)
        XCTAssertEqual(plays[1]["start_seconds"] as Double, 22)
        XCTAssertEqual(plays[1]["end_seconds"] as Double, 30)
    }

    func testFingerprintSongAcrossRunsDoesNotUseTimedMetadataMerge() throws {
        let fixture = try makeFixture()
        let secondRunID = try fixture.writer.createRun(
            streamID: fixture.streamID,
            startedAt: "2026-05-01T10:01:00Z",
            status: .running
        )
        let secondRunChunkID = try fixture.writer.createChunk(
            runID: secondRunID,
            sequence: 2000,
            segmentURI: "segment-2000.ts",
            startedAt: "2026-05-01T10:01:01Z",
            endedAt: "2026-05-01T10:01:07Z"
        )

        try fixture.writer.persistTimeline(
            IngestChunkTimeline(
                runID: fixture.runID,
                chunkID: fixture.firstChunkID,
                songPlays: [
                    SongPlayDraft(
                        song: knownSong,
                        startSeconds: 0,
                        endSeconds: 6,
                        confidence: 0.92,
                        source: "chromaprint"
                    )
                ],
                createdAt: "2026-05-01T10:00:06Z"
            )
        )
        try fixture.writer.persistTimeline(
            IngestChunkTimeline(
                runID: secondRunID,
                chunkID: secondRunChunkID,
                songPlays: [
                    SongPlayDraft(
                        song: knownSong,
                        startSeconds: 12,
                        endSeconds: 18,
                        confidence: 0.93,
                        source: "chromaprint"
                    )
                ],
                createdAt: "2026-05-01T10:01:07Z"
            )
        )

        let plays = try fixture.temporary.database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT run_id, first_chunk_id, last_chunk_id, start_seconds, end_seconds, source
                    FROM song_plays
                    ORDER BY start_seconds
                    """
            )
        }

        XCTAssertEqual(plays.count, 2)
        XCTAssertEqual(plays[0]["run_id"] as Int64, fixture.runID)
        XCTAssertEqual(plays[0]["first_chunk_id"] as Int64, fixture.firstChunkID)
        XCTAssertEqual(plays[0]["last_chunk_id"] as Int64, fixture.firstChunkID)
        XCTAssertEqual(plays[1]["run_id"] as Int64, secondRunID)
        XCTAssertEqual(plays[1]["first_chunk_id"] as Int64, secondRunChunkID)
        XCTAssertEqual(plays[1]["last_chunk_id"] as Int64, secondRunChunkID)
        XCTAssertEqual(plays[1]["source"] as String, "chromaprint")
    }

    func testUnidentifiedSongUsesStableUnknownSongRow() throws {
        let fixture = try makeFixture()

        try fixture.writer.persistTimeline(
            IngestChunkTimeline(
                runID: fixture.runID,
                chunkID: fixture.firstChunkID,
                songPlays: [
                    SongPlayDraft(
                        song: .unidentified(),
                        startSeconds: 0,
                        endSeconds: 10
                    )
                ],
                createdAt: "2026-05-01T10:00:03Z"
            )
        )

        let row = try fixture.temporary.database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT songs.song_key, songs.display_name, songs.is_unknown, song_plays.song_id
                FROM song_plays
                JOIN songs ON songs.id = song_plays.song_id
                """)
        }

        XCTAssertEqual(row?["song_key"] as String?, UnresolvedSongDraft.unidentifiedKey)
        XCTAssertEqual(row?["display_name"] as String?, UnresolvedSongDraft.unidentifiedDisplayName)
        XCTAssertEqual(row?["is_unknown"] as Bool?, true)
        XCTAssertNotNil(row?["song_id"] as Int64?)
    }

    func testZeroFingerprintsAndSongEventsIsAllowed() throws {
        let fixture = try makeFixture()

        try fixture.writer.persistTimeline(
            IngestChunkTimeline(
                runID: fixture.runID,
                chunkID: fixture.firstChunkID,
                createdAt: "2026-05-01T10:00:03Z"
            )
        )

        let counts = try fixture.temporary.database.read { db in
            try [
                "audio_fingerprints": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audio_fingerprints"),
                "songs": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM songs"),
                "song_plays": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song_plays")
            ]
        }

        XCTAssertEqual(counts, [
            "audio_fingerprints": 0,
            "songs": 0,
            "song_plays": 0
        ])
    }

    func testMalformedSongTimelineRollsBackWholeChunkTransaction() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(
            try fixture.writer.persistTimeline(
                IngestChunkTimeline(
                    runID: fixture.runID,
                    chunkID: fixture.firstChunkID,
                    segments: [
                        TranscriptSegmentDraft(
                            sequence: 0,
                            startSeconds: 0,
                            endSeconds: 1,
                            text: "segment should roll back"
                        )
                    ],
                    fingerprints: [
                        AudioFingerprintDraft(
                            algorithm: "chromaprint",
                            algorithmVersion: "1.5.1",
                            fingerprint: "",
                            fingerprintHash: "bad-empty-fingerprint",
                            startSeconds: 0,
                            endSeconds: 10
                        )
                    ],
                    songPlays: [SongPlayDraft(song: knownSong, startSeconds: 0, endSeconds: 10)],
                    createdAt: "2026-05-01T10:00:03Z"
                )
            )
        )

        let counts = try fixture.temporary.database.read { db in
            try [
                "segments": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments"),
                "fts": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments_fts"),
                "audio_fingerprints": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audio_fingerprints"),
                "songs": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM songs"),
                "song_plays": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song_plays")
            ]
        }

        XCTAssertEqual(counts, [
            "segments": 0,
            "fts": 0,
            "audio_fingerprints": 0,
            "songs": 0,
            "song_plays": 0
        ])
    }

    func testInvalidSongPlayIntervalRollsBackSongUpsert() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(
            try fixture.writer.persistTimeline(
                IngestChunkTimeline(
                    runID: fixture.runID,
                    chunkID: fixture.firstChunkID,
                    songPlays: [SongPlayDraft(song: knownSong, startSeconds: 20, endSeconds: 10)],
                    createdAt: "2026-05-01T10:00:03Z"
                )
            )
        )

        let counts = try fixture.temporary.database.read { db in
            try [
                "songs": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM songs"),
                "song_plays": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song_plays")
            ]
        }

        XCTAssertEqual(counts, [
            "songs": 0,
            "song_plays": 0
        ])
    }

    private struct Fixture {
        var temporary: TemporarySoundingDatabase
        var writer: IngestPersistence
        var streamID: Int64
        var runID: Int64
        var firstChunkID: Int64
        var secondChunkID: Int64
    }

    private var knownSong: UnresolvedSongDraft {
        UnresolvedSongDraft(
            songKey: "local:artist:station-id",
            title: "Station ID",
            artist: "Sounding Fixtures",
            album: "Integration Proofs",
            isrc: "US-S01-26-00001",
            displayName: "Sounding Fixtures — Station ID"
        )
    }

    private func makeFixture() throws -> Fixture {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)
        let streamID = try writer.createStream(
            streamType: "hls",
            source: "https://example.test/live.m3u8",
            createdAt: "2026-05-01T10:00:00Z"
        )
        let runID = try writer.createRun(
            streamID: streamID,
            startedAt: "2026-05-01T10:00:01Z",
            status: .running
        )
        let firstChunkID = try writer.createChunk(
            runID: runID,
            sequence: 0,
            segmentURI: "segment-000.ts",
            startedAt: "2026-05-01T10:00:02Z",
            endedAt: "2026-05-01T10:00:12Z"
        )
        let secondChunkID = try writer.createChunk(
            runID: runID,
            sequence: 1,
            segmentURI: "segment-001.ts",
            startedAt: "2026-05-01T10:00:12Z",
            endedAt: "2026-05-01T10:00:22Z"
        )
        return Fixture(
            temporary: temporary,
            writer: writer,
            streamID: streamID,
            runID: runID,
            firstChunkID: firstChunkID,
            secondChunkID: secondChunkID
        )
    }
}
