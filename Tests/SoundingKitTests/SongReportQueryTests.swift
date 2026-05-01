import Foundation
import GRDB
import XCTest

@testable import SoundingKit
@testable import sounding

final class SongReportQueryTests: XCTestCase {
    func testPlaysReturnMergedSongRowsWithStreamRunChunkIdentityInDeterministicOrder() throws {
        let fixture = try makeFixture()
        let results = try fixture.query.plays()

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(
            results.map { $0.identity.streamID },
            [fixture.hlsStreamID, fixture.hlsStreamID, fixture.icyStreamID])
        XCTAssertEqual(
            results.map { $0.identity.runID },
            [fixture.hlsRunID, fixture.hlsRunID, fixture.icyRunID])
        XCTAssertEqual(results.map(\.startSeconds), [0.0, 21.0, 0.0])

        let merged = results[0]
        XCTAssertEqual(merged.identity.streamType, "hls")
        XCTAssertEqual(
            merged.identity.streamSource, "https://example.test/live.m3u8?token=fixture-secret")
        XCTAssertEqual(merged.identity.firstChunkID, fixture.hlsFirstChunkID)
        XCTAssertEqual(merged.identity.firstChunkSequence, 0)
        XCTAssertEqual(merged.identity.lastChunkID, fixture.hlsSecondChunkID)
        XCTAssertEqual(merged.identity.lastChunkSequence, 1)
        XCTAssertEqual(merged.song.songKey, knownSong.songKey)
        XCTAssertEqual(merged.song.title, "Station ID")
        XCTAssertEqual(merged.song.artist, "Sounding Fixtures")
        XCTAssertEqual(merged.song.album, "Integration Proofs")
        XCTAssertEqual(merged.song.isrc, "US-S01-26-00001")
        XCTAssertFalse(merged.song.isUnknown)
        XCTAssertEqual(merged.startSeconds, 0)
        XCTAssertEqual(merged.endSeconds, 20)
        XCTAssertEqual(merged.durationSeconds, 20)
        XCTAssertEqual(merged.confidence, 0.91)
        XCTAssertEqual(merged.source, "local_fingerprint")

        let unknown = results[1]
        XCTAssertEqual(unknown.song.songKey, UnresolvedSongDraft.unidentifiedKey)
        XCTAssertEqual(unknown.song.displayName, UnresolvedSongDraft.unidentifiedDisplayName)
        XCTAssertTrue(unknown.song.isUnknown)
        XCTAssertEqual(unknown.identity.firstChunkID, fixture.hlsThirdChunkID)
        XCTAssertEqual(unknown.identity.lastChunkID, fixture.hlsThirdChunkID)
        XCTAssertEqual(unknown.startSeconds, 21)
        XCTAssertEqual(unknown.endSeconds, 30)
        XCTAssertEqual(unknown.durationSeconds, 9)

        let sameStartDifferentStream = results[2]
        XCTAssertEqual(sameStartDifferentStream.identity.streamType, "icy")
        XCTAssertEqual(sameStartDifferentStream.identity.streamSource, "https://example.test/radio")
        XCTAssertEqual(sameStartDifferentStream.song.songKey, otherSong.songKey)
        XCTAssertEqual(sameStartDifferentStream.startSeconds, 0)
    }

    func testFiltersByStreamIdTypeSourceAndTimeOverlap() throws {
        let fixture = try makeFixture()

        XCTAssertEqual(
            try fixture.query.plays(filter: .init(stream: String(fixture.icyStreamID))).map {
                $0.identity.streamID
            },
            [fixture.icyStreamID]
        )
        XCTAssertEqual(
            try fixture.query.plays(filter: .init(stream: "icy")).map { $0.identity.streamID },
            [fixture.icyStreamID]
        )
        XCTAssertEqual(
            try fixture.query.plays(filter: .init(stream: "https://example.test/radio")).map {
                $0.identity.streamID
            },
            [fixture.icyStreamID]
        )

        let hlsOverlappingLateWindow = try fixture.query.plays(
            filter: .init(stream: "hls", startSeconds: 19.5, endSeconds: 22.0)
        )
        XCTAssertEqual(hlsOverlappingLateWindow.count, 2)
        XCTAssertEqual(
            hlsOverlappingLateWindow.map(\.identity.playID),
            [fixture.knownPlayID, fixture.unknownPlayID])
    }

    func testEmptyDatabaseAndNoMatchReturnEmptyResults() throws {
        let temporary = try TemporarySoundingDatabase()
        let query = SongReportQuery(database: temporary.database)

        XCTAssertEqual(try query.plays(), [])
        XCTAssertEqual(try query.plays(filter: .init(stream: "missing-stream")), [])
    }

    func testJSONCodabilityAndSortedKeysAreStableForQueryPayload() throws {
        let fixture = try makeFixture()
        let results = try fixture.query.plays(filter: .init(stream: "hls"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(Payload(results: results))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"results\":[{"), text)
        XCTAssertTrue(text.contains("\"firstChunkID\":\(fixture.hlsFirstChunkID)"), text)
        XCTAssertTrue(text.contains("\"isUnknown\":true"), text)
        XCTAssertTrue(text.contains("\"songKey\":\"unknown:unidentified\""), text)

        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        XCTAssertEqual(decoded.results, results)
    }

    func testReportOutputFormatsHumanAndJsonWithRedactedSourcesAndExplicitUnknowns() throws {
        let fixture = try makeFixture()
        let results = try fixture.query.plays(filter: .init(stream: "hls"))

        let human = ReportOutput.formatPlaysHuman(results)
        XCTAssertTrue(human.contains("Play 1:"), human)
        XCTAssertTrue(human.contains("stream=\(fixture.hlsStreamID)(hls source="), human)
        XCTAssertTrue(human.contains("run=\(fixture.hlsRunID)"), human)
        XCTAssertTrue(
            human.contains(
                "chunks=\(fixture.hlsFirstChunkID)(seq=0)-\(fixture.hlsSecondChunkID)(seq=1)"),
            human)
        XCTAssertTrue(human.contains("time=00:00.000-00:20.000"), human)
        XCTAssertTrue(human.contains("duration=00:20.000"), human)
        XCTAssertTrue(human.contains("song=Sounding Fixtures — Station ID"), human)
        XCTAssertTrue(human.contains("song=unknown(Unknown song)"), human)
        XCTAssertTrue(human.contains("unknown=true"), human)
        XCTAssertFalse(human.contains("fixture-secret"), human)
        XCTAssertFalse(human.contains("token="), human)

        let json = try ReportOutput.encodePlaysJSON(results)
        XCTAssertTrue(json.hasPrefix("{\"results\":[{"), json)
        XCTAssertTrue(json.contains("\"displayLabel\":\"unknown(Unknown song)\""), json)
        XCTAssertTrue(json.contains("\"streamSource\":"), json)
        XCTAssertFalse(json.contains("fixture-secret"), json)
        XCTAssertFalse(json.contains("token="), json)
        _ = try JSONDecoder().decode(ReportOutput.PlaysPayload.self, from: Data(json.utf8))
    }

    func testReportOutputEmptyResultAndNonFiniteTimeHandling() throws {
        XCTAssertEqual(ReportOutput.formatPlaysHuman([]), "No song plays found.\n")
        let fixture = try makeFixture()
        var result = try XCTUnwrap(try fixture.query.plays().first)
        result.startSeconds = .nan

        XCTAssertThrowsError(try ReportOutput.encodePlaysJSON([result])) { error in
            XCTAssertEqual(error as? ReportOutput.OutputError, .invalidTime("startSeconds"))
        }
    }

    func testValidationRejectsMalformedFiltersBeforeSql() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(try fixture.query.plays(filter: .init(stream: "  \t\n"))) { error in
            XCTAssertEqual(error as? SongReportQuery.QueryError, .emptyStreamFilter)
        }
        XCTAssertThrowsError(
            try fixture.query.plays(filter: .init(startSeconds: 30, endSeconds: 20))
        ) { error in
            XCTAssertEqual(error as? SongReportQuery.QueryError, .invalidTimeRange)
        }
        XCTAssertThrowsError(try fixture.query.plays(filter: .init(startSeconds: .infinity))) {
            error in
            XCTAssertEqual(
                error as? SongReportQuery.QueryError, .nonFiniteTimeFilter("startSeconds"))
        }
        XCTAssertThrowsError(try fixture.query.plays(filter: .init(endSeconds: .nan))) { error in
            XCTAssertEqual(error as? SongReportQuery.QueryError, .nonFiniteTimeFilter("endSeconds"))
        }
    }

    func testSongTimelineIndexesNeededByReportQueryExist() throws {
        let fixture = try makeFixture()
        let indexes = try fixture.temporary.database.read { db in
            try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name")
        }

        XCTAssertTrue(
            indexes.contains("song_plays_on_stream_run_time"), indexes.joined(separator: ","))
        XCTAssertTrue(indexes.contains("song_plays_on_run_time"), indexes.joined(separator: ","))
        XCTAssertTrue(indexes.contains("song_plays_on_song_id"), indexes.joined(separator: ","))
    }

    private struct Payload: Codable, Equatable {
        var results: [SongReportQuery.PlayResult]
    }

    private struct Fixture {
        var temporary: TemporarySoundingDatabase
        var query: SongReportQuery
        var hlsStreamID: Int64
        var hlsRunID: Int64
        var hlsFirstChunkID: Int64
        var hlsSecondChunkID: Int64
        var hlsThirdChunkID: Int64
        var icyStreamID: Int64
        var icyRunID: Int64
        var knownPlayID: Int64
        var unknownPlayID: Int64
    }

    private func makeFixture() throws -> Fixture {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)

        let hlsStreamID = try writer.createStream(
            streamType: "hls",
            source: "https://example.test/live.m3u8?token=fixture-secret",
            createdAt: "2026-05-01T10:00:00Z"
        )
        let hlsRunID = try writer.createRun(
            streamID: hlsStreamID,
            startedAt: "2026-05-01T10:00:01Z",
            status: .running
        )
        let hlsFirstChunkID = try writer.createChunk(
            runID: hlsRunID,
            sequence: 0,
            segmentURI: "segment-000.ts",
            startedAt: "2026-05-01T10:00:02Z",
            endedAt: "2026-05-01T10:00:12Z"
        )
        let hlsSecondChunkID = try writer.createChunk(
            runID: hlsRunID,
            sequence: 1,
            segmentURI: "segment-001.ts",
            startedAt: "2026-05-01T10:00:12Z",
            endedAt: "2026-05-01T10:00:22Z"
        )
        let hlsThirdChunkID = try writer.createChunk(
            runID: hlsRunID,
            sequence: 2,
            segmentURI: "segment-002.ts",
            startedAt: "2026-05-01T10:00:22Z",
            endedAt: "2026-05-01T10:00:32Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: hlsRunID,
                chunkID: hlsFirstChunkID,
                songPlays: [
                    SongPlayDraft(
                        song: knownSong,
                        startSeconds: 0,
                        endSeconds: 10,
                        confidence: 0.90,
                        source: "local_fingerprint"
                    )
                ],
                createdAt: "2026-05-01T10:00:03Z"
            )
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: hlsRunID,
                chunkID: hlsSecondChunkID,
                songPlays: [
                    SongPlayDraft(
                        song: knownSong,
                        startSeconds: 10,
                        endSeconds: 20,
                        confidence: 0.91,
                        source: "local_fingerprint"
                    )
                ],
                createdAt: "2026-05-01T10:00:13Z"
            )
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: hlsRunID,
                chunkID: hlsThirdChunkID,
                songPlays: [
                    SongPlayDraft(
                        song: .unidentified(),
                        startSeconds: 21,
                        endSeconds: 30,
                        confidence: nil,
                        source: nil
                    )
                ],
                createdAt: "2026-05-01T10:00:23Z"
            )
        )

        let icyStreamID = try writer.createStream(
            streamType: "icy",
            source: "https://example.test/radio",
            createdAt: "2026-05-01T11:00:00Z"
        )
        let icyRunID = try writer.createRun(
            streamID: icyStreamID,
            startedAt: "2026-05-01T11:00:01Z",
            status: .running
        )
        let icyChunkID = try writer.createChunk(
            runID: icyRunID,
            sequence: 0,
            segmentURI: "icy-000",
            startedAt: "2026-05-01T11:00:02Z",
            endedAt: "2026-05-01T11:00:12Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: icyRunID,
                chunkID: icyChunkID,
                songPlays: [
                    SongPlayDraft(
                        song: otherSong,
                        startSeconds: 0,
                        endSeconds: 9,
                        confidence: 0.85,
                        source: "local_fingerprint"
                    )
                ],
                createdAt: "2026-05-01T11:00:03Z"
            )
        )

        let playIDs = try temporary.database.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT id, song_id FROM song_plays ORDER BY stream_id, run_id, start_seconds, id"
            )
        }
        let knownPlayID = try XCTUnwrap(playIDs.first?["id"] as Int64?)
        let unknownPlayID = try XCTUnwrap(playIDs.dropFirst().first?["id"] as Int64?)

        return Fixture(
            temporary: temporary,
            query: SongReportQuery(database: temporary.database),
            hlsStreamID: hlsStreamID,
            hlsRunID: hlsRunID,
            hlsFirstChunkID: hlsFirstChunkID,
            hlsSecondChunkID: hlsSecondChunkID,
            hlsThirdChunkID: hlsThirdChunkID,
            icyStreamID: icyStreamID,
            icyRunID: icyRunID,
            knownPlayID: knownPlayID,
            unknownPlayID: unknownPlayID
        )
    }
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

private var otherSong: UnresolvedSongDraft {
    UnresolvedSongDraft(
        songKey: "local:artist:overnight-theme",
        title: "Overnight Theme",
        artist: "Second Fixture",
        album: nil,
        isrc: nil,
        displayName: "Second Fixture — Overnight Theme"
    )
}
