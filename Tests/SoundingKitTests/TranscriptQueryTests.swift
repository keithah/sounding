import XCTest

@testable import SoundingKit

final class TranscriptQueryTests: XCTestCase {
    func testSearchReturnsStreamAwareSegmentContextAndWordsInOrder() throws {
        let fixture = try makeFixture()
        let results = try fixture.query.search(phrase: "alpha beta", limit: 10, contextSegments: 1)

        XCTAssertEqual(results.count, 2)
        let first = try XCTUnwrap(results.first { $0.identity.streamType == "hls" })
        XCTAssertEqual(first.identity.streamID, fixture.hlsStreamID)
        XCTAssertEqual(first.identity.runID, fixture.hlsRunID)
        XCTAssertEqual(first.identity.chunkID, fixture.hlsChunkID)
        XCTAssertEqual(first.identity.speakerLabel, "host")
        XCTAssertEqual(first.identity.sequence, 1)
        XCTAssertEqual(first.startSeconds, 1.0)
        XCTAssertEqual(first.endSeconds, 2.0)
        XCTAssertEqual(first.text, "Alpha beta alpha beta.")
        XCTAssertEqual(first.occurrenceCount, 2)
        XCTAssertEqual(first.words.map(\.text), ["Alpha", "beta", "alpha", "beta"])
        XCTAssertEqual(first.words.map(\.sequence), [0, 1, 2, 3])
        XCTAssertEqual(first.context.map(\.role), [.before, .match, .after])
        XCTAssertEqual(first.context.map { $0.identity.sequence }, [0, 1, 2])
        XCTAssertEqual(first.context.first?.identity.streamSource, "https://example.test/live.m3u8")

        let second = try XCTUnwrap(results.first { $0.identity.streamType == "icy" })
        XCTAssertEqual(second.identity.streamID, fixture.icyStreamID)
        XCTAssertEqual(second.identity.runID, fixture.icyRunID)
        XCTAssertEqual(second.identity.speakerLabel, "caller")
        XCTAssertEqual(second.context.map(\.role), [.before, .match])
        XCTAssertEqual(second.words.map(\.text), ["callers", "say", "ALPHA", "BETA"])
    }

    func testCountGroupsByStreamRunAndSpeakerWithExactOccurrencesAndMatchingSegments() throws {
        let fixture = try makeFixture()
        let counts = try fixture.query.count(phrase: "alpha beta")

        XCTAssertEqual(counts.count, 2)
        let hls = try XCTUnwrap(counts.first { $0.streamID == fixture.hlsStreamID })
        XCTAssertEqual(hls.streamType, "hls")
        XCTAssertEqual(hls.streamSource, "https://example.test/live.m3u8")
        XCTAssertEqual(hls.runID, fixture.hlsRunID)
        XCTAssertEqual(hls.speakerLabel, "host")
        XCTAssertEqual(hls.occurrenceCount, 2)
        XCTAssertEqual(hls.matchingSegmentCount, 1)

        let icy = try XCTUnwrap(counts.first { $0.streamID == fixture.icyStreamID })
        XCTAssertEqual(icy.streamType, "icy")
        XCTAssertEqual(icy.streamSource, "https://example.test/radio")
        XCTAssertEqual(icy.runID, fixture.icyRunID)
        XCTAssertEqual(icy.speakerLabel, "caller")
        XCTAssertEqual(icy.occurrenceCount, 1)
        XCTAssertEqual(icy.matchingSegmentCount, 1)
    }

    func testSearchOptionsPreserveDefaultResultsAndFilterByStreamSpeakerAndRunDate() throws {
        let fixture = try makeFixture()

        let defaultResults = try fixture.query.search(
            phrase: "alpha beta", limit: 10, contextSegments: 1)
        let optionsResults = try fixture.query.search(
            phrase: "alpha beta",
            options: TranscriptQuery.SearchOptions(limit: 10, contextSegments: 1)
        )
        XCTAssertEqual(optionsResults, defaultResults)

        let hlsOnly = try fixture.query.search(
            phrase: "alpha beta",
            options: TranscriptQuery.SearchOptions(limit: 10, streamIDs: [fixture.hlsStreamID])
        )
        XCTAssertEqual(hlsOnly.map(\.identity.streamID), [fixture.hlsStreamID])

        let callerOnly = try fixture.query.search(
            phrase: "alpha beta",
            options: TranscriptQuery.SearchOptions(limit: 10, speakerLabels: [" caller "])
        )
        XCTAssertEqual(callerOnly.map(\.identity.speakerLabel), ["caller"])
        XCTAssertEqual(callerOnly.map(\.identity.streamID), [fixture.icyStreamID])

        let icyRunDateOnly = try fixture.query.search(
            phrase: "alpha beta",
            options: TranscriptQuery.SearchOptions(
                limit: 10,
                runStartedAtFrom: "2026-04-30T13:00:01Z",
                runStartedAtThrough: "2026-04-30T13:00:01Z"
            )
        )
        XCTAssertEqual(icyRunDateOnly.map(\.identity.runID), [fixture.icyRunID])

        let hlsThroughDateOnly = try fixture.query.search(
            phrase: "alpha beta",
            options: TranscriptQuery.SearchOptions(
                limit: 10,
                runStartedAtThrough: "2026-04-30T12:00:01Z"
            )
        )
        XCTAssertEqual(hlsThroughDateOnly.map(\.identity.runID), [fixture.hlsRunID])

        let noMatchingFilter = try fixture.query.search(
            phrase: "alpha beta",
            options: TranscriptQuery.SearchOptions(
                limit: 10,
                streamIDs: [fixture.hlsStreamID],
                speakerLabels: ["caller"]
            )
        )
        XCTAssertEqual(noMatchingFilter, [])
    }

    func testSearchOptionsComposeFiltersBeforeRankLimit() throws {
        let fixture = try makeFixture()

        let unfilteredLowLimit = try XCTUnwrap(
            try fixture.query.search(phrase: "alpha beta", limit: 1).first
        )
        XCTAssertEqual(unfilteredLowLimit.identity.streamID, fixture.hlsStreamID)

        let filteredLowLimit = try fixture.query.search(
            phrase: "alpha beta",
            options: TranscriptQuery.SearchOptions(
                limit: 1,
                streamIDs: [fixture.icyStreamID],
                speakerLabels: ["caller"],
                runStartedAtFrom: "2026-04-30T13:00:01Z",
                runStartedAtThrough: "2026-04-30T13:00:01Z"
            )
        )
        XCTAssertEqual(filteredLowLimit.count, 1)
        XCTAssertEqual(filteredLowLimit.first?.identity.streamID, fixture.icyStreamID)
        XCTAssertEqual(filteredLowLimit.first?.identity.speakerLabel, "caller")
        XCTAssertEqual(filteredLowLimit.first?.identity.runID, fixture.icyRunID)
    }

    func testSearchOptionsValidateMalformedFiltersBeforeDatabaseRead() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(
            try fixture.query.search(
                phrase: "alpha",
                options: TranscriptQuery.SearchOptions(limit: 0)
            )
        ) { error in
            XCTAssertEqual(error as? TranscriptQuery.QueryError, .invalidLimit)
        }
        XCTAssertThrowsError(
            try fixture.query.search(
                phrase: "alpha",
                options: TranscriptQuery.SearchOptions(contextSegments: -1)
            )
        ) { error in
            XCTAssertEqual(error as? TranscriptQuery.QueryError, .invalidContext)
        }
        XCTAssertThrowsError(
            try fixture.query.search(
                phrase: "alpha",
                options: TranscriptQuery.SearchOptions(streamIDs: [fixture.hlsStreamID, 0])
            )
        ) { error in
            XCTAssertEqual(error as? TranscriptQuery.QueryError, .invalidStreamIDs)
        }
        XCTAssertThrowsError(
            try fixture.query.search(
                phrase: "alpha",
                options: TranscriptQuery.SearchOptions(speakerLabels: ["host", "  "])
            )
        ) { error in
            XCTAssertEqual(error as? TranscriptQuery.QueryError, .invalidSpeakerLabels)
        }
        XCTAssertThrowsError(
            try fixture.query.search(
                phrase: "alpha",
                options: TranscriptQuery.SearchOptions(
                    runStartedAtFrom: "2026-04-30T13:00:01Z",
                    runStartedAtThrough: "2026-04-30T12:00:01Z")
            )
        ) { error in
            XCTAssertEqual(error as? TranscriptQuery.QueryError, .invalidRunStartedAtRange)
        }
        XCTAssertThrowsError(
            try fixture.query.search(
                phrase: "alpha",
                options: TranscriptQuery.SearchOptions(runStartedAtFrom: "  ")
            )
        ) { error in
            XCTAssertEqual(error as? TranscriptQuery.QueryError, .invalidRunStartedAtRange)
        }
    }

    func testSearchValidatesInputsBeforeDatabaseRead() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(try fixture.query.search(phrase: "   \n\t  ")) { error in
            XCTAssertEqual(error as? TranscriptQuery.QueryError, .emptyPhrase)
        }
        XCTAssertThrowsError(try fixture.query.search(phrase: "alpha", limit: 0)) { error in
            XCTAssertEqual(error as? TranscriptQuery.QueryError, .invalidLimit)
        }
        XCTAssertThrowsError(try fixture.query.search(phrase: "alpha", contextSegments: -1)) {
            error in
            XCTAssertEqual(error as? TranscriptQuery.QueryError, .invalidContext)
        }
        XCTAssertThrowsError(try fixture.query.count(phrase: "  ")) { error in
            XCTAssertEqual(error as? TranscriptQuery.QueryError, .emptyPhrase)
        }
    }

    func testNoMatchAndQuotedPunctuationPhrasesAreSafe() throws {
        let fixture = try makeFixture()

        XCTAssertEqual(try fixture.query.search(phrase: "missing phrase"), [])
        XCTAssertEqual(try fixture.query.count(phrase: "missing phrase"), [])

        let quoted = try fixture.query.search(phrase: "quoted \"promo\" break", limit: 5)
        XCTAssertEqual(quoted.count, 1)
        XCTAssertEqual(quoted.first?.identity.speakerLabel, "producer")
        XCTAssertEqual(quoted.first?.occurrenceCount, 1)

        let punctuationNoMatch = try fixture.query.search(phrase: "alpha-beta?", limit: 5)
        XCTAssertEqual(punctuationNoMatch, [])
    }

    func testContextAtTimelineBoundariesDoesNotUnderflowOrOverflow() throws {
        let fixture = try makeFixture()

        let first = try XCTUnwrap(
            try fixture.query.search(phrase: "cold open", limit: 5, contextSegments: 2).first)
        XCTAssertEqual(first.context.map { $0.identity.sequence }, [0, 1, 2])
        XCTAssertEqual(first.context.map(\.role), [.match, .after, .after])

        let last = try XCTUnwrap(
            try fixture.query.search(phrase: "wrap up", limit: 5, contextSegments: 2).first)
        XCTAssertEqual(last.context.map { $0.identity.sequence }, [1, 2, 3])
        XCTAssertEqual(last.context.map(\.role), [.before, .before, .match])
    }

    private struct Fixture {
        var temporary: TemporarySoundingDatabase
        var query: TranscriptQuery
        var hlsStreamID: Int64
        var hlsRunID: Int64
        var hlsChunkID: Int64
        var icyStreamID: Int64
        var icyRunID: Int64
        var icyChunkID: Int64
    }

    private func makeFixture() throws -> Fixture {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)

        let hlsStreamID = try writer.createStream(
            streamType: "hls",
            source: "https://example.test/live.m3u8",
            createdAt: "2026-04-30T12:00:00Z"
        )
        let hlsRunID = try writer.createRun(
            streamID: hlsStreamID,
            startedAt: "2026-04-30T12:00:01Z",
            status: .running
        )
        let hlsChunkID = try writer.createChunk(
            runID: hlsRunID,
            sequence: 0,
            segmentURI: "segment-000.ts",
            startedAt: "2026-04-30T12:00:02Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: hlsRunID,
                chunkID: hlsChunkID,
                segments: [
                    segment(0, "host", 0.0, 1.0, "cold open starts now"),
                    segment(
                        1, "host", 1.0, 2.0, "Alpha beta alpha beta.",
                        words: ["Alpha", "beta", "alpha", "beta"]),
                    segment(2, "guest", 2.0, 3.0, "middle context only"),
                    segment(3, "producer", 3.0, 4.0, "quoted \"promo\" break then wrap up"),
                ],
                speakerTurns: [
                    SpeakerTurnDraft(
                        speakerLabel: "host", startSeconds: 0, endSeconds: 2, confidence: 0.91),
                    SpeakerTurnDraft(
                        speakerLabel: "guest", startSeconds: 2, endSeconds: 3, confidence: 0.84),
                    SpeakerTurnDraft(
                        speakerLabel: "producer", startSeconds: 3, endSeconds: 4, confidence: 0.82),
                ],
                createdAt: "2026-04-30T12:00:03Z"
            )
        )

        let icyStreamID = try writer.createStream(
            streamType: "icy",
            source: "https://example.test/radio",
            createdAt: "2026-04-30T13:00:00Z"
        )
        let icyRunID = try writer.createRun(
            streamID: icyStreamID,
            startedAt: "2026-04-30T13:00:01Z",
            status: .running
        )
        let icyChunkID = try writer.createChunk(
            runID: icyRunID,
            sequence: 0,
            segmentURI: "icy-000",
            startedAt: "2026-04-30T13:00:02Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: icyRunID,
                chunkID: icyChunkID,
                segments: [
                    segment(0, "dj", 0.0, 1.0, "station context"),
                    segment(
                        1, "caller", 1.0, 2.0, "callers say ALPHA BETA",
                        words: ["callers", "say", "ALPHA", "BETA"]),
                ],
                speakerTurns: [
                    SpeakerTurnDraft(
                        speakerLabel: "dj", startSeconds: 0, endSeconds: 1, confidence: 0.75),
                    SpeakerTurnDraft(
                        speakerLabel: "caller", startSeconds: 1, endSeconds: 2, confidence: 0.87),
                ],
                createdAt: "2026-04-30T13:00:03Z"
            )
        )

        return Fixture(
            temporary: temporary,
            query: TranscriptQuery(database: temporary.database),
            hlsStreamID: hlsStreamID,
            hlsRunID: hlsRunID,
            hlsChunkID: hlsChunkID,
            icyStreamID: icyStreamID,
            icyRunID: icyRunID,
            icyChunkID: icyChunkID
        )
    }

    private func segment(
        _ sequence: Int,
        _ speakerLabel: String,
        _ startSeconds: Double,
        _ endSeconds: Double,
        _ text: String,
        words: [String]? = nil
    ) -> TranscriptSegmentDraft {
        let wordTexts = words ?? text.split(separator: " ").map(String.init)
        let duration = max((endSeconds - startSeconds) / Double(max(wordTexts.count, 1)), 0.1)
        return TranscriptSegmentDraft(
            sequence: sequence,
            speakerLabel: speakerLabel,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            text: text,
            confidence: 0.9,
            words: wordTexts.enumerated().map { index, word in
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
