import Foundation
import GRDB
import XCTest

@testable import SoundingKit

final class ReportQueryTests: XCTestCase {
    func testAdsReturnEventsAndClassificationSummaryInDeterministicOrder() throws {
        let fixture = try makeAdFixture()
        let result = try fixture.query.events()

        XCTAssertEqual(result.summary, .init(unknown: 1, adStart: 2, adEnd: 1))
        XCTAssertEqual(result.events.count, 4)
        XCTAssertEqual(
            result.events.map { $0.identity.streamID },
            [fixture.hlsStreamID, fixture.hlsStreamID, fixture.hlsStreamID, fixture.icyStreamID]
        )
        XCTAssertEqual(result.events.map(\.classification), [.unknown, .adStart, .adEnd, .adStart])
        XCTAssertEqual(result.events.map(\.pts), [nil, 10, 20, 5])
        XCTAssertEqual(result.events.map { $0.identity.chunkSequence }, [1, 0, 2, 0])

        let nullPTS = result.events[0]
        XCTAssertEqual(nullPTS.identity.runID, fixture.hlsRunID)
        XCTAssertEqual(nullPTS.identity.chunkID, fixture.hlsSecondChunkID)
        XCTAssertEqual(nullPTS.markerType, "EXT-X-DATERANGE")
        XCTAssertEqual(nullPTS.source, "https://ads.example.test/null?token=fixture-secret")
        XCTAssertEqual(nullPTS.segment, "/private/ad-segment-null.ts?password=fixture-secret")
        XCTAssertEqual(nullPTS.observedAt, "2026-05-01T10:00:04Z")
    }

    func testStreamAndTimeFiltersUseStreamIdentityAndEventPTSOnly() throws {
        let fixture = try makeAdFixture()

        XCTAssertEqual(
            try fixture.query.events(filter: .init(stream: String(fixture.icyStreamID))).events.map
            {
                $0.identity.streamID
            },
            [fixture.icyStreamID]
        )
        XCTAssertEqual(
            try fixture.query.events(filter: .init(stream: "icy")).events.map {
                $0.identity.streamID
            },
            [fixture.icyStreamID]
        )
        XCTAssertEqual(
            try fixture.query.events(filter: .init(stream: "https://example.test/radio")).events.map
            {
                $0.identity.streamID
            },
            [fixture.icyStreamID]
        )

        let hlsWindow = try fixture.query.events(
            filter: .init(stream: "hls", startSeconds: 0, endSeconds: 15)
        )
        XCTAssertEqual(hlsWindow.events.map(\.classification), [.adStart])
        XCTAssertEqual(hlsWindow.events.map(\.pts), [10])

        let allStreamsWindow = try fixture.query.events(
            filter: .init(startSeconds: 0, endSeconds: 15))
        XCTAssertEqual(allStreamsWindow.events.map(\.classification), [.adStart, .adStart])
        XCTAssertEqual(allStreamsWindow.events.map(\.pts), [10, 5])
    }

    func testNullPTSIsIncludedWithoutTimeFilterAndExcludedWithEitherTimeFilter() throws {
        let fixture = try makeAdFixture()

        XCTAssertTrue(try fixture.query.events().events.contains { $0.pts == nil })
        XCTAssertFalse(
            try fixture.query.events(filter: .init(startSeconds: 0)).events.contains {
                $0.pts == nil
            }
        )
        XCTAssertFalse(
            try fixture.query.events(filter: .init(endSeconds: 100)).events.contains {
                $0.pts == nil
            }
        )
    }

    func testAdResultsAreCodableEquatableAndStableWithSortedKeys() throws {
        let fixture = try makeAdFixture()
        let result = try fixture.query.events(filter: .init(stream: "hls"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(result)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"events\":[{"), text)
        XCTAssertTrue(text.contains("\"summary\":{\"adEnd\":1,\"adStart\":1,\"unknown\":1}"), text)
        XCTAssertTrue(text.contains("\"classification\":\"UNKNOWN\""), text)
        XCTAssertTrue(text.contains("fixture-secret"), text)

        let decoded = try JSONDecoder().decode(AdReportQuery.Result.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testEmptyDatabaseAndNoMatchesReturnEmptyReportWithZeroSummary() throws {
        let temporary = try TemporarySoundingDatabase()
        let query = AdReportQuery(database: temporary.database)

        XCTAssertEqual(try query.events(), .init(events: [], summary: .init()))
        XCTAssertEqual(
            try query.events(filter: .init(stream: "missing-stream")),
            .init(events: [], summary: .init())
        )
    }

    func testValidationRejectsMalformedFiltersBeforeSql() throws {
        let fixture = try makeAdFixture()

        XCTAssertThrowsError(try fixture.query.events(filter: .init(stream: "  \t\n"))) { error in
            XCTAssertEqual(error as? AdReportQuery.QueryError, .emptyStreamFilter)
        }
        XCTAssertThrowsError(
            try fixture.query.events(filter: .init(startSeconds: 30, endSeconds: 20))
        ) { error in
            XCTAssertEqual(error as? AdReportQuery.QueryError, .invalidTimeRange)
        }
        XCTAssertThrowsError(try fixture.query.events(filter: .init(startSeconds: .infinity))) {
            error in
            XCTAssertEqual(error as? AdReportQuery.QueryError, .nonFiniteTimeFilter("startSeconds"))
        }
        XCTAssertThrowsError(try fixture.query.events(filter: .init(endSeconds: .nan))) { error in
            XCTAssertEqual(error as? AdReportQuery.QueryError, .nonFiniteTimeFilter("endSeconds"))
        }
    }

    func testMalformedClassificationProducesFieldSpecificError() throws {
        let fixture = try makeAdFixture()
        try fixture.temporary.database.write { db in
            try db.execute(
                sql: "UPDATE ad_events SET classification = 'BROKEN' WHERE id = ?",
                arguments: [fixture.hlsStartEventID])
        }

        XCTAssertThrowsError(try fixture.query.events()) { error in
            XCTAssertEqual(error as? AdReportQuery.QueryError, .malformedRow("classification"))
        }
    }

    func testDatabaseReadFailuresMapToQueryErrorCategory() throws {
        let fixture = try makeAdFixture()
        try fixture.temporary.database.write { db in
            try db.execute(sql: "DROP TABLE ad_events")
        }

        XCTAssertThrowsError(try fixture.query.events()) { error in
            XCTAssertEqual(error as? AdReportQuery.QueryError, .databaseReadFailed)
        }
    }

    private struct Fixture {
        var temporary: TemporarySoundingDatabase
        var query: AdReportQuery
        var hlsStreamID: Int64
        var hlsRunID: Int64
        var hlsFirstChunkID: Int64
        var hlsSecondChunkID: Int64
        var hlsStartEventID: Int64
        var icyStreamID: Int64
    }

    private func makeAdFixture() throws -> Fixture {
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
                adMarkers: [
                    AdMarker(
                        type: "EXT-X-CUE-OUT",
                        classification: .adStart,
                        source: "https://ads.example.test/start?token=fixture-secret",
                        pts: 10,
                        segment: "/private/ad-segment-start.ts?password=fixture-secret",
                        timestamp: "2026-05-01T10:00:05Z"
                    )
                ],
                createdAt: "2026-05-01T10:00:03Z"
            )
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: hlsRunID,
                chunkID: hlsSecondChunkID,
                adMarkers: [
                    AdMarker(
                        type: "EXT-X-DATERANGE",
                        classification: .unknown,
                        source: "https://ads.example.test/null?token=fixture-secret",
                        pts: nil,
                        segment: "/private/ad-segment-null.ts?password=fixture-secret",
                        timestamp: "2026-05-01T10:00:04Z"
                    )
                ],
                createdAt: "2026-05-01T10:00:13Z"
            )
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: hlsRunID,
                chunkID: hlsThirdChunkID,
                adMarkers: [
                    AdMarker(
                        type: "EXT-X-CUE-IN",
                        classification: .adEnd,
                        source: "manifest",
                        pts: 20,
                        segment: "segment-002.ts",
                        timestamp: "2026-05-01T10:00:20Z"
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
                adMarkers: [
                    AdMarker(
                        type: "StreamTitle",
                        classification: .adStart,
                        source: "icy-metadata",
                        pts: 5,
                        segment: nil,
                        timestamp: "2026-05-01T11:00:05Z"
                    )
                ],
                createdAt: "2026-05-01T11:00:03Z"
            )
        )

        let hlsStartEventID = try temporary.database.read { db in
            try Int64.fetchOne(
                db,
                sql:
                    "SELECT id FROM ad_events WHERE source = 'https://ads.example.test/start?token=fixture-secret'"
            )
        }

        return Fixture(
            temporary: temporary,
            query: AdReportQuery(database: temporary.database),
            hlsStreamID: hlsStreamID,
            hlsRunID: hlsRunID,
            hlsFirstChunkID: hlsFirstChunkID,
            hlsSecondChunkID: hlsSecondChunkID,
            hlsStartEventID: try XCTUnwrap(hlsStartEventID),
            icyStreamID: icyStreamID
        )
    }
}
