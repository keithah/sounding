import XCTest

@testable import SoundingKit

final class TranscriptExportQueryTests: XCTestCase {
    func testSegmentsReturnTimelineRowsAndWordsInDeterministicOrder() throws {
        let fixture = try makeFixture()
        let results = try fixture.query.segments()

        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(
            results.map { "\($0.identity.streamID):\($0.identity.runID):\($0.identity.sequence)" },
            [
                "\(fixture.mainStreamID):\(fixture.mainRunID):0",
                "\(fixture.mainStreamID):\(fixture.mainRunID):1",
                "\(fixture.mainStreamID):\(fixture.mainRunID):2",
                "\(fixture.otherStreamID):\(fixture.otherRunID):0",
                "\(fixture.otherStreamID):\(fixture.otherRunID):1",
            ]
        )

        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(first.identity.streamType, "hls")
        XCTAssertEqual(
            first.identity.streamSource, "https://example.test/main.m3u8?token=fixture-secret")
        XCTAssertEqual(first.identity.chunkID, fixture.mainChunk0ID)
        XCTAssertEqual(first.identity.speakerLabel, "host")
        XCTAssertEqual(first.startSeconds, 0)
        XCTAssertEqual(first.endSeconds, 10)
        XCTAssertEqual(first.text, "Opening alpha words")
        XCTAssertEqual(first.confidence, 0.9)
        XCTAssertEqual(first.createdAt, "2026-05-01T15:00:03Z")
        XCTAssertEqual(first.words.map(\.text), ["Opening", "alpha", "words"])
        XCTAssertEqual(first.words.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(first.words.map(\.speakerLabel), ["host", "host", "host"])
    }

    func testFiltersByStreamIdNameTypeSourceAndTimeOverlapIncludingRemovedStreams() throws {
        let fixture = try makeFixture()

        XCTAssertEqual(
            try fixture.query.segments(filter: .init(stream: String(fixture.otherStreamID))).map {
                $0.identity.streamID
            },
            [fixture.otherStreamID, fixture.otherStreamID]
        )
        XCTAssertEqual(
            try fixture.query.segments(filter: .init(stream: "Managed Main")).map {
                $0.identity.streamID
            },
            [fixture.mainStreamID, fixture.mainStreamID, fixture.mainStreamID]
        )
        XCTAssertEqual(
            try fixture.query.segments(filter: .init(stream: "icy")).map { $0.identity.streamID },
            [fixture.otherStreamID, fixture.otherStreamID]
        )
        XCTAssertEqual(
            try fixture.query.segments(filter: .init(stream: "https://example.test/other-radio"))
                .map { $0.identity.streamID },
            [fixture.otherStreamID, fixture.otherStreamID]
        )

        let overlapping = try fixture.query.segments(
            filter: .init(stream: "Managed Main", startSeconds: 9.5, endSeconds: 20.5)
        )
        XCTAssertEqual(overlapping.map { $0.identity.sequence }, [0, 1, 2])

        let lateWindow = try fixture.query.segments(
            filter: .init(stream: "Managed Main", startSeconds: 20.1, endSeconds: 29.0)
        )
        XCTAssertEqual(lateWindow.map { $0.identity.sequence }, [2])
    }

    func testEmptyDatabaseAndNoMatchFiltersReturnEmptyResults() throws {
        let temporary = try TemporarySoundingDatabase()
        let query = TranscriptExportQuery(database: temporary.database)

        XCTAssertEqual(try query.segments(), [])
        XCTAssertEqual(try query.segments(filter: .init(stream: "missing-stream")), [])
        XCTAssertEqual(try query.segments(filter: .init(startSeconds: 100, endSeconds: 200)), [])
    }

    func testValidationRejectsMalformedFiltersBeforeSql() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(try fixture.query.segments(filter: .init(stream: "  \t\n"))) { error in
            XCTAssertEqual(error as? SongReportQuery.QueryError, .emptyStreamFilter)
        }
        XCTAssertThrowsError(
            try fixture.query.segments(filter: .init(startSeconds: 30, endSeconds: 20))
        ) { error in
            XCTAssertEqual(error as? SongReportQuery.QueryError, .invalidTimeRange)
        }
        XCTAssertThrowsError(try fixture.query.segments(filter: .init(startSeconds: .infinity))) {
            error in
            XCTAssertEqual(
                error as? SongReportQuery.QueryError, .nonFiniteTimeFilter("startSeconds"))
        }
        XCTAssertThrowsError(try fixture.query.segments(filter: .init(endSeconds: .nan))) { error in
            XCTAssertEqual(error as? SongReportQuery.QueryError, .nonFiniteTimeFilter("endSeconds"))
        }
    }

    func testSegmentsAreCodableEquatableAndStableWithSortedKeys() throws {
        let fixture = try makeFixture()
        let results = try fixture.query.segments(filter: .init(stream: "Managed Main"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(Payload(results: results))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"results\":[{"), text)
        XCTAssertTrue(text.contains("\"createdAt\":\"2026-05-01T15:00:03Z\""), text)
        XCTAssertTrue(
            text.contains(
                "\"streamSource\":\"https:\\/\\/example.test\\/main.m3u8?token=fixture-secret\""),
            text)
        XCTAssertTrue(text.contains("\"words\":[{"), text)

        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        XCTAssertEqual(decoded.results, results)
    }

    private struct Payload: Codable, Equatable {
        var results: [TranscriptExportQuery.SegmentExportRow]
    }

    private struct Fixture {
        var temporary: TemporarySoundingDatabase
        var query: TranscriptExportQuery
        var mainStreamID: Int64
        var mainRunID: Int64
        var mainChunk0ID: Int64
        var otherStreamID: Int64
        var otherRunID: Int64
    }

    private func makeFixture() throws -> Fixture {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let main = try registry.add(
            name: "Managed Main",
            streamType: "hls",
            source: "https://example.test/main.m3u8?token=fixture-secret",
            createdAt: "2026-05-01T15:00:00Z"
        )
        let other = try registry.add(
            name: "Managed Other",
            streamType: "icy",
            source: "https://example.test/other-radio",
            createdAt: "2026-05-01T15:30:00Z"
        )

        let writer = IngestPersistence(database: temporary.database)
        let mainRunID = try writer.createRun(
            streamID: main.id,
            startedAt: "2026-05-01T15:00:01Z",
            status: .running
        )
        let mainChunk0ID = try writer.createChunk(
            runID: mainRunID,
            sequence: 0,
            segmentURI: "main-000.ts",
            startedAt: "2026-05-01T15:00:02Z",
            endedAt: "2026-05-01T15:00:12Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: mainRunID,
                chunkID: mainChunk0ID,
                segments: [
                    segment(0, "host", 0, 10, "Opening alpha words"),
                    segment(1, "guest", 10, 20, "Middle beta words"),
                ],
                speakerTurns: [
                    SpeakerTurnDraft(
                        speakerLabel: "host", startSeconds: 0, endSeconds: 10, confidence: 0.91),
                    SpeakerTurnDraft(
                        speakerLabel: "guest", startSeconds: 10, endSeconds: 20, confidence: 0.88),
                ],
                createdAt: "2026-05-01T15:00:03Z"
            )
        )
        let mainChunk1ID = try writer.createChunk(
            runID: mainRunID,
            sequence: 1,
            segmentURI: "main-001.ts",
            startedAt: "2026-05-01T15:00:12Z",
            endedAt: "2026-05-01T15:00:22Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: mainRunID,
                chunkID: mainChunk1ID,
                segments: [segment(2, "host", 20, 30, "Closing gamma words")],
                speakerTurns: [
                    SpeakerTurnDraft(
                        speakerLabel: "host", startSeconds: 20, endSeconds: 30, confidence: 0.86)
                ],
                createdAt: "2026-05-01T15:00:13Z"
            )
        )

        let otherRunID = try writer.createRun(
            streamID: other.id,
            startedAt: "2026-05-01T15:30:01Z",
            status: .running
        )
        let otherChunkID = try writer.createChunk(
            runID: otherRunID,
            sequence: 0,
            segmentURI: "other-000",
            startedAt: "2026-05-01T15:30:02Z",
            endedAt: "2026-05-01T15:30:12Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: otherRunID,
                chunkID: otherChunkID,
                segments: [
                    segment(0, "dj", 0, 9, "Other station intro"),
                    segment(1, "caller", 9, 18, "Other station call"),
                ],
                speakerTurns: [
                    SpeakerTurnDraft(
                        speakerLabel: "dj", startSeconds: 0, endSeconds: 9, confidence: 0.82),
                    SpeakerTurnDraft(
                        speakerLabel: "caller", startSeconds: 9, endSeconds: 18, confidence: 0.80),
                ],
                createdAt: "2026-05-01T15:30:03Z"
            )
        )

        _ = try registry.remove(id: main.id, removedAt: "2026-05-01T16:00:00Z")

        return Fixture(
            temporary: temporary,
            query: TranscriptExportQuery(database: temporary.database),
            mainStreamID: main.id,
            mainRunID: mainRunID,
            mainChunk0ID: mainChunk0ID,
            otherStreamID: other.id,
            otherRunID: otherRunID
        )
    }

    private func segment(
        _ sequence: Int,
        _ speakerLabel: String,
        _ startSeconds: Double,
        _ endSeconds: Double,
        _ text: String
    ) -> TranscriptSegmentDraft {
        let words = text.split(separator: " ").map(String.init)
        let duration = max((endSeconds - startSeconds) / Double(max(words.count, 1)), 0.1)
        return TranscriptSegmentDraft(
            sequence: sequence,
            speakerLabel: speakerLabel,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            text: text,
            confidence: 0.9,
            words: words.enumerated().map { index, word in
                TranscriptWordDraft(
                    sequence: index,
                    speakerLabel: speakerLabel,
                    startSeconds: startSeconds + (Double(index) * duration),
                    endSeconds: startSeconds + (Double(index + 1) * duration),
                    text: word,
                    confidence: 0.88
                )
            }
        )
    }
}
