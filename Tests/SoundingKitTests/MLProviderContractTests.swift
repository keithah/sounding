import Foundation
import GRDB
import XCTest
@testable import SoundingKit

final class MLProviderContractTests: XCTestCase {
    func testWhisperKitTranscriberUsesCacheAndMapsEngineSegments() async throws {
        let cache = ModelCache(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let transcriber = WhisperKitTranscriber(
            modelName: "tiny",
            cache: cache,
            setup: { target, progress in
                progress(1)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                return target
            },
            engineFactory: { modelName, modelDirectory in
                XCTAssertEqual(modelName, "tiny")
                XCTAssertTrue(modelDirectory.lastPathComponent == "tiny" || modelDirectory.path.contains("tiny"))
                return FakeWhisperEngine()
            }
        )

        let segments = try await transcriber.transcribe(Self.chunk())

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.text, "hello model")
        XCTAssertEqual(segments.first?.words.count, 2)
    }

    func testFluidAudioDiarizerUsesCacheAndMapsSpeakerTurns() async throws {
        let cache = ModelCache(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let diarizer = FluidAudioDiarizer(
            modelName: "offline-diarizer",
            cache: cache,
            setup: { target, progress in
                progress(1)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                return target
            },
            engineFactory: { modelName, _ in
                XCTAssertEqual(modelName, "offline-diarizer")
                return FakeFluidEngine()
            }
        )

        let turns = try await diarizer.diarize(Self.chunk(), transcriptSegments: [])

        XCTAssertEqual(turns, [SpeakerTurnDraft(speakerLabel: "speaker-1", startSeconds: 0.1, endSeconds: 1.3, confidence: 0.8)])
    }

    func testLinearPCMChunksAreStagedAsWAVFilesForProviders() async throws {
        let cache = ModelCache(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let transcriber = WhisperKitTranscriber(
            modelName: "tiny",
            cache: cache,
            setup: { target, progress in
                progress(1)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                return target
            },
            engineFactory: { _, _ in WAVAssertingWhisperEngine() }
        )

        let linearPCMChunk = Self.chunk(
            audio: Data([0x01, 0x00, 0x02, 0x00]),
            audioFormat: .linearPCM(sampleRate: 44_100, channelCount: 1, bitDepth: 16)
        )
        let segments = try await transcriber.transcribe(linearPCMChunk)

        XCTAssertEqual(segments.first?.text, "wav ok")

        let diarizer = FluidAudioDiarizer(
            modelName: "offline-diarizer",
            cache: cache,
            setup: { target, progress in
                progress(1)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                return target
            },
            engineFactory: { _, _ in WAVAssertingFluidEngine() }
        )

        let turns = try await diarizer.diarize(linearPCMChunk, transcriptSegments: segments)

        XCTAssertEqual(turns.first?.speakerLabel, "speaker-wav")
    }

    func testModelSetupFailurePersistsModelSetupDiagnosticInPipeline() async throws {
        let temporary = try TemporarySoundingDatabase()
        let transcriber = WhisperKitTranscriber(
            modelName: "tiny",
            cache: ModelCache(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)),
            setup: { _, _ in throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "token=secret"]) },
            engineFactory: { _, _ in FakeWhisperEngine() }
        )
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: FakeDecoder(chunks: [Self.chunk()]),
            transcriber: transcriber,
            diarizer: FakeDiarizer()
        )

        do {
            _ = try await pipeline.run(source: "https://user:pass@example.test/live?token=secret", streamType: .icecast, maxChunks: 1)
            XCTFail("Expected model setup failure to terminate the ingest run")
        } catch let error as ModelCacheError {
            XCTAssertEqual(error.ingestDiagnosticPhase, .modelSetup)
            XCTAssertEqual(error.ingestDiagnosticReason, "model-setup-failed")
        } catch {
            XCTFail("Expected ModelCacheError, got \(error)")
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
        XCTAssertEqual(evidence?["phase"] as String?, "modelSetup")
        XCTAssertEqual(evidence?["reason"] as String?, "model-setup-failed")
        let context: String? = evidence?["context"]
        XCTAssertFalse(context?.contains("secret") ?? true, context ?? "nil")
    }

    func testInvalidProviderModelNameIsHandledWithoutCallingFactory() async throws {
        let transcriber = WhisperKitTranscriber(
            modelName: "../tiny",
            cache: ModelCache(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)),
            setup: { target, _ in target },
            engineFactory: { _, _ in
                XCTFail("Factory should not run for invalid model names")
                return FakeWhisperEngine()
            }
        )

        do {
            _ = try await transcriber.transcribe(Self.chunk())
            XCTFail("Expected invalid model error")
        } catch let error as ModelCacheError {
            XCTAssertEqual(error.ingestDiagnosticPhase, .modelSetup)
            XCTAssertEqual(error.ingestDiagnosticReason, "invalid-model-name")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmptyAudioIsRejectedBeforeModelSetup() async throws {
        let transcriber = WhisperKitTranscriber(
            setup: { target, _ in
                XCTFail("Setup should not run for empty audio")
                return target
            },
            engineFactory: { _, _ in FakeWhisperEngine() }
        )

        do {
            _ = try await transcriber.transcribe(Self.chunk(audio: Data()))
            XCTFail("Expected empty audio error")
        } catch let error as MLProviderError {
            XCTAssertEqual(error.ingestDiagnosticReason, "empty-audio")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static func chunk(
        audio: Data = Data("fake audio bytes".utf8),
        audioFormat: DecodedAudioFormat = .containerBytes
    ) -> DecodedAudioChunk {
        DecodedAudioChunk(
            sequence: 0,
            segmentURI: "https://user:pass@example.test/segment.ts?token=secret",
            audio: audio,
            audioFormat: audioFormat,
            startSeconds: 0,
            endSeconds: 2,
            startedAt: "2026-04-30T12:00:00Z",
            endedAt: "2026-04-30T12:00:02Z"
        )
    }
}

private struct WAVAssertingWhisperEngine: WhisperTranscriptionEngine {
    func transcribeAudio(at url: URL, chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
        let data = try Data(contentsOf: url)
        XCTAssertEqual(url.pathExtension, "wav")
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.dropFirst(8).prefix(4), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data.dropFirst(36).prefix(4), encoding: .ascii), "data")
        XCTAssertEqual(data.suffix(chunk.audio.count), chunk.audio)
        return [
            TranscriptSegmentDraft(
                sequence: 0,
                startSeconds: chunk.startSeconds,
                endSeconds: chunk.endSeconds,
                text: "wav ok"
            )
        ]
    }
}

private struct WAVAssertingFluidEngine: FluidDiarizationEngine {
    func diarizeAudio(at url: URL, chunk: DecodedAudioChunk, transcriptSegments: [TranscriptSegmentDraft]) async throws -> [SpeakerTurnDraft] {
        let data = try Data(contentsOf: url)
        XCTAssertEqual(url.pathExtension, "wav")
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.dropFirst(8).prefix(4), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data.dropFirst(36).prefix(4), encoding: .ascii), "data")
        XCTAssertEqual(data.suffix(chunk.audio.count), chunk.audio)
        return [
            SpeakerTurnDraft(
                speakerLabel: "speaker-wav",
                startSeconds: chunk.startSeconds,
                endSeconds: chunk.endSeconds,
                confidence: 0.9
            )
        ]
    }
}

private struct FakeWhisperEngine: WhisperTranscriptionEngine {
    func transcribeAudio(at url: URL, chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        return [
            TranscriptSegmentDraft(
                sequence: 0,
                startSeconds: chunk.startSeconds + 0.1,
                endSeconds: chunk.startSeconds + 1.3,
                text: "hello model",
                confidence: 0.9,
                words: [
                    TranscriptWordDraft(sequence: 0, startSeconds: 0.1, endSeconds: 0.4, text: "hello", confidence: 0.9),
                    TranscriptWordDraft(sequence: 1, startSeconds: 0.5, endSeconds: 1.3, text: "model", confidence: 0.8)
                ]
            )
        ]
    }
}

private struct FakeFluidEngine: FluidDiarizationEngine {
    func diarizeAudio(at url: URL, chunk: DecodedAudioChunk, transcriptSegments: [TranscriptSegmentDraft]) async throws -> [SpeakerTurnDraft] {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        return [SpeakerTurnDraft(speakerLabel: "speaker-1", startSeconds: 0.1, endSeconds: 1.3, confidence: 0.8)]
    }
}

private struct FakeDecoder: AudioDecoding {
    var chunks: [DecodedAudioChunk]

    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        chunks
    }
}

private struct FakeDiarizer: SpeakerDiarization {
    func diarize(_ chunk: DecodedAudioChunk, transcriptSegments: [TranscriptSegmentDraft]) async throws -> [SpeakerTurnDraft] {
        []
    }
}
