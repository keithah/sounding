import XCTest
@testable import SoundingKit

final class StreamAppViewModelTimelineTests: XCTestCase {
    func testRefreshSelectedTimelineScopesSnapshotToSelectedStream() throws {
        let fixture = try makeFixture()
        let store = StreamAppTimelineStore(database: fixture.temporary.database)
        var viewModel = StreamAppViewModel(
            streams: [fixture.mainItem, fixture.otherItem],
            selectedStreamID: fixture.mainItem.id,
            playerTimelines: [
                fixture.mainItem.id: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainItem.id,
                    positionSeconds: 16,
                    liveEdgeSeconds: 24,
                    bufferedStartSeconds: 10,
                    bufferedEndSeconds: 24
                ),
                fixture.otherItem.id: AppPlayerTimelineSnapshot(
                    streamID: fixture.otherItem.id,
                    positionSeconds: 6,
                    liveEdgeSeconds: 8,
                    bufferedStartSeconds: 0,
                    bufferedEndSeconds: 8
                ),
            ]
        )

        try viewModel.refreshSelectedTimeline(using: store, refreshedAt: "2026-05-01T18:00:00Z")

        let selected = try XCTUnwrap(viewModel.selectedStream)
        XCTAssertEqual(selected.item.id, fixture.mainItem.id)
        XCTAssertEqual(selected.recentTranscriptParagraphs.map(\.text), ["Main opening", "Main closing"])
        XCTAssertEqual(selected.currentMetadata?.title, "Main Song")
        XCTAssertEqual(selected.currentMetadata?.artist, "Fixture Artist")
        XCTAssertEqual(selected.speakerDisplays.map(\.rawLabel), ["host"])
        XCTAssertTrue(selected.timelineItems.allSatisfy { $0.id != "transcript:\(fixture.otherSegmentID)" })
        XCTAssertEqual(selected.timelineDiagnostics?.refreshedAt, "2026-05-01T18:00:00Z")
        XCTAssertEqual(selected.timelineFreshnessMessage, "Timeline refreshed 2026-05-01T18:00:00Z.")
        XCTAssertEqual(selected.timelineLagMessage, "Transcript lag 8s.")
        XCTAssertNil(selected.timelineRefreshErrorMessage)
    }

    func testRefreshFailurePreservesLastGoodSnapshotAndRedactsMessage() throws {
        let fixture = try makeFixture()
        let store = StreamAppTimelineStore(database: fixture.temporary.database)
        var viewModel = StreamAppViewModel(streams: [fixture.mainItem], selectedStreamID: fixture.mainItem.id)
        try viewModel.refreshSelectedTimeline(using: store, refreshedAt: "2026-05-01T18:01:00Z")

        viewModel = StreamAppViewModel(
            streams: [fixture.mainItem],
            selectedStreamID: fixture.mainItem.id,
            timelineSnapshots: viewModel.timelineSnapshots
        )
        let failingTemporary = try TemporarySoundingDatabase()
        let failingStore = StreamAppTimelineStore(database: failingTemporary.database)

        XCTAssertThrowsError(
            try viewModel.refreshSelectedTimeline(using: failingStore, refreshedAt: "2026-05-01T18:01:10Z")
        )

        let selected = try XCTUnwrap(viewModel.selectedStream)
        XCTAssertEqual(selected.recentTranscriptParagraphs.map(\.text), ["Main opening", "Main closing"])
        XCTAssertEqual(selected.timelineDiagnostics?.refreshedAt, "2026-05-01T18:01:00Z")
        XCTAssertEqual(selected.timelineRefreshErrorMessage, "The selected stream was not found.")
        XCTAssertFalse(String(describing: viewModel).contains("token=main-secret"))
    }

    func testSpeakerDisplayEditRefreshesSelectedProjectionAndRejectsMalformedInputs() throws {
        let fixture = try makeFixture()
        let store = StreamAppTimelineStore(database: fixture.temporary.database)
        var viewModel = StreamAppViewModel(streams: [fixture.mainItem], selectedStreamID: fixture.mainItem.id)
        try viewModel.refreshSelectedTimeline(using: store, refreshedAt: "2026-05-01T18:02:00Z")

        try viewModel.updateSelectedSpeakerDisplay(
            rawLabel: "host",
            displayLabel: "Morning Host",
            colorToken: "violet",
            using: store,
            refreshedAt: "2026-05-01T18:02:10Z"
        )

        let selected = try XCTUnwrap(viewModel.selectedStream)
        XCTAssertEqual(selected.speakerDisplays.first?.displayLabel, "Morning Host")
        XCTAssertEqual(selected.speakerDisplays.first?.colorToken, "violet")
        XCTAssertEqual(selected.recentTranscriptParagraphs.first?.speakerDisplay.displayLabel, "Morning Host")
        XCTAssertNil(selected.speakerEditErrorMessage)

        XCTAssertThrowsError(
            try viewModel.updateSelectedSpeakerDisplay(
                rawLabel: "host",
                displayLabel: " ",
                colorToken: "violet",
                using: store,
                refreshedAt: "2026-05-01T18:02:20Z"
            )
        ) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .emptyDisplayLabel)
        }
        XCTAssertEqual(viewModel.selectedStream?.speakerEditErrorMessage, "Speaker display label must not be empty.")
    }

    func testTimelineProjectionHandlesEmptyAndUnbufferedSnapshots() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let empty = try registry.add(
            name: "Empty",
            streamType: "hls",
            source: "https://example.test/empty.m3u8?token=empty-secret",
            createdAt: "2026-05-01T19:00:00Z"
        )
        let item = StreamAppListItem(record: empty)
        let store = StreamAppTimelineStore(database: temporary.database)
        var viewModel = StreamAppViewModel(
            streams: [item],
            selectedStreamID: item.id,
            playerTimelines: [
                item.id: AppPlayerTimelineSnapshot(
                    streamID: item.id,
                    positionSeconds: 3,
                    liveEdgeSeconds: 12,
                    unavailableRangeMessage: "Requested https://secret.example.test/live at 40s is unavailable."
                )
            ]
        )

        try viewModel.refreshSelectedTimeline(using: store, refreshedAt: "2026-05-01T19:00:05Z")

        let selected = try XCTUnwrap(viewModel.selectedStream)
        XCTAssertEqual(selected.recentTranscriptParagraphs, [])
        XCTAssertEqual(selected.recentMetadata, [])
        XCTAssertEqual(selected.timelineItems, [])
        XCTAssertEqual(selected.timelineLagMessage, "Transcript lag 9s.")
        XCTAssertEqual(
            selected.bufferedSeekUnavailableMessage,
            "Requested [redacted-path] at 40s is unavailable."
        )
        XCTAssertFalse(selected.hasSeekableTimelineItems)
        XCTAssertFalse(String(describing: selected).contains("empty-secret"))
    }

    func testRefreshAndSpeakerEditRequireCurrentSelection() throws {
        let fixture = try makeFixture()
        let store = StreamAppTimelineStore(database: fixture.temporary.database)
        var viewModel = StreamAppViewModel(streams: [fixture.mainItem], selectedStreamID: nil)

        XCTAssertThrowsError(try viewModel.refreshSelectedTimeline(using: store)) { error in
            XCTAssertEqual(error as? StreamAppViewModelTimelineError, .noSelectedStream)
        }
        XCTAssertThrowsError(
            try viewModel.updateSelectedSpeakerDisplay(rawLabel: "host", displayLabel: "Host", using: store)
        ) { error in
            XCTAssertEqual(error as? StreamAppViewModelTimelineError, .noSelectedStream)
        }

        viewModel.selectedStreamID = fixture.otherItem.id
        XCTAssertThrowsError(try viewModel.refreshSelectedTimeline(using: store)) { error in
            XCTAssertEqual(error as? StreamAppViewModelTimelineError, .selectedStreamUnavailable)
        }
    }

    private struct Fixture {
        var temporary: TemporarySoundingDatabase
        var mainItem: StreamAppListItem
        var otherItem: StreamAppListItem
        var otherSegmentID: Int64
    }

    private func makeFixture() throws -> Fixture {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let main = try registry.add(
            name: "Managed Main",
            streamType: "hls",
            source: "https://example.test/main.m3u8?token=main-secret",
            createdAt: "2026-05-01T17:00:00Z"
        )
        let other = try registry.add(
            name: "Managed Other",
            streamType: "icy",
            source: "https://example.test/other?token=other-secret",
            createdAt: "2026-05-01T17:10:00Z"
        )

        let writer = IngestPersistence(database: temporary.database)
        let mainRunID = try writer.createRun(streamID: main.id, startedAt: "2026-05-01T17:00:01Z", status: .running)
        let mainChunkID = try writer.createChunk(runID: mainRunID, sequence: 0, segmentURI: "main-000.ts", startedAt: "2026-05-01T17:00:02Z", endedAt: "2026-05-01T17:00:22Z")
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: mainRunID,
                chunkID: mainChunkID,
                segments: [
                    segment(0, "host", 0, 10, "Main opening"),
                    segment(1, "host", 10, 20, "Main closing"),
                ],
                speakerTurns: [SpeakerTurnDraft(speakerLabel: "host", startSeconds: 0, endSeconds: 20, confidence: 0.9)],
                songPlays: [
                    SongPlayDraft(song: mainSong, startSeconds: 4, endSeconds: 18, confidence: 0.93, source: "fixture")
                ],
                createdAt: "2026-05-01T17:00:03Z"
            )
        )

        let otherRunID = try writer.createRun(streamID: other.id, startedAt: "2026-05-01T17:10:01Z", status: .running)
        let otherChunkID = try writer.createChunk(runID: otherRunID, sequence: 0, segmentURI: "other-000.ts", startedAt: "2026-05-01T17:10:02Z", endedAt: "2026-05-01T17:10:12Z")
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: otherRunID,
                chunkID: otherChunkID,
                segments: [segment(0, "dj", 0, 8, "Other intro")],
                speakerTurns: [SpeakerTurnDraft(speakerLabel: "dj", startSeconds: 0, endSeconds: 8, confidence: 0.8)],
                createdAt: "2026-05-01T17:10:03Z"
            )
        )
        let otherSegmentID = try temporary.database.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM transcript_segments WHERE run_id = ?", arguments: [otherRunID])!
        }

        return Fixture(
            temporary: temporary,
            mainItem: StreamAppListItem(record: main),
            otherItem: StreamAppListItem(record: other),
            otherSegmentID: otherSegmentID
        )
    }

    private var mainSong: UnresolvedSongDraft {
        UnresolvedSongDraft(
            songKey: "fixture:main:song",
            title: "Main Song",
            artist: "Fixture Artist",
            album: "Timeline Proofs",
            isrc: "US-S02-26-00002",
            displayName: "Fixture Artist — Main Song"
        )
    }

    private func segment(
        _ sequence: Int,
        _ speakerLabel: String,
        _ startSeconds: Double,
        _ endSeconds: Double,
        _ text: String
    ) -> TranscriptSegmentDraft {
        TranscriptSegmentDraft(
            sequence: sequence,
            speakerLabel: speakerLabel,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            text: text,
            confidence: 0.9,
            words: []
        )
    }
}
