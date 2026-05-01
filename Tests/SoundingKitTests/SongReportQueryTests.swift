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

    func testRepeatsGroupKnownSongsByNormalizedArtistTitleAndExcludeUnknowns() throws {
        let fixture = try makeRepeatFixture()
        let repeats = try fixture.query.repeats()

        XCTAssertEqual(
            repeats.map(\.groupKey),
            ["artist-title:repeat artist:echo song", "artist-title:second artist:tie song"])

        let echo = try XCTUnwrap(repeats.first)
        XCTAssertEqual(echo.repeatCount, 3)
        XCTAssertEqual(echo.totalDurationSeconds, 30)
        XCTAssertEqual(echo.firstStartSeconds, 0)
        XCTAssertEqual(echo.lastEndSeconds, 30)
        XCTAssertEqual(echo.song.displayName, "Repeat Artist — Echo Song")
        XCTAssertEqual(echo.plays.map(\.song.isUnknown), [false, false, false])
        XCTAssertEqual(echo.plays.map(\.startSeconds), [0, 20, 0])
        XCTAssertFalse(
            echo.plays.contains { $0.song.songKey == UnresolvedSongDraft.unidentifiedKey })
    }

    func testRepeatsInheritStreamAndTimeOverlapFiltersFromPlays() throws {
        let fixture = try makeRepeatFixture()

        let hlsRepeats = try fixture.query.repeats(filter: .init(stream: "hls"))
        XCTAssertEqual(hlsRepeats.map(\.groupKey), ["artist-title:repeat artist:echo song"])
        XCTAssertEqual(hlsRepeats.first?.repeatCount, 2)
        XCTAssertEqual(
            hlsRepeats.first?.plays.map(\.identity.streamID),
            [fixture.hlsStreamID, fixture.hlsStreamID])

        let overlappingWindow = try fixture.query.repeats(
            filter: .init(stream: "hls", startSeconds: 9.5, endSeconds: 20.5)
        )
        XCTAssertEqual(overlappingWindow.map(\.groupKey), ["artist-title:repeat artist:echo song"])
        XCTAssertEqual(overlappingWindow.first?.plays.map(\.startSeconds), [0, 20])
    }

    func testRepeatsAreCodableEquatableAndStableWithSortedKeys() throws {
        let fixture = try makeRepeatFixture()
        let repeats = try fixture.query.repeats()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(RepeatPayload(results: repeats))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"results\":[{"), text)
        XCTAssertTrue(text.contains("\"groupKey\":\"artist-title:repeat artist:echo song\""), text)
        XCTAssertTrue(text.contains("\"repeatCount\":3"), text)
        XCTAssertFalse(text.contains(UnresolvedSongDraft.unidentifiedKey), text)

        let decoded = try JSONDecoder().decode(RepeatPayload.self, from: data)
        XCTAssertEqual(decoded.results, repeats)
    }

    func testRepeatsReturnEmptyForEmptyDatabaseNoMatchesUnknownOnlyAndSingleKnownPlays() throws {
        let temporary = try TemporarySoundingDatabase()
        XCTAssertEqual(try SongReportQuery(database: temporary.database).repeats(), [])

        let fixture = try makeFixture()
        XCTAssertEqual(try fixture.query.repeats(), [])
        XCTAssertEqual(try fixture.query.repeats(filter: .init(stream: "missing-stream")), [])

        let unknownFixture = try makeUnknownOnlyRepeatFixture()
        XCTAssertEqual(try unknownFixture.query.repeats(), [])
    }

    func testRepeatValidationRejectsMalformedFiltersBeforeSql() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(try fixture.query.repeats(filter: .init(stream: "  \t\n"))) { error in
            XCTAssertEqual(error as? SongReportQuery.QueryError, .emptyStreamFilter)
        }
        XCTAssertThrowsError(
            try fixture.query.repeats(filter: .init(startSeconds: 30, endSeconds: 20))
        ) { error in
            XCTAssertEqual(error as? SongReportQuery.QueryError, .invalidTimeRange)
        }
        XCTAssertThrowsError(try fixture.query.repeats(filter: .init(startSeconds: .infinity))) {
            error in
            XCTAssertEqual(
                error as? SongReportQuery.QueryError, .nonFiniteTimeFilter("startSeconds"))
        }
        XCTAssertThrowsError(try fixture.query.repeats(filter: .init(endSeconds: .nan))) { error in
            XCTAssertEqual(error as? SongReportQuery.QueryError, .nonFiniteTimeFilter("endSeconds"))
        }
    }

    private struct Payload: Codable, Equatable {
        var results: [SongReportQuery.PlayResult]
    }

    private struct RepeatPayload: Codable, Equatable {
        var results: [SongReportQuery.RepeatResult]
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

    private struct RepeatFixture {
        var temporary: TemporarySoundingDatabase
        var query: SongReportQuery
        var hlsStreamID: Int64
        var icyStreamID: Int64
    }

    private func makeRepeatFixture() throws -> RepeatFixture {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)

        let hlsStreamID = try writer.createStream(
            streamType: "hls",
            source: "https://example.test/repeats.m3u8?token=fixture-secret",
            createdAt: "2026-05-01T12:00:00Z"
        )
        let hlsRunID = try writer.createRun(
            streamID: hlsStreamID,
            startedAt: "2026-05-01T12:00:01Z",
            status: .running
        )
        let hlsChunk0 = try writer.createChunk(
            runID: hlsRunID,
            sequence: 0,
            segmentURI: "repeat-000.ts",
            startedAt: "2026-05-01T12:00:02Z",
            endedAt: "2026-05-01T12:00:12Z"
        )
        let hlsChunk1 = try writer.createChunk(
            runID: hlsRunID,
            sequence: 1,
            segmentURI: "repeat-001.ts",
            startedAt: "2026-05-01T12:00:12Z",
            endedAt: "2026-05-01T12:00:22Z"
        )
        let hlsChunk2 = try writer.createChunk(
            runID: hlsRunID,
            sequence: 2,
            segmentURI: "repeat-002.ts",
            startedAt: "2026-05-01T12:00:22Z",
            endedAt: "2026-05-01T12:00:32Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: hlsRunID,
                chunkID: hlsChunk0,
                songPlays: [
                    SongPlayDraft(
                        song: repeatSong,
                        startSeconds: 0,
                        endSeconds: 10,
                        confidence: 0.90,
                        source: "local_fingerprint"
                    )
                ],
                createdAt: "2026-05-01T12:00:03Z"
            )
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: hlsRunID,
                chunkID: hlsChunk1,
                songPlays: [
                    SongPlayDraft(
                        song: .unidentified(),
                        startSeconds: 11,
                        endSeconds: 12,
                        confidence: nil,
                        source: nil
                    )
                ],
                createdAt: "2026-05-01T12:00:13Z"
            )
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: hlsRunID,
                chunkID: hlsChunk2,
                songPlays: [
                    SongPlayDraft(
                        song: repeatSong,
                        startSeconds: 20,
                        endSeconds: 30,
                        confidence: 0.88,
                        source: "local_fingerprint"
                    )
                ],
                createdAt: "2026-05-01T12:00:23Z"
            )
        )

        let icyStreamID = try writer.createStream(
            streamType: "icy",
            source: "https://example.test/repeats-radio",
            createdAt: "2026-05-01T13:00:00Z"
        )
        let icyRunID = try writer.createRun(
            streamID: icyStreamID,
            startedAt: "2026-05-01T13:00:01Z",
            status: .running
        )
        let icyChunk0 = try writer.createChunk(
            runID: icyRunID,
            sequence: 0,
            segmentURI: "icy-repeat-000",
            startedAt: "2026-05-01T13:00:02Z",
            endedAt: "2026-05-01T13:00:12Z"
        )
        let icyChunk1 = try writer.createChunk(
            runID: icyRunID,
            sequence: 1,
            segmentURI: "icy-repeat-001",
            startedAt: "2026-05-01T13:00:12Z",
            endedAt: "2026-05-01T13:00:22Z"
        )
        let icyChunk2 = try writer.createChunk(
            runID: icyRunID,
            sequence: 3,
            segmentURI: "icy-repeat-002",
            startedAt: "2026-05-01T13:00:22Z",
            endedAt: "2026-05-01T13:00:32Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: icyRunID,
                chunkID: icyChunk0,
                songPlays: [
                    SongPlayDraft(
                        song: repeatSongAlternateKey,
                        startSeconds: 0,
                        endSeconds: 10,
                        confidence: 0.87,
                        source: "remote_enrichment"
                    )
                ],
                createdAt: "2026-05-01T13:00:03Z"
            )
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: icyRunID,
                chunkID: icyChunk1,
                songPlays: [
                    SongPlayDraft(
                        song: tieSong,
                        startSeconds: 40,
                        endSeconds: 50,
                        confidence: 0.80,
                        source: "local_fingerprint"
                    )
                ],
                createdAt: "2026-05-01T13:00:13Z"
            )
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: icyRunID,
                chunkID: icyChunk2,
                songPlays: [
                    SongPlayDraft(
                        song: tieSong,
                        startSeconds: 60,
                        endSeconds: 70,
                        confidence: 0.81,
                        source: "local_fingerprint"
                    )
                ],
                createdAt: "2026-05-01T13:00:23Z"
            )
        )

        return RepeatFixture(
            temporary: temporary,
            query: SongReportQuery(database: temporary.database),
            hlsStreamID: hlsStreamID,
            icyStreamID: icyStreamID
        )
    }

    private func makeUnknownOnlyRepeatFixture() throws -> RepeatFixture {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)
        let streamID = try writer.createStream(
            streamType: "hls",
            source: "https://example.test/unknowns.m3u8",
            createdAt: "2026-05-01T14:00:00Z"
        )
        let runID = try writer.createRun(
            streamID: streamID,
            startedAt: "2026-05-01T14:00:01Z",
            status: .running
        )

        for sequence in 0..<2 {
            let chunkID = try writer.createChunk(
                runID: runID,
                sequence: sequence * 2,
                segmentURI: "unknown-\(sequence).ts",
                startedAt: "2026-05-01T14:00:0\(sequence + 2)Z",
                endedAt: "2026-05-01T14:00:1\(sequence + 2)Z"
            )
            try writer.persistTimeline(
                IngestChunkTimeline(
                    runID: runID,
                    chunkID: chunkID,
                    songPlays: [
                        SongPlayDraft(
                            song: .unidentified(),
                            startSeconds: Double(sequence * 20),
                            endSeconds: Double(sequence * 20 + 10),
                            confidence: nil,
                            source: nil
                        )
                    ],
                    createdAt: "2026-05-01T14:00:0\(sequence + 3)Z"
                )
            )
        }

        return RepeatFixture(
            temporary: temporary,
            query: SongReportQuery(database: temporary.database),
            hlsStreamID: streamID,
            icyStreamID: streamID
        )
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

private var repeatSong: UnresolvedSongDraft {
    UnresolvedSongDraft(
        songKey: "local:repeat-artist:echo-song",
        title: "Echo Song",
        artist: "Repeat Artist",
        album: "Repeat Proofs",
        isrc: "US-S03-26-00001",
        displayName: "Repeat Artist — Echo Song"
    )
}

private var repeatSongAlternateKey: UnresolvedSongDraft {
    UnresolvedSongDraft(
        songKey: "acoustid:alternate-echo-song",
        title: "  echo   song  ",
        artist: "Répeat Artist",
        album: "Alternate Metadata",
        isrc: nil,
        displayName: "Répeat Artist — echo song"
    )
}

private var tieSong: UnresolvedSongDraft {
    UnresolvedSongDraft(
        songKey: "local:second-artist:tie-song",
        title: "Tie Song",
        artist: "Second Artist",
        album: nil,
        isrc: nil,
        displayName: "Second Artist — Tie Song"
    )
}
