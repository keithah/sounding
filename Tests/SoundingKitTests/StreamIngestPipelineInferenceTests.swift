import Foundation
import GRDB
import XCTest

@testable import SoundingKit

final class StreamIngestPipelineInferenceTests: StreamIngestPipelineTestCase {
    func testDiarizationTurnsAssignTranscriptSegmentAndWordSpeakersBeforePersistence() async throws {
        let temporary = try TemporarySoundingDatabase()
        let segments = [
            Self.segment(
                text: "first voice second voice",
                speakerLabel: "",
                startSeconds: 0,
                endSeconds: 4,
                words: ["first", "voice", "second", "voice"]
            )
        ]
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: PipelineFakeDecoder(chunks: [Self.chunk(sequence: 0)]),
            transcriber: PipelineFakeTranscriber(segmentsBySequence: [0: segments]),
            diarizer: PipelineFakeDiarizer(turnsBySequence: [
                0: [
                    SpeakerTurnDraft(speakerLabel: "speaker-S1", startSeconds: 0, endSeconds: 2, confidence: 0.9),
                    SpeakerTurnDraft(speakerLabel: "speaker-S2", startSeconds: 2, endSeconds: 4, confidence: 0.9),
                ]
            ])
        )

        _ = try await pipeline.run(
            source: "https://example.test/live", streamType: .icecast, maxChunks: 1)

        let labels = try temporary.database.read { db in
            try (
                segments: String.fetchAll(
                    db,
                    sql: "SELECT speaker_label || ':' || text FROM transcript_segments ORDER BY sequence"
                ),
                words: String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT speaker_label FROM transcript_words ORDER BY speaker_label"
                )
            )
        }
        XCTAssertEqual(labels.segments, ["speaker-S1:first voice", "speaker-S2:second voice"])
        XCTAssertEqual(labels.words, ["speaker-S1", "speaker-S2"])
    }

    func testSplitDiarizedSegmentsKeepUniqueSequencesAcrossMultipleChunks() async throws {
        let temporary = try TemporarySoundingDatabase()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: PipelineFakeDecoder(chunks: [Self.chunk(sequence: 0), Self.chunk(sequence: 1)]),
            transcriber: PipelineFakeTranscriber(segmentsBySequence: [
                0: [
                    Self.segment(
                        text: "one two three four",
                        speakerLabel: "",
                        startSeconds: 0,
                        endSeconds: 4,
                        words: ["one", "two", "three", "four"]
                    )
                ],
                1: [
                    Self.segment(
                        text: "five six seven eight",
                        speakerLabel: "",
                        startSeconds: 4,
                        endSeconds: 8,
                        words: ["five", "six", "seven", "eight"]
                    )
                ],
            ]),
            diarizer: PipelineFakeDiarizer(turnsBySequence: [
                0: [
                    SpeakerTurnDraft(speakerLabel: "speaker-S1", startSeconds: 0, endSeconds: 2, confidence: 0.9),
                    SpeakerTurnDraft(speakerLabel: "speaker-S2", startSeconds: 2, endSeconds: 4, confidence: 0.9),
                ],
                1: [
                    SpeakerTurnDraft(speakerLabel: "speaker-S1", startSeconds: 4, endSeconds: 6, confidence: 0.9),
                    SpeakerTurnDraft(speakerLabel: "speaker-S2", startSeconds: 6, endSeconds: 8, confidence: 0.9),
                ],
            ])
        )

        _ = try await pipeline.run(
            source: "https://example.test/live", streamType: .icecast, maxChunks: 2)

        let rows = try temporary.database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT sequence || ':' || speaker_label || ':' || text FROM transcript_segments ORDER BY sequence"
            )
        }
        XCTAssertEqual(
            rows,
            [
                "0:speaker-S1:one two",
                "1:speaker-S2:three four",
                "2:speaker-S1:five six",
                "3:speaker-S2:seven eight",
            ]
        )
    }

    func testTranscriberAndDiarizerFailuresPersistPhaseDiagnosticsAndCompleteRun() async throws {
        let temporary = try TemporarySoundingDatabase()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: PipelineFakeDecoder(chunks: [Self.chunk(sequence: 0)]),
            transcriber: PipelineFakeTranscriber(errorBySequence: [
                0: PipelineFakeIngestError("transcribe token=secret")
            ]),
            diarizer: PipelineFakeDiarizer(errorBySequence: [0: PipelineFakeIngestError("diarize password=secret")])
        )

        let result = try await pipeline.run(
            source: "https://example.test/live", streamType: .icecast, maxChunks: 1)

        XCTAssertEqual(result.processedChunks, 1)
        XCTAssertEqual(result.diagnostics.map(\.phase), [.transcribe, .diarize])
        let rows = try temporary.database.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT phase, severity, reason, context_json FROM ingest_diagnostics ORDER BY id"
            )
        }
        XCTAssertEqual(rows.map { $0["phase"] as String }, ["transcribe", "diarize"])
        XCTAssertEqual(rows.map { $0["severity"] as String }, ["error", "error"])
        XCTAssertEqual(
            rows.map { $0["reason"] as String }, ["transcription-failed", "diarization-failed"])
        for row in rows {
            let context: String = row["context_json"]
            XCTAssertFalse(context.contains("secret"), context)
        }
        let completed = try temporary.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_runs WHERE status = 'completed'")
        }
        XCTAssertEqual(completed, 1)
    }

    func testRecoverableProviderFailureLeavesLaterTranscriptQueryable() async throws {
        let temporary = try TemporarySoundingDatabase()
        let validSegment = Self.segment(
            text: "The resilient phrase beacon survives partial failure.",
            speakerLabel: "anchor",
            startSeconds: 2.1,
            endSeconds: 4.0,
            words: ["The", "resilient", "phrase", "beacon", "survives", "partial", "failure."]
        )
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: PipelineFakeDecoder(chunks: [Self.chunk(sequence: 0), Self.chunk(sequence: 1)]),
            transcriber: PipelineFakeTranscriber(
                segmentsBySequence: [1: [validSegment]],
                errorBySequence: [
                    0: PipelineFakeIngestError(
                        "transcribe failed token=synthetic-secret path=/tmp/chunk-token=synthetic-secret.wav"
                    )
                ]
            ),
            diarizer: PipelineFakeDiarizer(
                turnsBySequence: [
                    1: [
                        SpeakerTurnDraft(
                            speakerLabel: "anchor", startSeconds: 2.0, endSeconds: 4.1,
                            confidence: 0.93)
                    ]
                ],
                errorBySequence: [
                    0: PipelineFakeIngestError(
                        "diarize failed password=synthetic-secret source=https://user:pass@example.test/bad?token=synthetic-secret#frag"
                    )
                ]
            )
        )

        let result = try await pipeline.run(
            source: "https://user:pass@example.test/live.m3u8?token=synthetic-secret#frag",
            streamType: .hls,
            maxChunks: 2
        )

        XCTAssertEqual(result.processedChunks, 2)
        XCTAssertEqual(result.diagnostics.map(\.phase), [.transcribe, .diarize])

        let evidence = try temporary.database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        ingest_runs.status AS status,
                        (SELECT COUNT(*) FROM ingest_chunks) AS chunks,
                        (SELECT COUNT(*) FROM ingest_chunks WHERE sequence = 0) AS failed_chunks,
                        (SELECT COUNT(*) FROM ingest_chunks WHERE sequence = 1) AS valid_chunks,
                        (SELECT COUNT(*) FROM transcript_segments) AS segments,
                        (SELECT COUNT(*) FROM transcript_words) AS words,
                        (SELECT COUNT(*) FROM speaker_turns) AS speaker_turns,
                        (SELECT COUNT(*) FROM ad_events) AS ad_events,
                        (SELECT COUNT(*) FROM transcript_segments_fts) AS fts_rows,
                        (SELECT COUNT(*) FROM transcript_segments
                         JOIN ingest_chunks ON ingest_chunks.id = transcript_segments.chunk_id
                         WHERE ingest_chunks.sequence = 0) AS failed_chunk_segments,
                        (SELECT COUNT(*) FROM ingest_diagnostics WHERE phase IN ('transcribe', 'diarize')) AS diagnostics,
                        (SELECT GROUP_CONCAT(context_json, '\n') FROM ingest_diagnostics ORDER BY id) AS diagnostic_context
                    FROM ingest_runs
                    """)
        }
        XCTAssertEqual(evidence?["status"] as String?, "completed")
        XCTAssertEqual(evidence?["chunks"] as Int?, 2)
        XCTAssertEqual(evidence?["failed_chunks"] as Int?, 1)
        XCTAssertEqual(evidence?["valid_chunks"] as Int?, 1)
        XCTAssertEqual(evidence?["segments"] as Int?, 1)
        XCTAssertEqual(evidence?["words"] as Int?, 7)
        XCTAssertEqual(evidence?["speaker_turns"] as Int?, 1)
        XCTAssertEqual(evidence?["ad_events"] as Int?, 2)
        XCTAssertEqual(evidence?["fts_rows"] as Int?, 1)
        XCTAssertEqual(evidence?["failed_chunk_segments"] as Int?, 0)
        XCTAssertEqual(evidence?["diagnostics"] as Int?, 2)
        let diagnosticContext: String = evidence?["diagnostic_context"] ?? ""
        XCTAssertTrue(diagnosticContext.contains("[redacted-path]"), diagnosticContext)
        Self.assertNoForbiddenLiterals(
            in: diagnosticContext,
            forbidden: [
                "synthetic-secret", "user:pass", "token=synthetic-secret",
                "/tmp/chunk-token=synthetic-secret.wav",
            ]
        )

        let query = TranscriptQuery(database: temporary.database)
        let searchResults = try query.search(
            phrase: "resilient phrase beacon", limit: 10, contextSegments: 0)
        XCTAssertEqual(searchResults.count, 1)
        let match = try XCTUnwrap(searchResults.first)
        XCTAssertEqual(match.identity.streamType, "hls")
        XCTAssertEqual(match.identity.streamSource, "https://example.test/live.m3u8")
        XCTAssertEqual(match.identity.sequence, validSegment.sequence)
        XCTAssertEqual(match.identity.speakerLabel, "anchor")
        XCTAssertEqual(match.startSeconds, 2.1)
        XCTAssertEqual(match.endSeconds, 4.0)
        XCTAssertEqual(match.text, "The resilient phrase beacon survives partial failure.")
        XCTAssertEqual(
            match.words.map(\.text),
            ["The", "resilient", "phrase", "beacon", "survives", "partial", "failure."])
        XCTAssertEqual(match.occurrenceCount, 1)

        let counts = try query.count(phrase: "resilient phrase beacon")
        XCTAssertEqual(counts.count, 1)
        XCTAssertEqual(counts.first?.streamID, match.identity.streamID)
        XCTAssertEqual(counts.first?.runID, match.identity.runID)
        XCTAssertEqual(counts.first?.speakerLabel, "anchor")
        XCTAssertEqual(counts.first?.occurrenceCount, 1)
        XCTAssertEqual(counts.first?.matchingSegmentCount, 1)
        XCTAssertEqual(try query.count(phrase: "poisoned failed chunk phrase"), [])
    }

    func testNonMonotonicWordTimestampsAreDiagnosedAndInvalidWordsAreRejected() async throws {
        let temporary = try TemporarySoundingDatabase()
        let badSegment = TranscriptSegmentDraft(
            sequence: 0,
            speakerLabel: "speaker-1",
            startSeconds: 0,
            endSeconds: 2,
            text: "hello rewind world",
            words: [
                TranscriptWordDraft(
                    sequence: 0, speakerLabel: "speaker-1", startSeconds: 0.0, endSeconds: 0.4,
                    text: "hello"),
                TranscriptWordDraft(
                    sequence: 1, speakerLabel: "speaker-1", startSeconds: 0.8, endSeconds: 1.0,
                    text: "rewind"),
                TranscriptWordDraft(
                    sequence: 2, speakerLabel: "speaker-1", startSeconds: 0.7, endSeconds: 1.2,
                    text: "world"),
            ]
        )
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: PipelineFakeDecoder(chunks: [Self.chunk(sequence: 0)]),
            transcriber: PipelineFakeTranscriber(segmentsBySequence: [0: [badSegment]]),
            diarizer: PipelineFakeDiarizer()
        )

        let result = try await pipeline.run(
            source: "https://example.test/live", streamType: .icecast, maxChunks: 1)

        XCTAssertEqual(result.diagnostics.map(\.reason), ["non-monotonic-word-timestamps"])
        let counts = try temporary.database.read { db in
            try [
                "segments": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments"),
                "words": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_words"),
                "diagnostics": Int.fetchOne(
                    db,
                    sql:
                        "SELECT COUNT(*) FROM ingest_diagnostics WHERE reason = 'non-monotonic-word-timestamps'"
                ),
            ]
        }
        XCTAssertEqual(counts, ["segments": 1, "words": 2, "diagnostics": 1])
    }

    func testTranscriberModelSetupFailureFailsRunWithSingleModelSetupDiagnostic() async throws {
        let temporary = try TemporarySoundingDatabase()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: PipelineFakeDecoder(chunks: [Self.chunk(sequence: 0)]),
            transcriber: PipelineFakeTranscriber(errorBySequence: [
                0: PipelineFakeDiagnosticError(
                    phase: .modelSetup, reason: "model-setup-failed", description: "token=secret")
            ]),
            diarizer: PipelineFakeDiarizer()
        )

        do {
            _ = try await pipeline.run(
                source: "https://user:pass@example.test/live?token=secret", streamType: .icecast,
                maxChunks: 1)
            XCTFail("Expected model setup failure")
        } catch let error as PipelineFakeDiagnosticError {
            XCTAssertEqual(error.ingestDiagnosticPhase, .modelSetup)
        } catch {
            XCTFail("Expected PipelineFakeDiagnosticError, got \(error)")
        }

        let rows = try temporary.database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT ingest_runs.status AS status, ingest_diagnostics.phase AS phase,
                           ingest_diagnostics.reason AS reason, ingest_diagnostics.context_json AS context
                    FROM ingest_runs
                    JOIN ingest_diagnostics ON ingest_diagnostics.run_id = ingest_runs.id
                    ORDER BY ingest_diagnostics.id
                    """)
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["status"] as String?, "failed")
        XCTAssertEqual(rows.first?["phase"] as String?, "modelSetup")
        XCTAssertEqual(rows.first?["reason"] as String?, "model-setup-failed")
        let context: String? = rows.first?["context"]
        XCTAssertFalse(context?.contains("secret") ?? true, context ?? "nil")
        let running = try temporary.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_runs WHERE status = 'running'")
        }
        XCTAssertEqual(running, 0)
    }

    func testDiarizerModelSetupFailureFailsRunWithSingleModelSetupDiagnostic() async throws {
        let temporary = try TemporarySoundingDatabase()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: PipelineFakeDecoder(chunks: [Self.chunk(sequence: 0)]),
            transcriber: PipelineFakeTranscriber(segmentsBySequence: [
                0: [Self.segment(text: "hello world")]
            ]),
            diarizer: PipelineFakeDiarizer(errorBySequence: [
                0: PipelineFakeDiagnosticError(
                    phase: .modelSetup, reason: "model-setup-failed", description: "password=secret"
                )
            ])
        )

        do {
            _ = try await pipeline.run(
                source: "https://user:pass@example.test/live?token=secret", streamType: .icecast,
                maxChunks: 1)
            XCTFail("Expected model setup failure")
        } catch let error as PipelineFakeDiagnosticError {
            XCTAssertEqual(error.ingestDiagnosticPhase, .modelSetup)
        } catch {
            XCTFail("Expected PipelineFakeDiagnosticError, got \(error)")
        }

        let rows = try temporary.database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT ingest_runs.status AS status, ingest_diagnostics.phase AS phase,
                           ingest_diagnostics.reason AS reason, ingest_diagnostics.context_json AS context
                    FROM ingest_runs
                    JOIN ingest_diagnostics ON ingest_diagnostics.run_id = ingest_runs.id
                    ORDER BY ingest_diagnostics.id
                    """)
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["status"] as String?, "failed")
        XCTAssertEqual(rows.first?["phase"] as String?, "modelSetup")
        XCTAssertEqual(rows.first?["reason"] as String?, "model-setup-failed")
        let context: String? = rows.first?["context"]
        XCTAssertFalse(context?.contains("secret") ?? true, context ?? "nil")
        let running = try temporary.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_runs WHERE status = 'running'")
        }
        XCTAssertEqual(running, 0)
    }
}
