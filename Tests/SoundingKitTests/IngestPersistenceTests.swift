import GRDB
import XCTest
@testable import SoundingKit

final class IngestPersistenceTests: XCTestCase {
    func testPersistsCompleteIngestTimelineWithTranscriptSpeakersMarkersAndDiagnostics() throws {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)

        let streamID = try writer.createStream(
            streamType: "hls",
            source: "https://example.test/live.m3u8",
            createdAt: "2026-04-30T12:00:00Z"
        )
        let runID = try writer.createRun(
            streamID: streamID,
            startedAt: "2026-04-30T12:00:01Z",
            status: .running,
            context: ["proof": true]
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 0,
            segmentURI: "segment-000.ts?token=<redacted>",
            byteCount: 4096,
            startedAt: "2026-04-30T12:00:02Z",
            endedAt: "2026-04-30T12:00:04Z",
            context: ["duration": 2.0]
        )

        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                segments: [
                    TranscriptSegmentDraft(
                        sequence: 0,
                        speakerLabel: "speaker-1",
                        startSeconds: 0.0,
                        endSeconds: 1.2,
                        text: "hello world",
                        confidence: 0.91,
                        words: [
                            TranscriptWordDraft(sequence: 0, speakerLabel: "speaker-1", startSeconds: 0.0, endSeconds: 0.5, text: "hello", confidence: 0.92),
                            TranscriptWordDraft(sequence: 1, speakerLabel: "speaker-1", startSeconds: 0.6, endSeconds: 1.2, text: "world", confidence: 0.90)
                        ]
                    )
                ],
                speakerTurns: [
                    SpeakerTurnDraft(speakerLabel: "speaker-1", startSeconds: 0.0, endSeconds: 1.2, confidence: 0.86)
                ],
                adMarkers: [
                    AdMarker(
                        type: "SCTE35",
                        classification: .adStart,
                        source: "hls_segment",
                        pts: 12.5,
                        segment: "segment-000.ts",
                        rawBase64: "AAAAAQ==",
                        fields: ["SourceClass": "hls_segment"],
                        timestamp: "2026-04-30T12:00:03Z"
                    )
                ],
                diagnostics: [
                    IngestDiagnosticDraft(
                        streamID: streamID,
                        phase: .transcribe,
                        severity: .warning,
                        reason: "recoverable-provider-warning",
                        source: "https://example.test/live.m3u8",
                        sourceClass: "hls_manifest",
                        streamType: "hls",
                        context: ["detail": "redacted"],
                        createdAt: "2026-04-30T12:00:04Z"
                    )
                ],
                createdAt: "2026-04-30T12:00:05Z"
            )
        )
        try writer.finishRun(runID: runID, endedAt: "2026-04-30T12:01:00Z", status: .completed)

        let counts = try temporary.database.read { db in
            try [
                "streams": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM streams"),
                "ingest_runs": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_runs WHERE status = 'completed'"),
                "ingest_chunks": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_chunks"),
                "transcript_segments": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments"),
                "transcript_words": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_words"),
                "speaker_turns": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_turns"),
                "ad_events": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ad_events"),
                "ingest_diagnostics": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_diagnostics"),
                "transcript_segments_fts": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments_fts WHERE transcript_segments_fts MATCH 'hello'")
            ]
        }

        XCTAssertEqual(counts, [
            "streams": 1,
            "ingest_runs": 1,
            "ingest_chunks": 1,
            "transcript_segments": 1,
            "transcript_words": 2,
            "speaker_turns": 1,
            "ad_events": 1,
            "ingest_diagnostics": 1,
            "transcript_segments_fts": 1
        ])
    }

    func testZeroTranscriptRowsForAChunkIsAllowed() throws {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)
        let streamID = try writer.createStream(streamType: "icy", source: "https://example.test/radio", createdAt: "2026-04-30T12:00:00Z")
        let runID = try writer.createRun(streamID: streamID, startedAt: "2026-04-30T12:00:01Z", status: .running)
        let chunkID = try writer.createChunk(runID: runID, sequence: 0, startedAt: "2026-04-30T12:00:02Z")

        try writer.persistTimeline(IngestChunkTimeline(runID: runID, chunkID: chunkID, createdAt: "2026-04-30T12:00:03Z"))

        let counts = try temporary.database.read { db in
            try [
                "chunks": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_chunks"),
                "segments": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments"),
                "words": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_words"),
                "turns": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_turns")
            ]
        }
        XCTAssertEqual(counts, ["chunks": 1, "segments": 0, "words": 0, "turns": 0])
    }

    func testDuplicateChunkSequencesAreRejected() throws {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)
        let streamID = try writer.createStream(streamType: "hls", source: "https://example.test/live", createdAt: "2026-04-30T12:00:00Z")
        let runID = try writer.createRun(streamID: streamID, startedAt: "2026-04-30T12:00:01Z", status: .running)
        _ = try writer.createChunk(runID: runID, sequence: 7, startedAt: "2026-04-30T12:00:02Z")

        XCTAssertThrowsError(try writer.createChunk(runID: runID, sequence: 7, startedAt: "2026-04-30T12:00:03Z"))
    }

    func testBadForeignKeysAreRejected() throws {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)

        XCTAssertThrowsError(
            try writer.createRun(streamID: 99_999, startedAt: "2026-04-30T12:00:01Z", status: .running)
        )
        XCTAssertThrowsError(
            try writer.createChunk(runID: 99_999, sequence: 0, startedAt: "2026-04-30T12:00:02Z")
        )
    }

    func testTimelineTransactionRollsBackWhenAnyRowFails() throws {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)
        let streamID = try writer.createStream(streamType: "hls", source: "https://example.test/live", createdAt: "2026-04-30T12:00:00Z")
        let runID = try writer.createRun(streamID: streamID, startedAt: "2026-04-30T12:00:01Z", status: .running)
        let chunkID = try writer.createChunk(runID: runID, sequence: 0, startedAt: "2026-04-30T12:00:02Z")

        XCTAssertThrowsError(
            try writer.persistTimeline(
                IngestChunkTimeline(
                    runID: runID,
                    chunkID: chunkID,
                    segments: [
                        TranscriptSegmentDraft(
                            sequence: 0,
                            speakerLabel: "speaker-1",
                            startSeconds: 0,
                            endSeconds: 1,
                            text: "first segment",
                            confidence: 0.9,
                            words: [
                                TranscriptWordDraft(sequence: 0, speakerLabel: "speaker-1", startSeconds: 0, endSeconds: 0.5, text: "first", confidence: 0.9)
                            ]
                        ),
                        TranscriptSegmentDraft(
                            sequence: 0,
                            speakerLabel: "speaker-2",
                            startSeconds: 1,
                            endSeconds: 2,
                            text: "duplicate sequence should fail",
                            confidence: 0.8
                        )
                    ],
                    createdAt: "2026-04-30T12:00:03Z"
                )
            )
        )

        let counts = try temporary.database.read { db in
            try [
                "segments": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments"),
                "words": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_words"),
                "fts": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments_fts")
            ]
        }
        XCTAssertEqual(counts, ["segments": 0, "words": 0, "fts": 0])
    }
}
