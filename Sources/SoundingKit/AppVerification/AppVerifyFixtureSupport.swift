import Foundation
import GRDB

actor AppVerifyRuntimeEventRecorder {
  private var events: [AppStreamRuntimeEvent] = []

  func append(_ event: AppStreamRuntimeEvent) {
    events.append(event)
  }

  func count(streamID: Int64, phase: AppStreamRuntimeStatusPhase) -> Int {
    events.filter { $0.streamID == streamID && $0.phase.statusPhase == phase }.count
  }

  func snapshot() -> [AppStreamRuntimeEvent] {
    events
  }
}

struct AppVerifyCollectedRuntime: Sendable {
  var events: [AppStreamRuntimeEvent]
  var terminalEvent: AppStreamRuntimeEvent
}

struct AppVerifyRunnerTimeoutError: Error, CustomStringConvertible, Sendable {
  var phase: String
  var description: String { "Timed out waiting for \(phase)." }
}

struct AppVerifyFixtureAdMarkerDecoratingDecoder: AudioDecoding {
  var upstream: any AudioDecoding
  var timestamp: @Sendable () -> String

  func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
    var chunks = try await upstream.decodedChunks(for: request)
    guard !chunks.isEmpty else { return chunks }
    let index = chunks.startIndex
    let first = chunks[index]
    let markerPTS = first.startSeconds.isFinite ? first.startSeconds : 0
    let marker = AdMarker(
      type: "app_verify_fixture_splice_insert",
      classification: .adStart,
      source: "app_verify_fixture",
      pts: max(0, markerPTS),
      segment: "app-verify-fixture",
      timestamp: timestamp()
    )
    chunks[index].adMarkers.append(marker)
    return chunks
  }
}

struct AppVerifyFixtureProjectionProbe: Sendable {
  var checks: [AppVerifyCheckRecord]

  static func collect(
    database: SoundingDatabase,
    streamID: Int64,
    timeline: AppPlayerTimelineSnapshot,
    refreshedAt: String,
    diagnosticEvents: [String]
  ) throws -> AppVerifyFixtureProjectionProbe {
    let counts = try AppVerifyFixtureProjectionCounts.fetch(database: database, streamID: streamID)
    let timelineSnapshot = try StreamAppTimelineStore(database: database).snapshot(
      request: StreamAppTimelineRequest(
        streamID: streamID,
        player: timeline,
        paragraphLimit: 10,
        wordLimitPerParagraph: 10,
        metadataLimit: 10,
        timelineLimit: 20,
        lookbackSeconds: nil,
        refreshedAt: refreshedAt
      )
    )
    let searchSnapshot = try StreamAppSearchStore(database: database).snapshot(
      request: StreamAppSearchRequest(
        phrase: "app verify fixture",
        streamIDs: [streamID],
        limit: 10,
        contextSegments: 1,
        player: timeline,
        refreshedAt: refreshedAt
      )
    )

    let transcriptTimelineItems = timelineSnapshot.timelineItems.filter { $0.kind == .transcript }
      .count
    let songMetadataItems = timelineSnapshot.recentMetadata.filter { $0.kind == .song }.count
    let songTimelineItems = timelineSnapshot.timelineItems.filter { $0.kind == .song }.count
    let adMetadataItems = timelineSnapshot.recentMetadata.filter { $0.kind == .event }.count
    let adTimelineItems = timelineSnapshot.timelineItems.filter { $0.kind == .event }.count

    return AppVerifyFixtureProjectionProbe(checks: [
      AppVerifyCheckEvaluator.projectionPopulated(
        .transcriptPersistence,
        surface: "transcript persistence",
        rowCount: min(counts.transcriptSegments, counts.transcriptWords, counts.transcriptFTSRows),
        sampleFields: [
          "segments": String(counts.transcriptSegments),
          "words": String(counts.transcriptWords),
          "ftsRows": String(counts.transcriptFTSRows),
        ],
        diagnosticEvents: diagnosticEvents
      ),
      AppVerifyCheckEvaluator.projectionPopulated(
        .transcriptTimelineProjection,
        surface: "transcript timeline",
        rowCount: counts.transcriptSegments,
        projectionCount: min(timelineSnapshot.transcriptParagraphs.count, transcriptTimelineItems),
        sampleFields: [
          "paragraphs": String(timelineSnapshot.transcriptParagraphs.count),
          "timelineTranscriptItems": String(transcriptTimelineItems),
          "speakers": String(timelineSnapshot.speakers.count),
        ],
        diagnosticEvents: diagnosticEvents
      ),
      AppVerifyCheckEvaluator.projectionPopulated(
        .transcriptSearchProjection,
        surface: "transcript search",
        rowCount: counts.transcriptFTSRows,
        projectionCount: searchSnapshot.results.count,
        sampleFields: [
          "phrase": "app verify fixture",
          "results": String(searchSnapshot.results.count),
          "status": searchSnapshot.diagnostics.status.title,
        ],
        diagnosticEvents: diagnosticEvents
      ),
      AppVerifyCheckEvaluator.projectionPopulated(
        .songMetadataProjection,
        surface: "song metadata",
        rowCount: counts.songRows,
        metadataCount: min(
          counts.songRows, counts.songPlays, max(songMetadataItems, songTimelineItems)),
        sampleFields: [
          "songRows": String(counts.songRows),
          "songPlays": String(counts.songPlays),
          "timelineSongItems": String(songTimelineItems),
          "recentSongMetadata": String(songMetadataItems),
        ],
        diagnosticEvents: diagnosticEvents
      ),
      AppVerifyCheckEvaluator.projectionPopulated(
        .adMetadataProjection,
        surface: "ad metadata",
        rowCount: counts.adEvents,
        metadataCount: min(counts.adEventsWithPTS, max(adMetadataItems, adTimelineItems)),
        sampleFields: [
          "adEvents": String(counts.adEvents),
          "adEventsWithPTS": String(counts.adEventsWithPTS),
          "timelineAdItems": String(adTimelineItems),
          "recentAdMetadata": String(adMetadataItems),
        ],
        diagnosticEvents: diagnosticEvents
      ),
    ])
  }
}

struct AppVerifyFixtureProjectionCounts: Sendable {
  var transcriptSegments: Int
  var transcriptWords: Int
  var transcriptFTSRows: Int
  var songRows: Int
  var songPlays: Int
  var adEvents: Int
  var adEventsWithPTS: Int

  static func fetch(database: SoundingDatabase, streamID: Int64) throws
    -> AppVerifyFixtureProjectionCounts
  {
    try database.read { db in
      AppVerifyFixtureProjectionCounts(
        transcriptSegments: try count(
          db,
          sql: """
            SELECT COUNT(*)
            FROM transcript_segments
            JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
            WHERE ingest_runs.stream_id = ?
            """,
          streamID: streamID
        ),
        transcriptWords: try count(
          db,
          sql: """
            SELECT COUNT(*)
            FROM transcript_words
            JOIN transcript_segments ON transcript_segments.id = transcript_words.segment_id
            JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
            WHERE ingest_runs.stream_id = ?
            """,
          streamID: streamID
        ),
        transcriptFTSRows: try count(
          db,
          sql: """
            SELECT COUNT(*)
            FROM transcript_segments_fts
            JOIN transcript_segments ON transcript_segments.id = transcript_segments_fts.rowid
            JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
            WHERE ingest_runs.stream_id = ?
            """,
          streamID: streamID
        ),
        songRows: try count(
          db,
          sql: """
            SELECT COUNT(DISTINCT songs.id)
            FROM songs
            JOIN song_plays ON song_plays.song_id = songs.id
            WHERE song_plays.stream_id = ?
            """,
          streamID: streamID
        ),
        songPlays: try count(
          db,
          sql: "SELECT COUNT(*) FROM song_plays WHERE stream_id = ?",
          streamID: streamID
        ),
        adEvents: try count(
          db,
          sql: """
            SELECT COUNT(*)
            FROM ad_events
            JOIN ingest_runs ON ingest_runs.id = ad_events.run_id
            WHERE ingest_runs.stream_id = ?
            """,
          streamID: streamID
        ),
        adEventsWithPTS: try count(
          db,
          sql: """
            SELECT COUNT(*)
            FROM ad_events
            JOIN ingest_runs ON ingest_runs.id = ad_events.run_id
            WHERE ingest_runs.stream_id = ?
              AND ad_events.pts IS NOT NULL
            """,
          streamID: streamID
        )
      )
    }
  }

  private static func count(_ db: Database, sql: String, streamID: Int64) throws -> Int {
    try Int.fetchOne(db, sql: sql, arguments: [streamID]) ?? 0
  }
}

struct AppVerifyDiagnosticsSnapshot: Sendable {
  var eventFileExists: Bool
  var errorFileExists: Bool
  var eventEntries: [AppVerifyParsedDiagnosticEntry]
  var errorEntries: [AppVerifyParsedDiagnosticEntry]
  var malformedLineCount: Int

  var eventNames: [String] {
    eventEntries.map(\.event)
  }

  var errorNames: [String] {
    errorEntries.map(\.event)
  }

  var recentNames: [String] {
    Array((eventNames + errorNames).suffix(32))
  }

  var recentEntries: [AppVerifyParsedDiagnosticEntry] {
    Array((eventEntries + errorEntries).suffix(32))
  }
}

struct AppVerifyRawDiagnosticEntry: Decodable {
  var event: String
  var phase: String?
  var streamID: Int64?
  var message: String?
  var fields: [String: String]?
}

struct AppVerifyDeterministicTranscriber: MLTranscription {
  func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
    [
      TranscriptSegmentDraft(
        sequence: chunk.sequence,
        startSeconds: chunk.startSeconds,
        endSeconds: chunk.endSeconds,
        text: "app verify fixture chunk \(chunk.sequence)",
        confidence: 1,
        words: [
          TranscriptWordDraft(
            sequence: 0,
            speakerLabel: "fixture-speaker",
            startSeconds: chunk.startSeconds,
            endSeconds: min(chunk.endSeconds, chunk.startSeconds + 0.25),
            text: "app",
            confidence: 1
          ),
          TranscriptWordDraft(
            sequence: 1,
            speakerLabel: "fixture-speaker",
            startSeconds: min(chunk.endSeconds, chunk.startSeconds + 0.25),
            endSeconds: min(chunk.endSeconds, chunk.startSeconds + 0.50),
            text: "verify",
            confidence: 1
          ),
          TranscriptWordDraft(
            sequence: 2,
            speakerLabel: "fixture-speaker",
            startSeconds: min(chunk.endSeconds, chunk.startSeconds + 0.50),
            endSeconds: chunk.endSeconds,
            text: "fixture",
            confidence: 1
          ),
        ]
      )
    ]
  }
}

struct AppVerifyDeterministicDiarizer: SpeakerDiarization {
  func diarize(
    _ chunk: DecodedAudioChunk,
    transcriptSegments: [TranscriptSegmentDraft]
  ) async throws -> [SpeakerTurnDraft] {
    [
      SpeakerTurnDraft(
        speakerLabel: "fixture-speaker",
        startSeconds: chunk.startSeconds,
        endSeconds: chunk.endSeconds,
        confidence: 1
      )
    ]
  }
}
