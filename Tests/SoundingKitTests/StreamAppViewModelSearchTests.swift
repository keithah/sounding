import XCTest

@testable import SoundingKit

final class StreamAppViewModelSearchTests: XCTestCase {
  func testRunSearchScopesToSelectedStreamAndExposesProjectionState() throws {
    let fixture = try makeFixture()
    let searchStore = StreamAppSearchStore(database: fixture.temporary.database)
    var viewModel = makeViewModel(fixture: fixture)
    viewModel.updateSearchDraft(
      StreamAppSearchDraft(
        phrase: "alpha beta",
        scopeToSelectedStream: true,
        speakerLabels: ["host"],
        runStartedAtFrom: "2026-05-01T18:00:01Z",
        runStartedAtThrough: "2026-05-01T18:00:01Z",
        limit: 10,
        contextSegments: 1
      )
    )

    let snapshot = try viewModel.runSearch(
      using: searchStore, refreshedAt: "2026-05-01T18:10:00Z")

    XCTAssertEqual(snapshot.request.streamIDs, [fixture.mainItem.id])
    XCTAssertEqual(snapshot.results.map(\.streamID), [fixture.mainItem.id, fixture.mainItem.id])
    XCTAssertEqual(snapshot.results.map(\.sequence), [1, 3])
    XCTAssertEqual(snapshot.diagnostics.status, .results)
    XCTAssertEqual(snapshot.diagnostics.resultCount, 2)
    XCTAssertEqual(snapshot.diagnostics.refreshedAt, "2026-05-01T18:10:00Z")

    let selected = try XCTUnwrap(viewModel.selectedStream)
    XCTAssertEqual(selected.searchDraft.phrase, "alpha beta")
    XCTAssertEqual(selected.searchDiagnostics?.statusMessage, "Found 2 transcript result(s).")
    XCTAssertEqual(selected.searchResults.map(\.segmentID), snapshot.results.map(\.segmentID))
    XCTAssertNil(selected.searchErrorMessage)
    XCTAssertNil(selected.selectedSearchResultID)
    XCTAssertFalse(String(describing: selected).contains("token=main-secret"))
  }

  func testAllStreamSearchStillRejectsJumpToDifferentSelectedStream() throws {
    let fixture = try makeFixture()
    let searchStore = StreamAppSearchStore(database: fixture.temporary.database)
    let timelineStore = StreamAppTimelineStore(database: fixture.temporary.database)
    var viewModel = makeViewModel(fixture: fixture)
    viewModel.updateSearchDraft(
      StreamAppSearchDraft(phrase: "alpha beta", scopeToSelectedStream: false, limit: 10)
    )
    let snapshot = try viewModel.runSearch(
      using: searchStore, refreshedAt: "2026-05-01T18:11:00Z")
    let otherResult = try XCTUnwrap(snapshot.results.first { $0.streamID == fixture.otherItem.id })

    XCTAssertThrowsError(
      try viewModel.selectSearchResult(
        id: otherResult.id, using: timelineStore, refreshedAt: "2026-05-01T18:11:10Z")
    ) { error in
      XCTAssertEqual(error as? StreamAppViewModelTimelineError, .searchResultWrongStream)
    }

    let selected = try XCTUnwrap(viewModel.selectedStream)
    XCTAssertEqual(selected.searchJumpMessage, "Search result belongs to a different stream.")
    XCTAssertNil(selected.selectedSearchResultID)
    XCTAssertNil(selected.transcriptScrollTargetSegmentID)
  }

  func testSelectingOlderBufferedResultRefreshesFocusedTimelineAndReturnsSeekTarget() throws {
    let fixture = try makeFixture()
    let searchStore = StreamAppSearchStore(database: fixture.temporary.database)
    let timelineStore = StreamAppTimelineStore(database: fixture.temporary.database)
    var viewModel = makeViewModel(fixture: fixture)
    viewModel.updateSearchDraft(StreamAppSearchDraft(phrase: "alpha beta", limit: 10))
    let snapshot = try viewModel.runSearch(
      using: searchStore, refreshedAt: "2026-05-01T18:12:00Z")
    let olderBufferedResult = try XCTUnwrap(snapshot.results.first { $0.sequence == 1 })

    let action = try viewModel.selectSearchResult(
      id: olderBufferedResult.id,
      using: timelineStore,
      refreshedAt: "2026-05-01T18:12:10Z"
    )

    XCTAssertTrue(action.shouldSeek)
    XCTAssertEqual(action.seekSeconds, 10)
    let selected = try XCTUnwrap(viewModel.selectedStream)
    XCTAssertEqual(selected.selectedSearchResultID, olderBufferedResult.id)
    XCTAssertEqual(selected.selectedSearchSegmentID, olderBufferedResult.segmentID)
    XCTAssertEqual(selected.transcriptScrollTargetSegmentID, olderBufferedResult.segmentID)
    XCTAssertEqual(selected.transcriptScrollTargetID, "transcript:\(olderBufferedResult.segmentID)")
    XCTAssertEqual(selected.timelineDiagnostics?.focusedSegmentID, olderBufferedResult.segmentID)
    XCTAssertTrue(
      selected.recentTranscriptParagraphs.contains { $0.id == olderBufferedResult.segmentID })
    XCTAssertEqual(selected.searchJumpMessage, "Search result selected at 10s.")
  }

  func testSelectingUnbufferedResultRefreshesAndDeniesSeekWithVisibleMessage() throws {
    let fixture = try makeFixture()
    let searchStore = StreamAppSearchStore(database: fixture.temporary.database)
    let timelineStore = StreamAppTimelineStore(database: fixture.temporary.database)
    var viewModel = makeViewModel(fixture: fixture)
    viewModel.updateSearchDraft(StreamAppSearchDraft(phrase: "alpha beta", limit: 10))
    let snapshot = try viewModel.runSearch(
      using: searchStore, refreshedAt: "2026-05-01T18:13:00Z")
    let unbufferedResult = try XCTUnwrap(snapshot.results.first { $0.sequence == 3 })

    let action = try viewModel.selectSearchResult(
      id: unbufferedResult.id,
      using: timelineStore,
      refreshedAt: "2026-05-01T18:13:10Z"
    )

    XCTAssertFalse(action.shouldSeek)
    XCTAssertNil(action.seekSeconds)
    XCTAssertTrue(try XCTUnwrap(action.message).contains("outside the current playback buffer"))
    let selected = try XCTUnwrap(viewModel.selectedStream)
    XCTAssertEqual(selected.selectedSearchResultID, unbufferedResult.id)
    XCTAssertEqual(selected.transcriptScrollTargetSegmentID, unbufferedResult.segmentID)
    XCTAssertTrue(
      try XCTUnwrap(selected.searchJumpMessage).contains("outside the current playback buffer"))
  }

  func testSearchErrorsAreRedactedAndPreserveLastGoodSelectionAndTimeline() throws {
    let fixture = try makeFixture()
    let searchStore = StreamAppSearchStore(database: fixture.temporary.database)
    let timelineStore = StreamAppTimelineStore(database: fixture.temporary.database)
    var viewModel = makeViewModel(fixture: fixture)
    viewModel.updateSearchDraft(StreamAppSearchDraft(phrase: "alpha beta", limit: 10))
    let snapshot = try viewModel.runSearch(
      using: searchStore, refreshedAt: "2026-05-01T18:14:00Z")
    let result = try XCTUnwrap(snapshot.results.first { $0.sequence == 1 })
    _ = try viewModel.selectSearchResult(
      id: result.id, using: timelineStore, refreshedAt: "2026-05-01T18:14:10Z")

    viewModel.updateSearchDraft(StreamAppSearchDraft(phrase: " ", limit: 10))
    XCTAssertThrowsError(
      try viewModel.runSearch(using: searchStore, refreshedAt: "2026-05-01T18:14:20Z")
    ) { error in
      XCTAssertEqual(error as? StreamAppSearchStoreError, .emptyPhrase)
    }

    let selected = try XCTUnwrap(viewModel.selectedStream)
    XCTAssertEqual(selected.searchErrorMessage, "Search phrase must not be empty.")
    XCTAssertEqual(selected.selectedSearchResultID, result.id)
    XCTAssertEqual(selected.timelineDiagnostics?.focusedSegmentID, result.segmentID)
    XCTAssertFalse(String(describing: viewModel).contains("token=main-secret"))
  }

  func testTimelineFailureDuringJumpPreservesLastGoodTimelineAndRedactsMessage() throws {
    let fixture = try makeFixture()
    let searchStore = StreamAppSearchStore(database: fixture.temporary.database)
    let timelineStore = StreamAppTimelineStore(database: fixture.temporary.database)
    var viewModel = makeViewModel(fixture: fixture)
    viewModel.updateSearchDraft(StreamAppSearchDraft(phrase: "alpha beta", limit: 10))
    let snapshot = try viewModel.runSearch(
      using: searchStore, refreshedAt: "2026-05-01T18:15:00Z")
    let result = try XCTUnwrap(snapshot.results.first { $0.sequence == 1 })
    _ = try viewModel.selectSearchResult(
      id: result.id, using: timelineStore, refreshedAt: "2026-05-01T18:15:10Z")
    let lastGoodParagraphs = viewModel.selectedStream?.recentTranscriptParagraphs

    let failingStore = StreamAppTimelineStore(database: try TemporarySoundingDatabase().database)
    XCTAssertThrowsError(
      try viewModel.selectSearchResult(
        id: result.id, using: failingStore, refreshedAt: "2026-05-01T18:15:20Z")
    ) { error in
      XCTAssertEqual(error as? StreamAppTimelineStoreError, .streamNotFound)
    }

    let selected = try XCTUnwrap(viewModel.selectedStream)
    XCTAssertEqual(selected.recentTranscriptParagraphs, lastGoodParagraphs)
    XCTAssertEqual(selected.searchJumpMessage, "The selected stream was not found.")
  }

  func testPlayerTimelineChangesRefreshSearchSeekabilityAndSelectionChangeClearsJumpTarget() throws
  {
    let fixture = try makeFixture()
    let searchStore = StreamAppSearchStore(database: fixture.temporary.database)
    var viewModel = makeViewModel(fixture: fixture)
    viewModel.updateSearchDraft(StreamAppSearchDraft(phrase: "alpha beta", limit: 10))
    var snapshot = try viewModel.runSearch(
      using: searchStore, refreshedAt: "2026-05-01T18:16:00Z")
    XCTAssertFalse(try XCTUnwrap(snapshot.results.first { $0.sequence == 3 }).isSeekable)

    viewModel = StreamAppViewModel(
      streams: [fixture.mainItem, fixture.otherItem],
      selectedStreamID: fixture.mainItem.id,
      playerTimelines: [
        fixture.mainItem.id: AppPlayerTimelineSnapshot(
          streamID: fixture.mainItem.id,
          positionSeconds: 30,
          liveEdgeSeconds: 45,
          bufferedStartSeconds: 0,
          bufferedEndSeconds: 40
        )
      ],
      searchDraft: viewModel.searchDraft,
      searchSnapshot: viewModel.searchSnapshot,
      selectedSearchResultID: snapshot.results.first?.id,
      selectedSearchSegmentID: snapshot.results.first?.segmentID,
      transcriptScrollTargetSegmentID: snapshot.results.first?.segmentID
    )
    viewModel.refreshSearchSeekability()
    snapshot = try XCTUnwrap(viewModel.selectedStream?.searchSnapshot)
    XCTAssertTrue(try XCTUnwrap(snapshot.results.first { $0.sequence == 3 }).isSeekable)

    viewModel.selectedStreamID = fixture.otherItem.id
    XCTAssertNil(viewModel.selectedStream?.selectedSearchResultID)
    XCTAssertNil(viewModel.selectedStream?.transcriptScrollTargetSegmentID)
  }

  private struct Fixture {
    var temporary: TemporarySoundingDatabase
    var mainItem: StreamAppListItem
    var otherItem: StreamAppListItem
  }

  private func makeViewModel(fixture: Fixture) -> StreamAppViewModel {
    StreamAppViewModel(
      streams: [fixture.mainItem, fixture.otherItem],
      selectedStreamID: fixture.mainItem.id,
      playerTimelines: [
        fixture.mainItem.id: AppPlayerTimelineSnapshot(
          streamID: fixture.mainItem.id,
          positionSeconds: 12,
          liveEdgeSeconds: 45,
          bufferedStartSeconds: 0,
          bufferedEndSeconds: 20
        )
      ]
    )
  }

  private func makeFixture() throws -> Fixture {
    let temporary = try TemporarySoundingDatabase()
    let registry = StreamRegistry(database: temporary.database)
    let main = try registry.add(
      name: "Search VM Main",
      streamType: "hls",
      source: "https://example.test/main.m3u8?token=main-secret",
      createdAt: "2026-05-01T18:00:00Z"
    )
    let other = try registry.add(
      name: "Search VM Other",
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
          segment(1, "host", 10, 14, "Alpha beta buffered"),
          segment(2, "guest", 15, 18, "context after only"),
          segment(3, "host", 30, 34, "late alpha beta unbuffered"),
        ],
        speakerTurns: [
          SpeakerTurnDraft(speakerLabel: "guest", startSeconds: 0, endSeconds: 8, confidence: 0.8),
          SpeakerTurnDraft(speakerLabel: "host", startSeconds: 10, endSeconds: 14, confidence: 0.9),
          SpeakerTurnDraft(
            speakerLabel: "guest", startSeconds: 15, endSeconds: 18, confidence: 0.8),
          SpeakerTurnDraft(speakerLabel: "host", startSeconds: 30, endSeconds: 34, confidence: 0.9),
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
      mainItem: StreamAppListItem(record: main),
      otherItem: StreamAppListItem(record: other)
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
      words: text.split(separator: " ").enumerated().map { index, word in
        TranscriptWordDraft(
          sequence: index,
          speakerLabel: speakerLabel,
          startSeconds: startSeconds + Double(index),
          endSeconds: startSeconds + Double(index) + 0.5,
          text: String(word),
          confidence: 0.88
        )
      }
    )
  }
}
