import Foundation
import GRDB
import XCTest

@testable import SoundingKit

final class StreamIngestPipelineHLSTests: StreamIngestPipelineTestCase {
    func testDefaultTimestampProviderUsesReusableISO8601ClockAndInjectionStillWins() async throws {
        let generated = StreamIngestPipeline.defaultTimestamp()
        XCTAssertNotNil(ISO8601DateFormatter().date(from: generated))

        let temporary = try TemporarySoundingDatabase()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: PipelineFakeDecoder(chunks: [Self.chunk(sequence: 0)]),
            transcriber: PipelineFakeTranscriber(),
            diarizer: PipelineFakeDiarizer(),
            now: { "2026-05-01T12:34:56Z" }
        )

        _ = try await pipeline.run(
            source: "https://example.test/live.m3u8",
            streamType: .hls,
            maxChunks: 1
        )

        let persistedRunStartedAt = try temporary.database.read { db in
            try String.fetchOne(db, sql: "SELECT started_at FROM ingest_runs")
        }
        XCTAssertEqual(persistedRunStartedAt, "2026-05-01T12:34:56Z")
    }

    func testHLSReconnectOverlapSkipsDuplicateBeforeInferenceAndPersistsContiguousSequence() async throws {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)
        let streamID = try writer.createStream(
            streamType: "hls",
            source: "https://example.test/live.m3u8",
            createdAt: "2026-05-01T10:00:00Z"
        )
        let probe = PipelineRecordingCollaboratorProbe()

        let firstPipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: PipelineFakeDecoder(chunks: [
                Self.hlsChunk(sequence: 0, mediaSequence: 7),
                Self.hlsChunk(sequence: 1, mediaSequence: 8),
            ]),
            transcriber: PipelineFakeTranscriber(segmentsBySequence: [
                0: [Self.segment(text: "media seven")],
                1: [Self.segment(text: "media eight")],
            ], probe: probe),
            diarizer: PipelineFakeDiarizer(turnsBySequence: [
                0: [SpeakerTurnDraft(speakerLabel: "speaker-1", startSeconds: 0, endSeconds: 1)],
                1: [SpeakerTurnDraft(speakerLabel: "speaker-1", startSeconds: 2, endSeconds: 3)],
            ], probe: probe),
            fingerprinter: PipelineRecordingFingerprinter(probe: probe)
        )
        let firstResult = try await firstPipeline.run(
            streamID: streamID,
            source: "https://user:pass@example.test/live.m3u8?token=secret#frag",
            streamType: .hls,
            maxChunks: 2
        )

        let secondPipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: PipelineFakeDecoder(chunks: [
                Self.hlsChunk(sequence: 0, mediaSequence: 8),
                Self.hlsChunk(sequence: 1, mediaSequence: 9),
            ]),
            transcriber: PipelineFakeTranscriber(segmentsBySequence: [
                0: [Self.segment(text: "duplicate eight must not run")],
                1: [Self.segment(text: "media nine")],
            ], errorByMediaSequence: [8: PipelineFakeIngestError("duplicate media sequence reached transcriber")], probe: probe),
            diarizer: PipelineFakeDiarizer(turnsBySequence: [
                1: [SpeakerTurnDraft(speakerLabel: "speaker-1", startSeconds: 4, endSeconds: 5)],
            ], errorByMediaSequence: [8: PipelineFakeIngestError("duplicate media sequence reached diarizer")], probe: probe),
            fingerprinter: PipelineRecordingFingerprinter(errorByMediaSequence: [
                8: PipelineFakeIngestError("duplicate media sequence reached fingerprinter")
            ], probe: probe)
        )
        let secondResult = try await secondPipeline.run(
            streamID: streamID,
            source: "https://user:pass@example.test/live.m3u8?token=secret#frag",
            streamType: .hls,
            maxChunks: 2
        )

        let transcribedMediaSequences = await probe.transcribedMediaSequences()
        let diarizedMediaSequences = await probe.diarizedMediaSequences()
        let fingerprintedMediaSequences = await probe.fingerprintedMediaSequences()

        XCTAssertEqual(firstResult.processedChunks, 2)
        XCTAssertEqual(secondResult.processedChunks, 1)
        XCTAssertEqual(transcribedMediaSequences, [7, 8, 9])
        XCTAssertEqual(diarizedMediaSequences, [7, 8, 9])
        XCTAssertEqual(fingerprintedMediaSequences, [7, 8, 9])

        let evidence = try temporary.database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT
                    (SELECT COUNT(*) FROM ingest_chunks) AS chunks,
                    (SELECT GROUP_CONCAT(media_sequence, ',') FROM hls_ingest_segments ORDER BY media_sequence) AS media_sequences,
                    (SELECT COUNT(*) FROM hls_ingest_segments WHERE media_sequence = 8) AS media_eight_claims,
                    (SELECT COUNT(*) FROM transcript_segments) AS segments,
                    (SELECT COUNT(*) FROM ad_events) AS ad_events,
                    (SELECT COUNT(*) FROM audio_fingerprints) AS fingerprints,
                    (SELECT COUNT(*) FROM song_plays) AS song_plays,
                    (SELECT COUNT(*) FROM ingest_diagnostics WHERE reason = 'hls-segment-duplicate') AS duplicate_diagnostics,
                    (SELECT GROUP_CONCAT(context_json, '\n') FROM ingest_diagnostics WHERE reason LIKE 'hls-%' ORDER BY id) AS hls_context
                """)
        }
        XCTAssertEqual(evidence?["chunks"] as Int?, 3)
        XCTAssertEqual(evidence?["media_sequences"] as String?, "7,8,9")
        XCTAssertEqual(evidence?["media_eight_claims"] as Int?, 1)
        XCTAssertEqual(evidence?["segments"] as Int?, 3)
        XCTAssertEqual(evidence?["ad_events"] as Int?, 3)
        XCTAssertEqual(evidence?["fingerprints"] as Int?, 3)
        XCTAssertEqual(evidence?["song_plays"] as Int?, 3)
        XCTAssertEqual(evidence?["duplicate_diagnostics"] as Int?, 1)
        let hlsContext: String = evidence?["hls_context"] ?? ""
        XCTAssertTrue(hlsContext.contains("duplicate-skip"), hlsContext)
        XCTAssertTrue(hlsContext.contains("mediaSequence"), hlsContext)
        Self.assertNoForbiddenLiterals(
            in: hlsContext,
            forbidden: ["user:pass", "token=secret", "#frag", "duplicate media sequence"]
        )
    }

    func testMaxChunksOnePersistsExactlyOneChunkWithTranscriptSpeakerAndMarkerRows() async throws {
        let temporary = try TemporarySoundingDatabase()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: PipelineFakeDecoder(chunks: [Self.chunk(sequence: 0), Self.chunk(sequence: 1)]),
            transcriber: PipelineFakeTranscriber(segmentsBySequence: [
                0: [Self.segment(text: "hello world")], 1: [Self.segment(text: "ignored")],
            ]),
            diarizer: PipelineFakeDiarizer(turnsBySequence: [
                0: [SpeakerTurnDraft(speakerLabel: "speaker-1", startSeconds: 0, endSeconds: 1.2)]
            ])
        )

        let result = try await pipeline.run(
            source: "https://user:pass@example.test/live.m3u8?token=secret#frag",
            streamType: .hls,
            maxChunks: 1
        )

        XCTAssertEqual(result.processedChunks, 1)
        let counts = try temporary.database.read { db in
            try [
                "streams": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM streams"),
                "completed_runs": Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM ingest_runs WHERE status = 'completed'"),
                "chunks": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_chunks"),
                "segments": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments"),
                "words": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_words"),
                "turns": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_turns"),
                "ads": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ad_events"),
            ]
        }
        XCTAssertEqual(
            counts,
            [
                "streams": 1,
                "completed_runs": 1,
                "chunks": 1,
                "segments": 1,
                "words": 2,
                "turns": 1,
                "ads": 1,
            ])

        let storedSources = try temporary.database.read { db in
            try [
                "stream": String.fetchOne(db, sql: "SELECT source FROM streams"),
                "chunk": String.fetchOne(db, sql: "SELECT segment_uri FROM ingest_chunks"),
                "adRaw": String.fetchOne(db, sql: "SELECT raw_base64 FROM ad_events"),
            ]
        }
        XCTAssertEqual(storedSources["stream"] as? String, "https://example.test/live.m3u8")
        XCTAssertEqual(storedSources["chunk"] as? String, "https://example.test/segment-000.ts")
        XCTAssertEqual(storedSources["adRaw"] as? String, "[redacted]")
    }

    func testHLSIdentityIsPersistedInRedactedChunkContext() async throws {
        let temporary = try TemporarySoundingDatabase()
        let chunk = DecodedAudioChunk(
            sequence: 0,
            segmentURI: "https://user:pass@example.test/live/segment7.ts?token=secret#frag",
            hlsIdentity: HLSDecodedAudioChunkIdentity(
                mediaSequence: 7,
                segmentIdentity:
                    "https://user:pass@example.test/live/segment7.ts?token=secret#frag",
                manifestPosition: 0
            ),
            audio: Data([0x01, 0x02, 0x03]),
            startSeconds: 0,
            endSeconds: 6,
            startedAt: "2026-04-30T12:00:00Z",
            endedAt: "2026-04-30T12:00:06Z"
        )
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: PipelineFakeDecoder(chunks: [chunk]),
            transcriber: PipelineFakeTranscriber(),
            diarizer: PipelineFakeDiarizer()
        )

        _ = try await pipeline.run(
            source:
                "https://viewer:letmein@example.test/live.m3u8?token=synthetic-secret#private-fragment",
            streamType: .hls,
            maxChunks: 1
        )

        let context =
            try temporary.database.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT context_json FROM ingest_chunks WHERE sequence = 0"
                )
            } ?? ""

        XCTAssertTrue(context.contains("\"hls\""), context)
        XCTAssertTrue(context.contains("\"mediaSequence\":7"), context)
        XCTAssertTrue(
            context.contains(
                "\"segmentIdentity\":\"https:\\/\\/example.test\\/live\\/segment7.ts\""), context)
        XCTAssertTrue(context.contains("\"manifestPosition\":0"), context)
        Self.assertNoForbiddenLiterals(
            in: context,
            forbidden: [
                "user:pass", "viewer", "letmein", "secret", "synthetic-secret",
                "token=secret", "private-fragment", "#frag",
            ]
        )
    }

    func testEmptyChunksAreDiagnosedWithoutTranscriptRows() async throws {
        let temporary = try TemporarySoundingDatabase()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: PipelineFakeDecoder(chunks: [Self.chunk(sequence: 0, audio: Data())]),
            transcriber: PipelineFakeTranscriber(),
            diarizer: PipelineFakeDiarizer()
        )

        let result = try await pipeline.run(
            source: "https://example.test/live", streamType: .icecast, maxChunks: 1)

        XCTAssertEqual(result.processedChunks, 1)
        XCTAssertEqual(result.diagnostics.first?.phase, .decode)
        XCTAssertEqual(result.diagnostics.first?.reason, "empty-audio-chunk")
        let counts = try temporary.database.read { db in
            try [
                "chunks": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_chunks"),
                "segments": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments"),
                "diagnostics": Int.fetchOne(
                    db,
                    sql:
                        "SELECT COUNT(*) FROM ingest_diagnostics WHERE phase = 'decode' AND reason = 'empty-audio-chunk'"
                ),
            ]
        }
        XCTAssertEqual(counts, ["chunks": 1, "segments": 0, "diagnostics": 1])
    }

    func testIngestRedactionRemovesSecretsAndLocalPathsFromPersistedOperationalFields() async throws
    {
        let temporary = try TemporarySoundingDatabase()
        let source =
            "https://viewer:letmein@example.test/live.m3u8?token=synthetic-secret#private-fragment"
        let providerAudioPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundingProviderAudio")
            .appendingPathComponent("provider-token=synthetic-secret.wav")
            .path
        let modelCacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sounding")
            .appendingPathComponent("Models")
            .appendingPathComponent("whisperkit")
            .path
        let databasePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest-token=synthetic-secret.sqlite")
            .path
        let malformedURLLike = "https://viewer:letmein@ token=synthetic-secret#private-fragment"
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: PipelineFakeDecoder(chunks: [Self.chunk(sequence: 0)]),
            transcriber: PipelineFakeTranscriber(errorBySequence: [
                0: PipelineFakeIngestError(
                    "provider failed for \(source) db=\(databasePath) cache=\(modelCacheRoot) audio=\(providerAudioPath) \(malformedURLLike)"
                )
            ]),
            diarizer: PipelineFakeDiarizer()
        )

        _ = try await pipeline.run(source: source, streamType: .hls, maxChunks: 1)

        let row = try temporary.database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT streams.source AS stream_source,
                           ingest_chunks.segment_uri AS segment_uri,
                           ingest_diagnostics.source AS diagnostic_source,
                           ingest_diagnostics.context_json AS context
                    FROM streams
                    JOIN ingest_runs ON ingest_runs.stream_id = streams.id
                    JOIN ingest_chunks ON ingest_chunks.run_id = ingest_runs.id AND ingest_chunks.sequence = 0
                    JOIN ingest_diagnostics ON ingest_diagnostics.chunk_id = ingest_chunks.id
                    """)
        }
        let combined = [
            row?["stream_source"] as String?,
            row?["segment_uri"] as String?,
            row?["diagnostic_source"] as String?,
            row?["context"] as String?,
        ].compactMap { $0 }.joined(separator: "\n")

        XCTAssertTrue(combined.contains("https://example.test/live.m3u8"), combined)
        XCTAssertTrue(combined.contains("https://example.test/segment-000.ts"), combined)
        XCTAssertTrue(combined.contains("[redacted-path]"), combined)
        Self.assertNoForbiddenLiterals(
            in: combined,
            forbidden: [
                "viewer", "letmein", "synthetic-secret", "private-fragment",
                "token=synthetic-secret", databasePath, modelCacheRoot, providerAudioPath,
                FileManager.default.temporaryDirectory.path,
            ]
        )
    }

    func testIngestRedactionHandlesMalformedURLLikeTextWithoutLeakingSecrets() {
        let text = IngestRedaction.redact(
            "failed opening https://viewer:letmein@ token=synthetic-secret#private-fragment path=/tmp/audio-token=synthetic-secret.wav"
        )

        XCTAssertTrue(text.contains("failed opening"), text)
        XCTAssertTrue(text.contains("[redacted-path]"), text)
        Self.assertNoForbiddenLiterals(
            in: text,
            forbidden: [
                "viewer", "letmein", "synthetic-secret", "private-fragment",
                "/tmp/audio-token=synthetic-secret.wav",
            ]
        )
    }

    func testIngestDiagnosticRedactionRemovesSecretAssignmentKeyNames() {
        let text = IngestRedaction.diagnostic(
            #"segment=segment-0.ts?token=uat-secret secret=hidden api_key=hidden password=hidden"#
        )

        XCTAssertTrue(text.contains("[redacted-secret]"), text)
        Self.assertNoForbiddenLiterals(
            in: text,
            forbidden: [
                "token=", "secret=", "api_key=", "password=", "uat-secret", "hidden",
            ])
    }
}
