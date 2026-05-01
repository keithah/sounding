import GRDB
import XCTest

@testable import SoundingKit

final class StreamAppSearchStoreTests: XCTestCase {
    func testFilteredSearchProjectsSafeMetadataDisplayOverridesContextAndStatus() throws {
        let fixture = try makeFixture()
        let timelineStore = StreamAppTimelineStore(database: fixture.temporary.database)
        try timelineStore.updateSpeakerDisplay(
            streamID: fixture.mainStreamID,
            rawLabel: "host",
            displayLabel: "Morning Host",
            colorToken: "violet",
            updatedAt: "2026-05-01T18:05:00Z"
        )
        let store = StreamAppSearchStore(database: fixture.temporary.database)

        let snapshot = try store.snapshot(
            request: StreamAppSearchRequest(
                phrase: "alpha beta",
                streamIDs: [fixture.mainStreamID],
                speakerLabels: ["host"],
                runStartedAtFrom: "2026-05-01T18:00:01Z",
                runStartedAtThrough: "2026-05-01T18:00:01Z",
                limit: 5,
                contextSegments: 1,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 11,
                    liveEdgeSeconds: 40,
                    bufferedStartSeconds: 0,
                    bufferedEndSeconds: 15
                ),
                refreshedAt: "2026-05-01T18:06:00Z"
            )
        )

        XCTAssertEqual(snapshot.diagnostics.status, .results)
        XCTAssertEqual(snapshot.diagnostics.statusMessage, "Found 2 transcript result(s).")
        XCTAssertEqual(snapshot.diagnostics.resultCount, 2)
        XCTAssertEqual(snapshot.diagnostics.refreshedAt, "2026-05-01T18:06:00Z")
        XCTAssertEqual(
            snapshot.results.map(\.streamID), [fixture.mainStreamID, fixture.mainStreamID])

        let first = try XCTUnwrap(snapshot.results.first { $0.sequence == 1 })
        XCTAssertEqual(first.streamName, "Search Main")
        XCTAssertEqual(first.streamType, "hls")
        XCTAssertEqual(first.sourceDescription, "https://example.test/main.m3u8")
        XCTAssertEqual(first.runID, fixture.mainRunID)
        XCTAssertEqual(first.runStartedAt, "2026-05-01T18:00:01Z")
        XCTAssertEqual(first.rawSpeakerLabel, "host")
        XCTAssertEqual(first.speakerDisplay.displayLabel, "Morning Host")
        XCTAssertEqual(first.speakerDisplay.colorToken, "violet")
        XCTAssertEqual(first.text, "Alpha beta alpha beta")
        XCTAssertEqual(first.occurrenceCount, 2)
        XCTAssertEqual(first.context.map(\.role), [.before, .match, .after])
        XCTAssertEqual(
            first.context.map { $0.speakerDisplay.displayLabel },
            ["guest", "Morning Host", "guest"])
        XCTAssertEqual(first.words.map(\.text), ["Alpha", "beta", "alpha", "beta"])
        XCTAssertTrue(first.words.allSatisfy { $0.speakerDisplay.displayLabel == "Morning Host" })
        XCTAssertTrue(first.isSeekable)
        XCTAssertNil(first.seekUnavailableMessage)
        XCTAssertFalse(String(describing: snapshot).contains("token=main-secret"))
    }

    func testSearchMarksBufferedAndUnbufferedResultsInSameSet() throws {
        let fixture = try makeFixture()
        let store = StreamAppSearchStore(database: fixture.temporary.database)

        let snapshot = try store.snapshot(
            request: StreamAppSearchRequest(
                phrase: "alpha beta",
                limit: 10,
                contextSegments: 0,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 12,
                    liveEdgeSeconds: 45,
                    bufferedStartSeconds: 0,
                    bufferedEndSeconds: 20
                ),
                refreshedAt: "2026-05-01T18:06:30Z"
            )
        )

        let seekable = snapshot.results.filter(\.isSeekable)
        let unseekable = snapshot.results.filter { !$0.isSeekable }
        XCTAssertEqual(seekable.map(\.sequence), [1])
        XCTAssertEqual(unseekable.count, 2)
        XCTAssertTrue(
            unseekable.contains { $0.streamID == fixture.mainStreamID && $0.sequence == 3 })
        XCTAssertTrue(unseekable.contains { $0.streamID == fixture.otherStreamID })
        XCTAssertEqual(snapshot.diagnostics.unseekableResultCount, 2)
        XCTAssertEqual(snapshot.diagnostics.bufferedSeekUnavailableMessages.count, 2)
        XCTAssertTrue(
            snapshot.diagnostics.bufferedSeekUnavailableMessages.contains {
                $0.contains("outside the current playback buffer")
            }
        )
        XCTAssertTrue(
            snapshot.diagnostics.bufferedSeekUnavailableMessages.contains {
                $0.contains("not in the active playback stream")
            }
        )
    }

    func testMissingStreamFilterIsNormalEmptyState() throws {
        let fixture = try makeFixture()
        let store = StreamAppSearchStore(database: fixture.temporary.database)

        let snapshot = try store.snapshot(
            request: StreamAppSearchRequest(
                phrase: "alpha beta",
                streamIDs: [9_999],
                limit: 10,
                refreshedAt: "2026-05-01T18:07:00Z"
            )
        )

        XCTAssertEqual(snapshot.results, [])
        XCTAssertEqual(snapshot.diagnostics.status, .empty)
        XCTAssertEqual(snapshot.diagnostics.statusMessage, "No transcript results found.")
        XCTAssertEqual(snapshot.diagnostics.resultCount, 0)
        XCTAssertEqual(snapshot.diagnostics.validationErrors, [])
        XCTAssertNil(snapshot.diagnostics.databaseErrorMessage)
    }

    func testValidationRejectsMalformedInputsWithRedactedAppErrors() throws {
        let fixture = try makeFixture()
        let store = StreamAppSearchStore(database: fixture.temporary.database)

        XCTAssertThrowsError(try store.snapshot(request: StreamAppSearchRequest(phrase: " "))) {
            error in
            XCTAssertEqual(error as? StreamAppSearchStoreError, .emptyPhrase)
            XCTAssertFalse(String(describing: error).contains("token="))
        }
        XCTAssertThrowsError(
            try store.snapshot(
                request: StreamAppSearchRequest(
                    phrase: "alpha", streamIDs: [fixture.mainStreamID, 0]))
        ) { error in
            XCTAssertEqual(error as? StreamAppSearchStoreError, .invalidStreamIDs)
        }
        XCTAssertThrowsError(
            try store.snapshot(
                request: StreamAppSearchRequest(phrase: "alpha", speakerLabels: ["host", "  "]))
        ) { error in
            XCTAssertEqual(error as? StreamAppSearchStoreError, .invalidSpeakerLabels)
        }
        XCTAssertThrowsError(
            try store.snapshot(
                request: StreamAppSearchRequest(
                    phrase: "alpha",
                    runStartedAtFrom: "2026-05-01T19:00:00Z",
                    runStartedAtThrough: "2026-05-01T18:00:00Z"
                )
            )
        ) { error in
            XCTAssertEqual(error as? StreamAppSearchStoreError, .invalidRunStartedAtRange)
        }
        XCTAssertThrowsError(
            try store.snapshot(request: StreamAppSearchRequest(phrase: "alpha", limit: 0))
        ) { error in
            XCTAssertEqual(error as? StreamAppSearchStoreError, .invalidLimit)
        }
    }

    func testDisplayOverridesDoNotMutateProviderRowsOrFts() throws {
        let fixture = try makeFixture()
        let timelineStore = StreamAppTimelineStore(database: fixture.temporary.database)
        try timelineStore.updateSpeakerDisplay(
            streamID: fixture.mainStreamID,
            rawLabel: "host",
            displayLabel: "Morning Host",
            colorToken: "violet",
            updatedAt: "2026-05-01T18:05:00Z"
        )
        let store = StreamAppSearchStore(database: fixture.temporary.database)

        let snapshot = try store.snapshot(
            request: StreamAppSearchRequest(phrase: "alpha beta", streamIDs: [fixture.mainStreamID])
        )

        XCTAssertEqual(snapshot.results.first?.speakerDisplay.displayLabel, "Morning Host")
        let providerRows = try fixture.temporary.database.read { db in
            try (
                segmentLabels: String.fetchAll(
                    db,
                    sql:
                        "SELECT DISTINCT speaker_label FROM transcript_segments ORDER BY speaker_label"
                ),
                wordLabels: String.fetchAll(
                    db,
                    sql:
                        "SELECT DISTINCT speaker_label FROM transcript_words ORDER BY speaker_label"
                ),
                turnLabels: String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT speaker_label FROM speaker_turns ORDER BY speaker_label"),
                ftsLabels: String.fetchAll(
                    db,
                    sql:
                        "SELECT DISTINCT speaker_label FROM transcript_segments_fts ORDER BY speaker_label"
                )
            )
        }

        XCTAssertEqual(providerRows.segmentLabels, ["caller", "guest", "host"])
        XCTAssertEqual(providerRows.wordLabels, ["caller", "guest", "host"])
        XCTAssertEqual(providerRows.turnLabels, ["caller", "guest", "host"])
        XCTAssertEqual(providerRows.ftsLabels, ["caller", "guest", "host"])
    }

    private struct Fixture {
        var temporary: TemporarySoundingDatabase
        var mainStreamID: Int64
        var mainRunID: Int64
        var otherStreamID: Int64
    }

    private func makeFixture() throws -> Fixture {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let main = try registry.add(
            name: "Search Main",
            streamType: "hls",
            source: "https://example.test/main.m3u8?token=main-secret",
            createdAt: "2026-05-01T18:00:00Z"
        )
        let other = try registry.add(
            name: "Search Other",
            streamType: "icy",
            source: "https://example.test/other-radio?token=other-secret",
            createdAt: "2026-05-01T18:30:00Z"
        )

        let writer = IngestPersistence(database: temporary.database)
        let mainRunID = try writer.createRun(
            streamID: main.id, startedAt: "2026-05-01T18:00:01Z", status: .running)
        let mainChunkID = try writer.createChunk(
            runID: mainRunID, sequence: 0, segmentURI: "main-000.ts",
            startedAt: "2026-05-01T18:00:02Z")
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: mainRunID,
                chunkID: mainChunkID,
                segments: [
                    segment(0, "guest", 0, 8, "opening context only"),
                    segment(
                        1, "host", 10, 14, "Alpha beta alpha beta",
                        words: ["Alpha", "beta", "alpha", "beta"]),
                    segment(2, "guest", 15, 18, "context after only"),
                    segment(3, "host", 30, 34, "late alpha beta"),
                ],
                speakerTurns: [
                    SpeakerTurnDraft(
                        speakerLabel: "guest", startSeconds: 0, endSeconds: 8, confidence: 0.8),
                    SpeakerTurnDraft(
                        speakerLabel: "host", startSeconds: 10, endSeconds: 14, confidence: 0.9),
                    SpeakerTurnDraft(
                        speakerLabel: "guest", startSeconds: 15, endSeconds: 18, confidence: 0.8),
                    SpeakerTurnDraft(
                        speakerLabel: "host", startSeconds: 30, endSeconds: 34, confidence: 0.9),
                ],
                createdAt: "2026-05-01T18:00:03Z"
            )
        )

        let otherRunID = try writer.createRun(
            streamID: other.id, startedAt: "2026-05-01T18:30:01Z", status: .running)
        let otherChunkID = try writer.createChunk(
            runID: otherRunID, sequence: 0, segmentURI: "other-000",
            startedAt: "2026-05-01T18:30:02Z")
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: otherRunID,
                chunkID: otherChunkID,
                segments: [segment(0, "caller", 40, 44, "other alpha beta result")],
                speakerTurns: [
                    SpeakerTurnDraft(
                        speakerLabel: "caller", startSeconds: 40, endSeconds: 44, confidence: 0.82)
                ],
                createdAt: "2026-05-01T18:30:03Z"
            )
        )

        return Fixture(
            temporary: temporary,
            mainStreamID: main.id,
            mainRunID: mainRunID,
            otherStreamID: other.id
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
