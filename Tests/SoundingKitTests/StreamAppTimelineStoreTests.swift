import GRDB
import XCTest
@testable import SoundingKit

final class StreamAppTimelineStoreTests: XCTestCase {
    func testSnapshotIsBoundedToSelectedStreamAndDoesNotExposeReconnectSource() throws {
        let fixture = try makeFixture()
        let store = StreamAppTimelineStore(database: fixture.temporary.database)

        let snapshot = try store.snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 22,
                    liveEdgeSeconds: 30,
                    bufferedStartSeconds: 10,
                    bufferedEndSeconds: 30
                ),
                paragraphLimit: 2,
                wordLimitPerParagraph: 2,
                metadataLimit: 2,
                timelineLimit: 6,
                lookbackSeconds: 30,
                refreshedAt: "2026-05-01T16:00:00Z"
            )
        )

        XCTAssertEqual(snapshot.streamID, fixture.mainStreamID)
        XCTAssertEqual(snapshot.transcriptParagraphs.map(\.text), ["Middle beta words", "Closing gamma words"])
        XCTAssertEqual(snapshot.transcriptParagraphs.flatMap { $0.words.map(\.text) }, ["Middle", "beta", "Closing", "gamma"])
        XCTAssertTrue(snapshot.transcriptParagraphs.allSatisfy { $0.streamID == fixture.mainStreamID })
        XCTAssertFalse(String(describing: snapshot).contains("token=fixture-secret"))
        XCTAssertFalse(String(describing: snapshot).contains("other-radio"))
        XCTAssertEqual(snapshot.diagnostics.latestSegmentEndSeconds, 30)
        XCTAssertEqual(snapshot.diagnostics.playerPositionSeconds, 22)
        XCTAssertEqual(snapshot.diagnostics.playerLiveEdgeSeconds, 30)
        XCTAssertEqual(snapshot.diagnostics.lagSeconds, 8)
        XCTAssertEqual(snapshot.diagnostics.refreshedAt, "2026-05-01T16:00:00Z")
    }

    func testTimelineMergesTranscriptSongAndAdItemsDeterministicallyWithSeekability() throws {
        let fixture = try makeFixture()
        let store = StreamAppTimelineStore(database: fixture.temporary.database)

        let snapshot = try store.snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 15,
                    liveEdgeSeconds: 35,
                    bufferedStartSeconds: 10,
                    bufferedEndSeconds: 30,
                    unavailableRangeMessage: "Requested 40s is unavailable (available range 10-30s)."
                ),
                paragraphLimit: 5,
                wordLimitPerParagraph: 5,
                metadataLimit: 3,
                timelineLimit: 10,
                lookbackSeconds: 40,
                refreshedAt: "2026-05-01T16:00:01Z"
            )
        )

        XCTAssertEqual(
            snapshot.timelineItems.map { "\($0.kind.rawValue):\($0.startSeconds):\($0.title):\($0.isSeekable)" },
            [
                "transcript:0.0:host: false",
                "song:5.0:Fixture Artist — Fixture Song: false",
                "event:9.0:ad_start: false",
                "transcript:10.0:guest: true",
                "transcript:20.0:host: true",
                "event:21.0:ad_end: true"
            ]
        )
        XCTAssertEqual(snapshot.currentMetadata?.title, "Fixture Artist — Fixture Song")
        XCTAssertEqual(snapshot.recentMetadata.map(\.title), ["Fixture Artist — Fixture Song"])
        XCTAssertEqual(snapshot.diagnostics.bufferedSeekUnavailableMessage, "Requested 40s is unavailable (available range 10-30s).")
    }

    func testSpeakerDisplayOverridesPersistAndDoNotMutateProviderRowsOrFts() throws {
        let fixture = try makeFixture()
        let store = StreamAppTimelineStore(database: fixture.temporary.database)

        try store.updateSpeakerDisplay(
            streamID: fixture.mainStreamID,
            rawLabel: "host",
            displayLabel: "Morning Host",
            colorToken: "violet",
            updatedAt: "2026-05-01T16:05:00Z"
        )

        let reloaded = StreamAppTimelineStore(database: fixture.temporary.database)
        let snapshot = try reloaded.snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: nil,
                paragraphLimit: 5,
                wordLimitPerParagraph: 5,
                metadataLimit: 5,
                timelineLimit: 10,
                lookbackSeconds: 60,
                refreshedAt: "2026-05-01T16:05:01Z"
            )
        )

        XCTAssertEqual(snapshot.speakers.first { $0.rawLabel == "host" }?.displayLabel, "Morning Host")
        XCTAssertEqual(snapshot.speakers.first { $0.rawLabel == "host" }?.colorToken, "violet")
        XCTAssertEqual(snapshot.transcriptParagraphs.first?.speakerDisplay.displayLabel, "Morning Host")

        let providerRows = try fixture.temporary.database.read { db in
            try (
                segmentLabels: String.fetchAll(db, sql: "SELECT DISTINCT speaker_label FROM transcript_segments ORDER BY speaker_label"),
                wordLabels: String.fetchAll(db, sql: "SELECT DISTINCT speaker_label FROM transcript_words ORDER BY speaker_label"),
                turnLabels: String.fetchAll(db, sql: "SELECT DISTINCT speaker_label FROM speaker_turns ORDER BY speaker_label"),
                ftsLabels: String.fetchAll(db, sql: "SELECT DISTINCT speaker_label FROM transcript_segments_fts ORDER BY speaker_label")
            )
        }

        XCTAssertEqual(providerRows.segmentLabels, ["caller", "dj", "guest", "host"])
        XCTAssertEqual(providerRows.wordLabels, ["caller", "dj", "guest", "host"])
        XCTAssertEqual(providerRows.turnLabels, ["caller", "dj", "guest", "host"])
        XCTAssertEqual(providerRows.ftsLabels, ["caller", "dj", "guest", "host"])
    }

    func testValidationRejectsMalformedInputsBeforeSql() throws {
        let fixture = try makeFixture()
        let store = StreamAppTimelineStore(database: fixture.temporary.database)

        XCTAssertThrowsError(try store.snapshot(request: StreamAppTimelineRequest(streamID: -1))) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .invalidStreamID)
        }
        XCTAssertThrowsError(try store.snapshot(request: StreamAppTimelineRequest(streamID: fixture.mainStreamID, paragraphLimit: 0))) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .invalidLimit("paragraphLimit"))
        }
        XCTAssertThrowsError(try store.snapshot(request: StreamAppTimelineRequest(streamID: fixture.mainStreamID, lookbackSeconds: -1))) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .invalidWindow)
        }
        XCTAssertThrowsError(try store.snapshot(request: StreamAppTimelineRequest(streamID: 9_999))) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .streamNotFound)
        }
        XCTAssertThrowsError(try store.updateSpeakerDisplay(streamID: fixture.mainStreamID, rawLabel: " ", displayLabel: "Host")) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .emptyRawSpeakerLabel)
        }
        XCTAssertThrowsError(try store.updateSpeakerDisplay(streamID: fixture.mainStreamID, rawLabel: "host", displayLabel: " ")) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .emptyDisplayLabel)
        }
        XCTAssertThrowsError(try store.updateSpeakerDisplay(streamID: fixture.mainStreamID, rawLabel: "host", displayLabel: String(repeating: "A", count: 65))) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .displayLabelTooLong(max: 64))
        }
        XCTAssertThrowsError(try store.updateSpeakerDisplay(streamID: fixture.mainStreamID, rawLabel: "host", displayLabel: "Host", colorToken: "DROP TABLE")) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .invalidColorToken("DROP TABLE"))
        }
    }

    func testEmptyTimelineReturnsDiagnosticsWithValidationErrors() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Empty",
            streamType: "hls",
            source: "https://example.test/empty.m3u8?token=secret",
            createdAt: "2026-05-01T17:00:00Z"
        )
        let store = StreamAppTimelineStore(database: temporary.database)

        let snapshot = try store.snapshot(
            request: StreamAppTimelineRequest(
                streamID: stream.id,
                player: AppPlayerTimelineSnapshot(streamID: stream.id, positionSeconds: 4, liveEdgeSeconds: 8),
                refreshedAt: "2026-05-01T17:00:01Z"
            )
        )

        XCTAssertEqual(snapshot.transcriptParagraphs, [])
        XCTAssertNil(snapshot.currentMetadata)
        XCTAssertEqual(snapshot.timelineItems, [])
        XCTAssertNil(snapshot.diagnostics.latestSegmentEndSeconds)
        XCTAssertEqual(snapshot.diagnostics.lagSeconds, 4)
        XCTAssertEqual(snapshot.diagnostics.validationErrors, [])
        XCTAssertFalse(String(describing: snapshot).contains("token=secret"))
    }

    private struct Fixture {
        var temporary: TemporarySoundingDatabase
        var mainStreamID: Int64
        var otherStreamID: Int64
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
            source: "https://example.test/other-radio?token=other-secret",
            createdAt: "2026-05-01T15:30:00Z"
        )

        let writer = IngestPersistence(database: temporary.database)
        let mainRunID = try writer.createRun(streamID: main.id, startedAt: "2026-05-01T15:00:01Z", status: .running)
        let mainChunk0ID = try writer.createChunk(runID: mainRunID, sequence: 0, segmentURI: "main-000.ts", startedAt: "2026-05-01T15:00:02Z", endedAt: "2026-05-01T15:00:12Z")
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: mainRunID,
                chunkID: mainChunk0ID,
                segments: [
                    segment(0, "host", 0, 10, "Opening alpha words"),
                    segment(1, "guest", 10, 20, "Middle beta words"),
                ],
                speakerTurns: [
                    SpeakerTurnDraft(speakerLabel: "host", startSeconds: 0, endSeconds: 10, confidence: 0.91),
                    SpeakerTurnDraft(speakerLabel: "guest", startSeconds: 10, endSeconds: 20, confidence: 0.88),
                ],
                adMarkers: [
                    AdMarker(type: "splice_insert", classification: .adStart, source: "manifest", pts: 9, segment: "main-000.ts", timestamp: "2026-05-01T15:00:09Z")
                ],
                songPlays: [
                    SongPlayDraft(song: knownSong, startSeconds: 5, endSeconds: 25, confidence: 0.92, source: "fixture")
                ],
                createdAt: "2026-05-01T15:00:03Z"
            )
        )
        let mainChunk1ID = try writer.createChunk(runID: mainRunID, sequence: 1, segmentURI: "main-001.ts", startedAt: "2026-05-01T15:00:12Z", endedAt: "2026-05-01T15:00:22Z")
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: mainRunID,
                chunkID: mainChunk1ID,
                segments: [segment(2, "host", 20, 30, "Closing gamma words")],
                speakerTurns: [SpeakerTurnDraft(speakerLabel: "host", startSeconds: 20, endSeconds: 30, confidence: 0.86)],
                adMarkers: [AdMarker(type: "splice_insert", classification: .adEnd, source: "manifest", pts: 21, segment: "main-001.ts", timestamp: "2026-05-01T15:00:21Z")],
                createdAt: "2026-05-01T15:00:13Z"
            )
        )

        let otherRunID = try writer.createRun(streamID: other.id, startedAt: "2026-05-01T15:30:01Z", status: .running)
        let otherChunkID = try writer.createChunk(runID: otherRunID, sequence: 0, segmentURI: "other-000", startedAt: "2026-05-01T15:30:02Z", endedAt: "2026-05-01T15:30:12Z")
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: otherRunID,
                chunkID: otherChunkID,
                segments: [
                    segment(0, "dj", 0, 9, "Other station intro"),
                    segment(1, "caller", 9, 18, "Other station call"),
                ],
                speakerTurns: [
                    SpeakerTurnDraft(speakerLabel: "dj", startSeconds: 0, endSeconds: 9, confidence: 0.82),
                    SpeakerTurnDraft(speakerLabel: "caller", startSeconds: 9, endSeconds: 18, confidence: 0.80),
                ],
                createdAt: "2026-05-01T15:30:03Z"
            )
        )

        return Fixture(temporary: temporary, mainStreamID: main.id, otherStreamID: other.id)
    }

    private var knownSong: UnresolvedSongDraft {
        UnresolvedSongDraft(
            songKey: "fixture:artist:song",
            title: "Fixture Song",
            artist: "Fixture Artist",
            album: "Timeline Proofs",
            isrc: "US-S02-26-00001",
            displayName: "Fixture Artist — Fixture Song"
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
