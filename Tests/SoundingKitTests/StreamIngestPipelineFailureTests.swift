import Foundation
import GRDB
import XCTest

@testable import SoundingKit

final class StreamIngestPipelineFailureTests: StreamIngestPipelineTestCase {
    func testDecoderFailurePersistsDecodeDiagnosticAndFailsRunWithRedactedContext() async throws {
        let temporary = try TemporarySoundingDatabase()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: PipelineFakeDecoder(
                error: PipelineFakeIngestError(
                    "decoder failed for https://user:pass@example.test/live?token=secret")),
            transcriber: PipelineFakeTranscriber(),
            diarizer: PipelineFakeDiarizer()
        )

        do {
            _ = try await pipeline.run(
                source: "https://user:pass@example.test/live?token=secret", streamType: .hls,
                maxChunks: 1)
            XCTFail("Expected decoder failure")
        } catch let error as PipelineFakeIngestError {
            XCTAssertTrue(error.description.contains("decoder failed"))
        } catch {
            XCTFail("Expected PipelineFakeIngestError, got \(error)")
        }

        let evidence = try temporary.database.read { db in
            try Row.fetchOne(
                db,
                sql: """
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
            transcriber: PipelineFakeTranscriber(),
            diarizer: PipelineFakeDiarizer()
        )

        do {
            _ = try await pipeline.run(
                source: "/tmp/missing-token=secret.wav", streamType: .icecast, maxChunks: 1)
            XCTFail("Expected native source-open failure")
        } catch let error as AVFoundationAudioDecoderError {
            XCTAssertEqual(error.ingestDiagnosticReason, "source-open-failed")
        } catch {
            XCTFail("Expected AVFoundationAudioDecoderError, got \(error)")
        }

        let row = try temporary.database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT phase, reason, context_json
                    FROM ingest_diagnostics
                    """)
        }
        XCTAssertEqual(row?["phase"] as String?, "sourceOpen")
        XCTAssertEqual(row?["reason"] as String?, "source-open-failed")
        let context: String? = row?["context_json"]
        XCTAssertFalse(context?.contains("secret") ?? true, context ?? "nil")
    }

    func testCancellationAfterDecodeBeforeChunkProcessingCancelsRunWithDiagnostic() async throws {
        let temporary = try TemporarySoundingDatabase()
        let gate = PipelineDecodeGate(chunks: [Self.chunk(sequence: 0)])
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: PipelineGateDecoder(gate: gate),
            transcriber: PipelineFakeTranscriber(segmentsBySequence: [
                0: [Self.segment(text: "should not run")]
            ]),
            diarizer: PipelineFakeDiarizer()
        )

        let task = Task {
            try await pipeline.run(
                source: "https://user:pass@example.test/live?token=secret", streamType: .icecast,
                maxChunks: 1)
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
            try Row.fetchOne(
                db,
                sql: """
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
}
