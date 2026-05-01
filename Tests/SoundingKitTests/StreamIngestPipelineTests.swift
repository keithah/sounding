import Foundation
import GRDB
import XCTest
@testable import SoundingKit

final class StreamIngestPipelineTests: XCTestCase {
    func testMaxChunksOnePersistsExactlyOneChunkWithTranscriptSpeakerAndMarkerRows() async throws {
        let temporary = try TemporarySoundingDatabase()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: FakeDecoder(chunks: [Self.chunk(sequence: 0), Self.chunk(sequence: 1)]),
            transcriber: FakeTranscriber(segmentsBySequence: [0: [Self.segment(text: "hello world")], 1: [Self.segment(text: "ignored")]]),
            diarizer: FakeDiarizer(turnsBySequence: [0: [SpeakerTurnDraft(speakerLabel: "speaker-1", startSeconds: 0, endSeconds: 1.2)]])
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
                "completed_runs": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_runs WHERE status = 'completed'"),
                "chunks": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_chunks"),
                "segments": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments"),
                "words": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_words"),
                "turns": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_turns"),
                "ads": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ad_events")
            ]
        }
        XCTAssertEqual(counts, [
            "streams": 1,
            "completed_runs": 1,
            "chunks": 1,
            "segments": 1,
            "words": 2,
            "turns": 1,
            "ads": 1
        ])

        let storedSources = try temporary.database.read { db in
            try [
                "stream": String.fetchOne(db, sql: "SELECT source FROM streams"),
                "chunk": String.fetchOne(db, sql: "SELECT segment_uri FROM ingest_chunks"),
                "adRaw": String.fetchOne(db, sql: "SELECT raw_base64 FROM ad_events")
            ]
        }
        XCTAssertEqual(storedSources["stream"] as? String, "https://example.test/live.m3u8")
        XCTAssertEqual(storedSources["chunk"] as? String, "https://example.test/segment-000.ts")
        XCTAssertEqual(storedSources["adRaw"] as? String, "[redacted]")
    }

    func testTranscriberAndDiarizerFailuresPersistPhaseDiagnosticsAndCompleteRun() async throws {
        let temporary = try TemporarySoundingDatabase()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: FakeDecoder(chunks: [Self.chunk(sequence: 0)]),
            transcriber: FakeTranscriber(errorBySequence: [0: FakeIngestError("transcribe token=secret")]),
            diarizer: FakeDiarizer(errorBySequence: [0: FakeIngestError("diarize password=secret")])
        )

        let result = try await pipeline.run(source: "https://example.test/live", streamType: .icecast, maxChunks: 1)

        XCTAssertEqual(result.processedChunks, 1)
        XCTAssertEqual(result.diagnostics.map(\.phase), [.transcribe, .diarize])
        let rows = try temporary.database.read { db in
            try Row.fetchAll(db, sql: "SELECT phase, severity, reason, context_json FROM ingest_diagnostics ORDER BY id")
        }
        XCTAssertEqual(rows.map { $0["phase"] as String }, ["transcribe", "diarize"])
        XCTAssertEqual(rows.map { $0["severity"] as String }, ["error", "error"])
        XCTAssertEqual(rows.map { $0["reason"] as String }, ["transcription-failed", "diarization-failed"])
        for row in rows {
            let context: String = row["context_json"]
            XCTAssertFalse(context.contains("secret"), context)
        }
        let completed = try temporary.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_runs WHERE status = 'completed'")
        }
        XCTAssertEqual(completed, 1)
    }

    func testIngestRedactionRemovesSecretsAndLocalPathsFromPersistedOperationalFields() async throws {
        let temporary = try TemporarySoundingDatabase()
        let source = "https://viewer:letmein@example.test/live.m3u8?token=synthetic-secret#private-fragment"
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
            decoder: FakeDecoder(chunks: [Self.chunk(sequence: 0)]),
            transcriber: FakeTranscriber(errorBySequence: [
                0: FakeIngestError(
                    "provider failed for \(source) db=\(databasePath) cache=\(modelCacheRoot) audio=\(providerAudioPath) \(malformedURLLike)")
            ]),
            diarizer: FakeDiarizer()
        )

        _ = try await pipeline.run(source: source, streamType: .hls, maxChunks: 1)

        let row = try temporary.database.read { db in
            try Row.fetchOne(db, sql: """
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

    func testEmptyChunksAreDiagnosedWithoutTranscriptRows() async throws {
        let temporary = try TemporarySoundingDatabase()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: FakeDecoder(chunks: [Self.chunk(sequence: 0, audio: Data())]),
            transcriber: FakeTranscriber(),
            diarizer: FakeDiarizer()
        )

        let result = try await pipeline.run(source: "https://example.test/live", streamType: .icecast, maxChunks: 1)

        XCTAssertEqual(result.processedChunks, 1)
        XCTAssertEqual(result.diagnostics.first?.phase, .decode)
        XCTAssertEqual(result.diagnostics.first?.reason, "empty-audio-chunk")
        let counts = try temporary.database.read { db in
            try [
                "chunks": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_chunks"),
                "segments": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments"),
                "diagnostics": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_diagnostics WHERE phase = 'decode' AND reason = 'empty-audio-chunk'")
            ]
        }
        XCTAssertEqual(counts, ["chunks": 1, "segments": 0, "diagnostics": 1])
    }

    func testIngestRedactionHandlesMalformedURLLikeTextWithoutLeakingSecrets() {
        let text = IngestRedaction.redact(
            "failed opening https://viewer:letmein@ token=synthetic-secret#private-fragment path=/tmp/audio-token=synthetic-secret.wav"
        )

        XCTAssertTrue(text.contains("https://[redacted-source]"), text)
        XCTAssertTrue(text.contains("[redacted-path]"), text)
        Self.assertNoForbiddenLiterals(
            in: text,
            forbidden: ["viewer", "letmein", "synthetic-secret", "private-fragment", "/tmp/audio-token=synthetic-secret.wav"]
        )
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
                TranscriptWordDraft(sequence: 0, speakerLabel: "speaker-1", startSeconds: 0.0, endSeconds: 0.4, text: "hello"),
                TranscriptWordDraft(sequence: 1, speakerLabel: "speaker-1", startSeconds: 0.8, endSeconds: 1.0, text: "rewind"),
                TranscriptWordDraft(sequence: 2, speakerLabel: "speaker-1", startSeconds: 0.7, endSeconds: 1.2, text: "world")
            ]
        )
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: FakeDecoder(chunks: [Self.chunk(sequence: 0)]),
            transcriber: FakeTranscriber(segmentsBySequence: [0: [badSegment]]),
            diarizer: FakeDiarizer()
        )

        let result = try await pipeline.run(source: "https://example.test/live", streamType: .icecast, maxChunks: 1)

        XCTAssertEqual(result.diagnostics.map(\.reason), ["non-monotonic-word-timestamps"])
        let counts = try temporary.database.read { db in
            try [
                "segments": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments"),
                "words": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_words"),
                "diagnostics": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_diagnostics WHERE reason = 'non-monotonic-word-timestamps'")
            ]
        }
        XCTAssertEqual(counts, ["segments": 1, "words": 2, "diagnostics": 1])
    }

    func testDecoderFailurePersistsDecodeDiagnosticAndFailsRunWithRedactedContext() async throws {
        let temporary = try TemporarySoundingDatabase()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: FakeDecoder(error: FakeIngestError("decoder failed for https://user:pass@example.test/live?token=secret")),
            transcriber: FakeTranscriber(),
            diarizer: FakeDiarizer()
        )

        do {
            _ = try await pipeline.run(source: "https://user:pass@example.test/live?token=secret", streamType: .hls, maxChunks: 1)
            XCTFail("Expected decoder failure")
        } catch let error as FakeIngestError {
            XCTAssertTrue(error.description.contains("decoder failed"))
        } catch {
            XCTFail("Expected FakeIngestError, got \(error)")
        }

        let evidence = try temporary.database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT ingest_runs.status AS status, ingest_diagnostics.phase AS phase,
                       ingest_diagnostics.reason AS reason, ingest_diagnostics.context_json AS context
                FROM ingest_runs
                JOIN ingest_diagnostics ON ingest_diagnostics.run_id = ingest_runs.id
                """)
        }
        XCTAssertEqual(evidence?["status"] as String?, "failed")
        XCTAssertEqual(evidence?["phase"] as String?, "decode")
        XCTAssertEqual(evidence?["reason"] as String?, "decoder-failed")
        let context: String? = evidence?["context"]
        XCTAssertFalse(context?.contains("user:pass") ?? true, context ?? "nil")
        XCTAssertFalse(context?.contains("token=secret") ?? true, context ?? "nil")
    }

    func testNativeDecoderSourceOpenFailurePersistsSourceOpenDiagnostic() async throws {
        let temporary = try TemporarySoundingDatabase()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: AVFoundationAudioDecoder(),
            transcriber: FakeTranscriber(),
            diarizer: FakeDiarizer()
        )

        do {
            _ = try await pipeline.run(source: "/tmp/missing-token=secret.wav", streamType: .icecast, maxChunks: 1)
            XCTFail("Expected native source-open failure")
        } catch let error as AVFoundationAudioDecoderError {
            XCTAssertEqual(error.ingestDiagnosticReason, "source-open-failed")
        } catch {
            XCTFail("Expected AVFoundationAudioDecoderError, got \(error)")
        }

        let row = try temporary.database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT phase, reason, context_json
                FROM ingest_diagnostics
                """)
        }
        XCTAssertEqual(row?["phase"] as String?, "sourceOpen")
        XCTAssertEqual(row?["reason"] as String?, "source-open-failed")
        let context: String? = row?["context_json"]
        XCTAssertFalse(context?.contains("secret") ?? true, context ?? "nil")
    }

    func testTranscriberModelSetupFailureFailsRunWithSingleModelSetupDiagnostic() async throws {
        let temporary = try TemporarySoundingDatabase()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: FakeDecoder(chunks: [Self.chunk(sequence: 0)]),
            transcriber: FakeTranscriber(errorBySequence: [0: FakeDiagnosticError(phase: .modelSetup, reason: "model-setup-failed", description: "token=secret")]),
            diarizer: FakeDiarizer()
        )

        do {
            _ = try await pipeline.run(source: "https://user:pass@example.test/live?token=secret", streamType: .icecast, maxChunks: 1)
            XCTFail("Expected model setup failure")
        } catch let error as FakeDiagnosticError {
            XCTAssertEqual(error.ingestDiagnosticPhase, .modelSetup)
        } catch {
            XCTFail("Expected FakeDiagnosticError, got \(error)")
        }

        let rows = try temporary.database.read { db in
            try Row.fetchAll(db, sql: """
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
            decoder: FakeDecoder(chunks: [Self.chunk(sequence: 0)]),
            transcriber: FakeTranscriber(segmentsBySequence: [0: [Self.segment(text: "hello world")]]),
            diarizer: FakeDiarizer(errorBySequence: [0: FakeDiagnosticError(phase: .modelSetup, reason: "model-setup-failed", description: "password=secret")])
        )

        do {
            _ = try await pipeline.run(source: "https://user:pass@example.test/live?token=secret", streamType: .icecast, maxChunks: 1)
            XCTFail("Expected model setup failure")
        } catch let error as FakeDiagnosticError {
            XCTAssertEqual(error.ingestDiagnosticPhase, .modelSetup)
        } catch {
            XCTFail("Expected FakeDiagnosticError, got \(error)")
        }

        let rows = try temporary.database.read { db in
            try Row.fetchAll(db, sql: """
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

    func testCancellationAfterDecodeBeforeChunkProcessingCancelsRunWithDiagnostic() async throws {
        let temporary = try TemporarySoundingDatabase()
        let gate = DecodeGate(chunks: [Self.chunk(sequence: 0)])
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: GateDecoder(gate: gate),
            transcriber: FakeTranscriber(segmentsBySequence: [0: [Self.segment(text: "should not run")]]),
            diarizer: FakeDiarizer()
        )

        let task = Task {
            try await pipeline.run(source: "https://user:pass@example.test/live?token=secret", streamType: .icecast, maxChunks: 1)
        }
        await gate.waitUntilRequested()
        task.cancel()
        await gate.resume()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let evidence = try temporary.database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT ingest_runs.status AS status, ingest_diagnostics.reason AS reason,
                       ingest_diagnostics.context_json AS context,
                       (SELECT COUNT(*) FROM ingest_chunks WHERE ingest_chunks.run_id = ingest_runs.id AND sequence >= 0) AS real_chunks
                FROM ingest_runs
                JOIN ingest_diagnostics ON ingest_diagnostics.run_id = ingest_runs.id
                """)
        }
        XCTAssertEqual(evidence?["status"] as String?, "cancelled")
        XCTAssertEqual(evidence?["reason"] as String?, "ingest-cancelled")
        XCTAssertEqual(evidence?["real_chunks"] as Int?, 0)
        let context: String? = evidence?["context"]
        XCTAssertFalse(context?.contains("secret") ?? true, context ?? "nil")
        let running = try temporary.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_runs WHERE status = 'running'")
        }
        XCTAssertEqual(running, 0)
    }

    private static func chunk(sequence: Int, audio: Data = Data([0x01, 0x02, 0x03])) -> DecodedAudioChunk {
        DecodedAudioChunk(
            sequence: sequence,
            segmentURI: "https://user:pass@example.test/segment-\(String(format: "%03d", sequence)).ts?token=secret#frag",
            audio: audio,
            startSeconds: Double(sequence) * 2.0,
            endSeconds: Double(sequence + 1) * 2.0,
            startedAt: "2026-04-30T12:00:0\(sequence)Z",
            endedAt: "2026-04-30T12:00:0\(sequence + 1)Z",
            adMarkers: [
                AdMarker(
                    type: "SCTE35",
                    classification: .adStart,
                    source: "hls_segment",
                    pts: 1.0,
                    segment: "https://user:pass@example.test/segment-\(sequence).ts?token=secret",
                    rawBase64: "AAAAAQ==",
                    timestamp: "2026-04-30T12:00:0\(sequence)Z"
                )
            ]
        )
    }

    private static func segment(text: String) -> TranscriptSegmentDraft {
        TranscriptSegmentDraft(
            sequence: 0,
            speakerLabel: "speaker-1",
            startSeconds: 0,
            endSeconds: 1.2,
            text: text,
            confidence: 0.9,
            words: [
                TranscriptWordDraft(sequence: 0, speakerLabel: "speaker-1", startSeconds: 0.0, endSeconds: 0.5, text: "hello", confidence: 0.9),
                TranscriptWordDraft(sequence: 1, speakerLabel: "speaker-1", startSeconds: 0.6, endSeconds: 1.2, text: "world", confidence: 0.9)
            ]
        )
    }
    private static func assertNoForbiddenLiterals(
        in text: String,
        forbidden literals: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for literal in literals where !literal.isEmpty {
            XCTAssertFalse(
                text.contains(literal),
                "Expected redacted text to omit forbidden literal '\(literal)', got: \(text)",
                file: file,
                line: line
            )
        }
    }
}

private struct FakeDecoder: AudioDecoding {
    var chunks: [DecodedAudioChunk]
    var error: Error?

    init(chunks: [DecodedAudioChunk] = [], error: Error? = nil) {
        self.chunks = chunks
        self.error = error
    }

    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        if let error {
            throw error
        }
        return chunks
    }
}

private struct FakeTranscriber: MLTranscription {
    var segmentsBySequence: [Int: [TranscriptSegmentDraft]]
    var errorBySequence: [Int: Error]

    init(
        segmentsBySequence: [Int: [TranscriptSegmentDraft]] = [:],
        errorBySequence: [Int: Error] = [:]
    ) {
        self.segmentsBySequence = segmentsBySequence
        self.errorBySequence = errorBySequence
    }

    func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
        if let error = errorBySequence[chunk.sequence] {
            throw error
        }
        return segmentsBySequence[chunk.sequence] ?? []
    }
}

private struct FakeDiarizer: SpeakerDiarization {
    var turnsBySequence: [Int: [SpeakerTurnDraft]]
    var errorBySequence: [Int: Error]

    init(
        turnsBySequence: [Int: [SpeakerTurnDraft]] = [:],
        errorBySequence: [Int: Error] = [:]
    ) {
        self.turnsBySequence = turnsBySequence
        self.errorBySequence = errorBySequence
    }

    func diarize(_ chunk: DecodedAudioChunk, transcriptSegments: [TranscriptSegmentDraft]) async throws -> [SpeakerTurnDraft] {
        if let error = errorBySequence[chunk.sequence] {
            throw error
        }
        return turnsBySequence[chunk.sequence] ?? []
    }
}

private struct FakeIngestError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

private struct FakeDiagnosticError: Error, CustomStringConvertible, IngestDiagnosticError {
    var ingestDiagnosticPhase: IngestDiagnosticPhase
    var ingestDiagnosticReason: String
    var description: String

    init(phase: IngestDiagnosticPhase, reason: String, description: String) {
        self.ingestDiagnosticPhase = phase
        self.ingestDiagnosticReason = reason
        self.description = description
    }
}

private struct GateDecoder: AudioDecoding {
    let gate: DecodeGate

    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        await gate.chunksAfterResume()
    }
}

private actor DecodeGate {
    private let chunks: [DecodedAudioChunk]
    private var requested = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    init(chunks: [DecodedAudioChunk]) {
        self.chunks = chunks
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func chunksAfterResume() async -> [DecodedAudioChunk] {
        requested = true
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            resumeWaiter = continuation
        }
        return chunks
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}
