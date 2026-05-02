import Foundation
import XCTest

@testable import SoundingKit

final class AppVerifyEvidenceTests: XCTestCase {
    func testEvidenceRoundTripUsesStableCheckNamesAndAggregatesPass() throws {
        let checks: [AppVerifyCheckRecord] = [
            .pass(.fixtureSourceCreated, phase: .fixture),
            .pass(.databaseOpened, phase: .database),
            .pass(.streamRegistered, phase: .registration),
            .pass(.runtimeStarted, phase: .runtimeStart),
            AppVerifyCheckEvaluator.decodeCompleted(processedChunks: 1, decodedChunks: 1),
            AppVerifyCheckEvaluator.playbackScheduled(scheduledBuffers: 1),
            .pass(.runtimeStopped, phase: .runtimeStop),
            .pass(.diagnosticsWritten, phase: .diagnostics),
        ]
        let evidence = AppVerifyEvidence(
            generatedAt: "2026-05-02T18:00:00Z",
            runID: "fixture-run-1",
            checks: checks,
            runtimeFacts: AppVerifyRuntimeFacts(
                phase: .diagnostics,
                processedChunks: 1,
                decodedChunks: 1,
                scheduledBuffers: 1,
                diagnosticCount: 2,
                recentDiagnosticEvents: ["playback.prepare.succeeded", "playback.play.scheduled"],
                timelineSnapshotFields: ["scheduledBufferCount": "1"]
            ),
            artifacts: [AppVerifyRedactedArtifact(kind: "evidence", path: "runtime-events.jsonl")]
        )

        let data = try evidence.jsonData()
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#""fixture_source_created""#), json)
        XCTAssertTrue(json.contains(#""avfoundation_playback_scheduled""#), json)
        XCTAssertTrue(json.contains(#""playback.prepare.succeeded""#), json)

        let decoded = try JSONDecoder().decode(AppVerifyEvidence.self, from: data)
        XCTAssertEqual(decoded.summary.status, .pass)
        XCTAssertEqual(decoded.summary.requiredCheckCount, checks.count)
        XCTAssertEqual(decoded.summary.failedRequiredCheckCount, 0)
        XCTAssertEqual(decoded.checks.map(\.name), checks.map(\.name))
    }

    func testAggregationFailsEmptyAndFailedRequiredChecks() {
        let empty = AppVerifyEvidenceSummary.aggregate([])
        XCTAssertEqual(empty.status, .fail)
        XCTAssertEqual(empty.failedRequiredCheckCount, 1)

        let failed = AppVerifyEvidenceSummary.aggregate([
            .pass(.fixtureSourceCreated, phase: .fixture),
            .fail(
                .databaseOpened,
                phase: .database,
                reason: "failed to open /tmp/app-verify.sqlite?token=secret"
            ),
        ])
        XCTAssertEqual(failed.status, .fail)
        XCTAssertEqual(failed.requiredCheckCount, 2)
        XCTAssertEqual(failed.failedRequiredCheckCount, 1)
    }

    func testWarningsAggregateWithoutFailingRequiredPasses() {
        let summary = AppVerifyEvidenceSummary.aggregate([
            .pass(.fixtureSourceCreated, phase: .fixture),
            .warn(.diagnosticsWritten, phase: .diagnostics, reason: "missing optional timeline snapshot"),
        ])
        XCTAssertEqual(summary.status, .warn)
        XCTAssertEqual(summary.failedRequiredCheckCount, 0)
        XCTAssertEqual(summary.warningCheckCount, 1)
    }

    func testSanitizesSecretLikeStringsAndLocalPaths() throws {
        let secret = "https://user:pass@example.test/live.wav?token=synthetic-secret#frag"
        let evidence = AppVerifyEvidence(
            generatedAt: "2026-05-02T18:00:00Z",
            runID: "token=synthetic-secret",
            checks: [
                .fail(
                    .fixtureSourceCreated,
                    phase: .fixture,
                    reason: "could not write /tmp/sounding-token=synthetic-secret/output.wav for \(secret)"
                )
            ],
            artifacts: [
                AppVerifyRedactedArtifact(kind: "fixture", path: "/Users/alice/app-verify-token=synthetic-secret/fixture.wav"),
            ],
            metadata: ["source": secret]
        )

        let payload = try XCTUnwrap(String(data: try evidence.jsonData(), encoding: .utf8))
        XCTAssertFalse(payload.contains("user:pass"), payload)
        XCTAssertFalse(payload.contains("synthetic-secret"), payload)
        XCTAssertFalse(payload.contains("token="), payload)
        XCTAssertFalse(payload.contains("/Users/alice"), payload)
        XCTAssertFalse(payload.contains("/tmp/sounding"), payload)
        XCTAssertTrue(payload.contains("[redacted-path]") || payload.contains("https://example.test/live.wav"), payload)
    }

    func testZeroDecodeAndPlaybackCountersFailRequiredChecks() {
        let decode = AppVerifyCheckEvaluator.decodeCompleted(processedChunks: 0, decodedChunks: 0)
        XCTAssertEqual(decode.status, .fail)
        XCTAssertTrue(decode.required)
        XCTAssertEqual(decode.phase, .decode)
        XCTAssertEqual(decode.facts?.processedChunks, 0)

        let playback = AppVerifyCheckEvaluator.playbackScheduled(scheduledBuffers: 0)
        XCTAssertEqual(playback.status, .fail)
        XCTAssertTrue(playback.required)
        XCTAssertEqual(playback.phase, .playback)
        XCTAssertEqual(playback.facts?.scheduledBuffers, 0)

        let summary = AppVerifyEvidenceSummary.aggregate([decode, playback])
        XCTAssertEqual(summary.status, .fail)
        XCTAssertEqual(summary.failedRequiredCheckCount, 2)
    }

    func testFixtureWAVCreationProducesRuntimeGeneratedPCMFixture() async throws {
        let runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppVerifyEvidenceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runDirectory) }

        let fixture = try AppVerifyFixtureSourceWriter.writeDeterministicWAV(in: runDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url.path))
        XCTAssertEqual(fixture.sourceDescription, "[redacted-path]")
        XCTAssertEqual(fixture.sampleRate, 44_100)
        XCTAssertEqual(fixture.channelCount, 2)
        XCTAssertEqual(fixture.bitDepth, 16)
        XCTAssertGreaterThan(fixture.byteCount, 44)

        let header = try Data(contentsOf: fixture.url).prefix(12)
        XCTAssertEqual(String(data: header.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: header.suffix(4), encoding: .ascii), "WAVE")

        let decoder = AVFoundationAudioDecoder(chunkDurationSeconds: 0.25)
        let chunks = try await decoder.decodedChunks(
            for: AudioDecodeRequest(
                source: fixture.url.path,
                streamType: .icecast,
                durationSeconds: 0.25,
                maxChunks: 1
            ))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertGreaterThan(chunks[0].byteCount, 0)
        XCTAssertEqual(chunks[0].audioFormat.payloadKind, .linearPCM)
        XCTAssertEqual(chunks[0].audioFormat.sampleRate, 44_100)
        XCTAssertEqual(chunks[0].audioFormat.channelCount, 2)
    }

    func testFixtureCreationFailureMapsToNamedFailedCheckWithSanitizedReason() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppVerifyEvidenceTests-file-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            _ = try AppVerifyFixtureSourceWriter.writeDeterministicWAV(
                in: fileURL,
                fileName: "token=synthetic-secret.wav"
            )
            XCTFail("Expected fixture creation to fail")
        } catch let error as AppVerifyFixtureSourceError {
            let check = error.check
            XCTAssertEqual(check.name, .fixtureSourceCreated)
            XCTAssertEqual(check.status, .fail)
            XCTAssertEqual(check.phase, .fixture)
            XCTAssertFalse(check.reason?.contains("synthetic-secret") ?? true, check.reason ?? "")
            XCTAssertFalse(error.description.contains("/tmp/"), error.description)
        } catch {
            XCTFail("Expected AppVerifyFixtureSourceError, got \(error)")
        }
    }

    func testMalformedEvidenceJSONProducesNormalDecodingErrorWithoutSecretLeakage() {
        let malformed = Data(#"{"checks":[{"name":"fixture_source_created","status":"nope"}],"metadata":{"source":"https://user:pass@example.test/live.wav?token=secret"}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppVerifyEvidence.self, from: malformed)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected DecodingError.dataCorrupted, got \(error)")
            }
            XCTAssertFalse(String(describing: error).contains("user:pass"), String(describing: error))
            XCTAssertFalse(String(describing: error).contains("token=secret"), String(describing: error))
        }
    }
}
