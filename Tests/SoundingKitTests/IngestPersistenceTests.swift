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

    func testActiveAdBreakExpiresAfterDeclaredIcyDuration() throws {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)
        let streamID = try writer.createStream(
            streamType: "icy",
            source: "https://example.test/radio",
            createdAt: "2026-04-30T12:00:00Z"
        )
        let runID = try writer.createRun(
            streamID: streamID,
            startedAt: "2026-04-30T12:00:01Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 0,
            startedAt: "2026-04-30T12:00:02Z"
        )

        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                adMarkers: [
                    AdMarker(
                        type: "ICY",
                        classification: .adStart,
                        source: "icy_stream",
                        pts: 0,
                        fields: ["durationMilliseconds": .string("30000")]
                    )
                ],
                createdAt: "2026-04-30T12:00:03Z"
            )
        )

        XCTAssertTrue(try writer.activeAdBreakOverlaps(streamID: streamID, startSeconds: 10, endSeconds: 20))
        XCTAssertTrue(try writer.activeAdBreakOverlaps(streamID: streamID, startSeconds: 29, endSeconds: 35))
        XCTAssertFalse(try writer.activeAdBreakOverlaps(streamID: streamID, startSeconds: 36, endSeconds: 46))
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

    func testHLSSegmentClaimClaimsFirstSegmentAndFinalizesChunkLink() throws {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)
        let streamID = try writer.createStream(streamType: "hls", source: "https://example.test/live.m3u8", createdAt: "2026-05-01T10:00:00Z")
        let runID = try writer.createRun(streamID: streamID, startedAt: "2026-05-01T10:00:01Z", status: .running)

        let result = try writer.claimHLSSegment(
            HLSSegmentClaim(
                streamID: streamID,
                runID: runID,
                mediaSequence: 7,
                segmentIdentity: "https://cdn.example.test/seg-7.ts?token=secret#frag",
                claimedAt: "2026-05-01T10:00:02Z"
            )
        )
        XCTAssertEqual(result, .claimed(diagnostics: []))
        XCTAssertEqual(try writer.lastPersistedHLSMediaSequence(streamID: streamID), 7)

        let chunkID = try writer.createChunk(runID: runID, sequence: 0, startedAt: "2026-05-01T10:00:03Z")
        try writer.finalizeHLSSegmentClaim(
            streamID: streamID,
            mediaSequence: 7,
            runID: runID,
            chunkID: chunkID,
            finalizedAt: "2026-05-01T10:00:04Z"
        )

        let row = try temporary.database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT segment_identity, segment_identity_hash, claimed_run_id, chunk_id, finalized_at
                FROM hls_ingest_segments
                WHERE stream_id = ? AND media_sequence = 7
                """, arguments: [streamID])
        }
        XCTAssertEqual(row?["segment_identity"] as String?, "https://cdn.example.test/seg-7.ts")
        XCTAssertNotNil(row?["segment_identity_hash"] as String?)
        XCTAssertEqual(row?["claimed_run_id"] as Int64?, runID)
        XCTAssertEqual(row?["chunk_id"] as Int64?, chunkID)
        XCTAssertEqual(row?["finalized_at"] as String?, "2026-05-01T10:00:04Z")
    }

    func testHLSSegmentClaimClassifiesMalformedDuplicateGapAndConflictWithRedactedDiagnostics() throws {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)
        let streamID = try writer.createStream(streamType: "hls", source: "https://example.test/live.m3u8", createdAt: "2026-05-01T10:00:00Z")
        let firstRunID = try writer.createRun(streamID: streamID, startedAt: "2026-05-01T10:00:01Z", status: .running)
        let secondRunID = try writer.createRun(streamID: streamID, startedAt: "2026-05-01T10:01:01Z", status: .running)

        XCTAssertEqual(try writer.claimHLSSegment(nil), .noClaim)
        XCTAssertEqual(
            try writer.claimHLSSegment(
                HLSSegmentClaim(streamID: streamID, runID: firstRunID, mediaSequence: -1, segmentIdentity: "seg", claimedAt: "2026-05-01T10:00:01Z")
            ),
            .noClaim
        )

        _ = try writer.claimHLSSegment(
            HLSSegmentClaim(
                streamID: streamID,
                runID: firstRunID,
                mediaSequence: 7,
                segmentIdentity: "https://cdn.example.test/seg-7.ts?token=first-secret#fragment",
                claimedAt: "2026-05-01T10:00:02Z"
            )
        )
        let chunkID = try writer.createChunk(runID: firstRunID, sequence: 0, startedAt: "2026-05-01T10:00:03Z")
        try writer.finalizeHLSSegmentClaim(streamID: streamID, mediaSequence: 7, runID: firstRunID, chunkID: chunkID, finalizedAt: "2026-05-01T10:00:04Z")

        let duplicate = try writer.claimHLSSegment(
            HLSSegmentClaim(
                streamID: streamID,
                runID: secondRunID,
                mediaSequence: 7,
                segmentIdentity: "https://cdn.example.test/seg-7.ts?token=second-secret#other",
                claimedAt: "2026-05-01T10:01:02Z"
            )
        )
        guard case let .duplicate(existingRunID, existingChunkID, duplicateDiagnostic) = duplicate else {
            return XCTFail("Expected duplicate skip classification, got \(duplicate)")
        }
        XCTAssertEqual(existingRunID, firstRunID)
        XCTAssertEqual(existingChunkID, chunkID)
        XCTAssertEqual(duplicateDiagnostic.severity, .info)
        XCTAssertEqual(duplicateDiagnostic.reason, "hls-segment-duplicate")

        let gap = try writer.claimHLSSegment(
            HLSSegmentClaim(
                streamID: streamID,
                runID: secondRunID,
                mediaSequence: 10,
                segmentIdentity: "https://cdn.example.test/seg-10.ts?api_key=gap-secret",
                claimedAt: "2026-05-01T10:01:03Z"
            )
        )
        guard case let .claimed(gapDiagnostics) = gap else {
            return XCTFail("Expected gap claim classification, got \(gap)")
        }
        XCTAssertEqual(gapDiagnostics.map(\.reason), ["hls-media-sequence-gap"])
        XCTAssertEqual(gapDiagnostics.first?.severity, .warning)

        let reset = try writer.claimHLSSegment(
            HLSSegmentClaim(
                streamID: streamID,
                runID: secondRunID,
                mediaSequence: 7,
                segmentIdentity: "https://cdn.example.test/changed-7.ts?password=conflict-secret",
                claimedAt: "2026-05-01T10:01:04Z"
            )
        )
        guard case let .claimed(resetDiagnostics) = reset else {
            return XCTFail("Expected sequence reset claim classification, got \(reset)")
        }
        XCTAssertEqual(resetDiagnostics.map(\.reason), ["hls-media-sequence-reset"])
        XCTAssertEqual(resetDiagnostics.first?.severity, .warning)

        let diagnostics = try temporary.database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT severity, reason, context_json
                FROM ingest_diagnostics
                WHERE reason LIKE 'hls-%'
                ORDER BY id
                """)
        }
        XCTAssertEqual(diagnostics.map { $0["reason"] as String? }, [
            "hls-segment-duplicate",
            "hls-media-sequence-gap",
            "hls-media-sequence-reset"
        ])
        XCTAssertEqual(diagnostics.map { $0["severity"] as String? }, ["info", "warning", "warning"])
        let contexts = diagnostics.compactMap { $0["context_json"] as String? }.joined(separator: "\n")
        XCTAssertTrue(contexts.contains("mediaSequence"))
        XCTAssertTrue(contexts.contains("expectedMediaSequence"))
        XCTAssertTrue(contexts.contains("existingChunkID"))
        XCTAssertFalse(contexts.contains("first-secret"))
        XCTAssertFalse(contexts.contains("second-secret"))
        XCTAssertFalse(contexts.contains("gap-secret"))
        XCTAssertFalse(contexts.contains("conflict-secret"))
        XCTAssertFalse(contexts.contains("token="))
        XCTAssertFalse(contexts.contains("api_key="))
        XCTAssertFalse(contexts.contains("password="))

        let currentClaim = try temporary.database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT segment_identity, claimed_run_id, chunk_id, finalized_at
                FROM hls_ingest_segments
                WHERE stream_id = ? AND media_sequence = 7
                """, arguments: [streamID])
        }
        XCTAssertEqual(currentClaim?["segment_identity"] as String?, "https://cdn.example.test/changed-7.ts")
        XCTAssertEqual(currentClaim?["claimed_run_id"] as Int64?, secondRunID)
        XCTAssertNil(currentClaim?["chunk_id"] as Int64?)
        XCTAssertNil(currentClaim?["finalized_at"] as String?)
    }

    func testHLSSegmentAbandonUnfinalizedClaimAllowsRetryWithoutDuplicateClassification() throws {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)
        let streamID = try writer.createStream(streamType: "hls", source: "https://example.test/live.m3u8", createdAt: "2026-05-01T10:00:00Z")
        let runID = try writer.createRun(streamID: streamID, startedAt: "2026-05-01T10:00:01Z", status: .running)

        let first = try writer.claimHLSSegment(
            HLSSegmentClaim(
                streamID: streamID,
                runID: runID,
                mediaSequence: 11,
                segmentIdentity: "https://cdn.example.test/seg-11.ts?token=secret",
                claimedAt: "2026-05-01T10:00:02Z"
            )
        )
        XCTAssertEqual(first, .claimed(diagnostics: []))

        try writer.abandonUnfinalizedHLSSegmentClaim(
            streamID: streamID,
            mediaSequence: 11,
            runID: runID
        )

        let retry = try writer.claimHLSSegment(
            HLSSegmentClaim(
                streamID: streamID,
                runID: runID,
                mediaSequence: 11,
                segmentIdentity: "https://cdn.example.test/seg-11.ts?token=other",
                claimedAt: "2026-05-01T10:00:03Z"
            )
        )
        XCTAssertEqual(retry, .claimed(diagnostics: []))
        let rows = try temporary.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hls_ingest_segments WHERE stream_id = ? AND media_sequence = 11", arguments: [streamID])
        }
        XCTAssertEqual(rows, 1)
    }

    func testHLSSegmentFinalizeFailureDoesNotLeavePartialChunkLink() throws {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)
        let streamID = try writer.createStream(streamType: "hls", source: "https://example.test/live.m3u8", createdAt: "2026-05-01T10:00:00Z")
        let runID = try writer.createRun(streamID: streamID, startedAt: "2026-05-01T10:00:01Z", status: .running)
        _ = try writer.claimHLSSegment(
            HLSSegmentClaim(streamID: streamID, runID: runID, mediaSequence: 1, segmentIdentity: "seg-1.ts", claimedAt: "2026-05-01T10:00:02Z")
        )

        XCTAssertThrowsError(
            try writer.finalizeHLSSegmentClaim(
                streamID: streamID,
                mediaSequence: 1,
                runID: runID,
                chunkID: 99_999,
                finalizedAt: "2026-05-01T10:00:03Z"
            )
        )
        XCTAssertThrowsError(
            try writer.finalizeHLSSegmentClaim(
                streamID: streamID,
                mediaSequence: 99,
                runID: runID,
                chunkID: 99_999,
                finalizedAt: "2026-05-01T10:00:04Z"
            )
        )

        let row = try temporary.database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT chunk_id, finalized_at
                FROM hls_ingest_segments
                WHERE stream_id = ? AND media_sequence = 1
                """, arguments: [streamID])
        }
        XCTAssertNil(row?["chunk_id"] as Int64?)
        XCTAssertNil(row?["finalized_at"] as String?)
    }

}
