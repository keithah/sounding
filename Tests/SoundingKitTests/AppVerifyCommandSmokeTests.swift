import Foundation
import XCTest

@testable import SoundingKit
@testable import sounding

final class AppVerifyCommandSmokeTests: XCTestCase {
    func testAppVerifyHelpAdvertisesFixtureSubcommand() throws {
        let result = try CLIRunner().runSounding(arguments: ["app-verify", "--help"])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("fixture"), result.diagnosticSummary)
    }

    func testFixtureHelpAdvertisesJSONOption() throws {
        let result = try CLIRunner().runSounding(arguments: ["app-verify", "fixture", "--help"])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("--json"), result.diagnosticSummary)
    }

    func testMissingJSONUsesArgumentParserFailure() throws {
        let result = try CLIRunner().runSounding(arguments: ["app-verify", "fixture"])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        XCTAssertTrue(result.stderrText.contains("Missing expected argument"), result.diagnosticSummary)
        XCTAssertTrue(result.stderrText.contains("--json"), result.diagnosticSummary)
    }

    func testInvalidSubcommandUsesArgumentParserFailure() throws {
        let result = try CLIRunner().runSounding(arguments: ["app-verify", "bogus"])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        XCTAssertTrue(result.stderrText.contains("Unexpected argument 'bogus'"), result.diagnosticSummary)
        XCTAssertFalse(result.stderrText.contains("token=synthetic-secret"), result.diagnosticSummary)
    }

    func testPassingEvidenceWritesPrettySortedJSONAndExitsZero() async throws {
        let evidenceURL = temporaryEvidenceURL()
        defer { try? FileManager.default.removeItem(at: evidenceURL) }
        let capture = OutputCapture()
        let adapter = AppVerifyFixtureCommandAdapter(
            runner: { Self.passingEvidence() },
            standardOutput: { capture.stdout($0) },
            standardError: { capture.stderr($0) }
        )

        let exitCode = await adapter.run(jsonPath: evidenceURL.path)

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(capture.stderrText, "")
        XCTAssertEqual(capture.stdoutLines.count, 1)
        XCTAssertTrue(capture.stdoutText.contains("app verification passed"), capture.stdoutText)
        XCTAssertTrue(capture.stdoutText.contains("status=pass"), capture.stdoutText)
        assertSanitized(capture.stdoutText, forbiddenLiteral: evidenceURL.path)

        let evidenceText = try String(contentsOf: evidenceURL)
        XCTAssertTrue(evidenceText.contains("\n  \"artifacts\""), evidenceText)
        XCTAssertTrue(evidenceText.contains("\"fixture_source_created\""), evidenceText)
        XCTAssertTrue(evidenceText.contains("\"transcript_persistence\""), evidenceText)
        XCTAssertTrue(evidenceText.contains("\"projectionFacts\""), evidenceText)
        let decoded = try JSONDecoder().decode(AppVerifyEvidence.self, from: Data(evidenceText.utf8))
        XCTAssertEqual(decoded.summary.status, .pass)
        XCTAssertEqual(Set(decoded.checks.map(\.name)), Set(AppVerifyCheckName.fixtureRequired))
        XCTAssertEqual(decoded.summary.requiredCheckCount, AppVerifyCheckName.fixtureRequired.count)
    }

    func testFailedEvidenceWritesJSONThenReturnsNonZeroWithFailedCheckNames() async throws {
        let secretSource = "https://user:pass@example.test/live.wav?token=synthetic-secret#private-fragment"
        let evidenceURL = temporaryEvidenceURL()
        defer { try? FileManager.default.removeItem(at: evidenceURL) }
        let capture = OutputCapture()
        let adapter = AppVerifyFixtureCommandAdapter(
            runner: { Self.failedEvidence(secretSource: secretSource) },
            standardOutput: { capture.stdout($0) },
            standardError: { capture.stderr($0) }
        )

        let exitCode = await adapter.run(jsonPath: evidenceURL.path)

        XCTAssertEqual(exitCode, .failure)
        XCTAssertEqual(capture.stderrText, "")
        XCTAssertEqual(capture.stdoutLines.count, 1)
        XCTAssertTrue(capture.stdoutText.contains("app verification failed"), capture.stdoutText)
        XCTAssertTrue(capture.stdoutText.contains("requiredFailures=1"), capture.stdoutText)
        XCTAssertTrue(capture.stdoutText.contains("playback_muted:playback_control:required"), capture.stdoutText)
        XCTAssertFalse(capture.stdoutText.contains("runtime-events.jsonl"), capture.stdoutText)
        XCTAssertFalse(capture.stdoutText.contains("live.wav"), capture.stdoutText)
        assertSanitized(capture.stdoutText, forbiddenLiteral: secretSource)
        assertSanitized(capture.stdoutText, forbiddenLiteral: evidenceURL.path)

        let evidenceText = try String(contentsOf: evidenceURL)
        XCTAssertTrue(evidenceText.contains("playback_muted"), evidenceText)
        XCTAssertTrue(evidenceText.contains("runtime.mute.requested"), evidenceText)
        XCTAssertTrue(evidenceText.contains("[redacted"), evidenceText)
        assertSanitized(evidenceText, forbiddenLiteral: "user:pass")
        assertSanitized(evidenceText, forbiddenLiteral: "synthetic-secret")
        assertSanitized(evidenceText, forbiddenLiteral: "private-fragment")
        assertSanitized(evidenceText, forbiddenLiteral: "?token")
    }

    func testUnwritableJSONPathFailsWithoutPathLeakageOrPartialEvidence() async throws {
        let secretDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-app-verify-user:pass@example.test?token=synthetic-secret#frag-")
            .appendingPathExtension(UUID().uuidString)
        let evidenceURL = secretDirectory.appendingPathComponent("evidence.json")
        defer { try? FileManager.default.removeItem(at: secretDirectory) }
        let capture = OutputCapture()
        let adapter = AppVerifyFixtureCommandAdapter(
            runner: { Self.passingEvidence() },
            standardOutput: { capture.stdout($0) },
            standardError: { capture.stderr($0) }
        )

        let exitCode = await adapter.run(jsonPath: evidenceURL.path)

        XCTAssertEqual(exitCode, .failure)
        XCTAssertEqual(capture.stdoutText, "")
        XCTAssertTrue(capture.stderrText.contains("App verification output failed"), capture.stderrText)
        XCTAssertTrue(capture.stderrText.contains("redacted output path"), capture.stderrText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path), capture.stderrText)
        assertSanitized(capture.stderrText, forbiddenLiteral: evidenceURL.path)
        assertSanitized(capture.stderrText, forbiddenLiteral: secretDirectory.path)
        assertSanitized(capture.stderrText, forbiddenLiteral: "user:pass")
        assertSanitized(capture.stderrText, forbiddenLiteral: "synthetic-secret")
        assertSanitized(capture.stderrText, forbiddenLiteral: "?token")
        assertSanitized(capture.stderrText, forbiddenLiteral: "#frag")
        assertSanitized(capture.stderrText, forbiddenLiteral: "evidence.json")
    }

    func testSummaryLineDoesNotLeakSecretLikeEvidenceStrings() {
        let secretSource = "https://user:pass@example.test/live.wav?token=synthetic-secret#private-fragment"
        let adapter = AppVerifyFixtureCommandAdapter()
        let line = adapter.summaryLine(for: Self.failedEvidence(secretSource: secretSource))

        XCTAssertTrue(line.contains("playback_muted:playback_control:required"), line)
        XCTAssertFalse(line.contains("runtime-events.jsonl"), line)
        XCTAssertFalse(line.contains("live.wav"), line)
        assertSanitized(line, forbiddenLiteral: secretSource)
        assertSanitized(line, forbiddenLiteral: "user:pass")
        assertSanitized(line, forbiddenLiteral: "synthetic-secret")
        assertSanitized(line, forbiddenLiteral: "private-fragment")
    }


    func testAppVerifyHelpAdvertisesLiveSubcommand() throws {
        let result = try CLIRunner().runSounding(arguments: ["app-verify", "--help"])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("fixture"), result.diagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("live"), result.diagnosticSummary)
    }

    func testLiveHelpAdvertisesConfigAndJSONOptions() throws {
        let result = try CLIRunner().runSounding(arguments: ["app-verify", "live", "--help"])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("--config"), result.diagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("--json"), result.diagnosticSummary)
    }

    func testLiveMissingConfigUsesArgumentParserFailure() throws {
        let result = try CLIRunner().runSounding(arguments: ["app-verify", "live", "--json", "evidence.json"])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        XCTAssertTrue(result.stderrText.contains("Missing expected argument"), result.diagnosticSummary)
        XCTAssertTrue(result.stderrText.contains("--config"), result.diagnosticSummary)
    }

    func testLiveMissingJSONUsesArgumentParserFailure() throws {
        let result = try CLIRunner().runSounding(arguments: ["app-verify", "live", "--config", "app-verify-live.example.json"])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        XCTAssertTrue(result.stderrText.contains("Missing expected argument"), result.diagnosticSummary)
        XCTAssertTrue(result.stderrText.contains("--json"), result.diagnosticSummary)
    }

    func testLiveMissingConfigPathFailsWithFixedRedactedMessage() async throws {
        let secretConfigPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-live-user:pass@example.test?token=synthetic-secret#frag.json")
            .path
        let evidenceURL = temporaryEvidenceURL()
        defer { try? FileManager.default.removeItem(at: evidenceURL) }
        let capture = OutputCapture()
        let adapter = AppVerifyLiveCommandAdapter(
            standardOutput: { capture.stdout($0) },
            standardError: { capture.stderr($0) }
        )

        let exitCode = await adapter.run(configPath: secretConfigPath, jsonPath: evidenceURL.path)

        XCTAssertEqual(exitCode, .failure)
        XCTAssertEqual(capture.stdoutText, "")
        XCTAssertTrue(capture.stderrText.contains("could not read redacted config path"), capture.stderrText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path), capture.stderrText)
        assertSanitized(capture.stderrText, forbiddenLiteral: secretConfigPath)
        assertSanitized(capture.stderrText, forbiddenLiteral: "user:pass")
        assertSanitized(capture.stderrText, forbiddenLiteral: "synthetic-secret")
        assertSanitized(capture.stderrText, forbiddenLiteral: "#frag")
    }

    func testLiveMalformedConfigRedactsSecretLikeJSON() async throws {
        let secretSource = "https://user:pass@example.test/live.m3u8?token=synthetic-secret#frag"
        let evidenceURL = temporaryEvidenceURL()
        defer { try? FileManager.default.removeItem(at: evidenceURL) }
        let capture = OutputCapture()
        let adapter = AppVerifyLiveCommandAdapter(
            configReader: { _ in Data("{ \"streams\": [ { \"source\": \"\(secretSource)\" ".utf8) },
            runnerFactory: { _ in FakeLiveRunner(evidence: Self.livePassingEvidence(secretSource: secretSource)) },
            standardOutput: { capture.stdout($0) },
            standardError: { capture.stderr($0) }
        )

        let exitCode = await adapter.run(configPath: "/tmp/private-config.json", jsonPath: evidenceURL.path)

        XCTAssertEqual(exitCode, .failure)
        XCTAssertEqual(capture.stdoutText, "")
        XCTAssertTrue(capture.stderrText.contains("malformed JSON in redacted config path"), capture.stderrText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path), capture.stderrText)
        assertSanitized(capture.stderrText, forbiddenLiteral: secretSource)
        assertSanitized(capture.stderrText, forbiddenLiteral: "user:pass")
        assertSanitized(capture.stderrText, forbiddenLiteral: "synthetic-secret")
        assertSanitized(capture.stderrText, forbiddenLiteral: "private-config.json")
    }

    func testLiveValidationFailureRedactsSourceAndConfigPath() async throws {
        let secretSource = "https://user:pass@example.test/radio?token=synthetic-secret#frag"
        let secretConfigPath = "/tmp/sounding-live-user:pass@example.test?token=synthetic-secret#frag.json"
        let evidenceURL = temporaryEvidenceURL()
        defer { try? FileManager.default.removeItem(at: evidenceURL) }
        let capture = OutputCapture()
        let adapter = AppVerifyLiveCommandAdapter(
            configReader: { _ in Data(Self.liveConfigJSON(source: secretSource, streamType: "auto").utf8) },
            runnerFactory: { _ in FakeLiveRunner(evidence: Self.livePassingEvidence(secretSource: secretSource)) },
            standardOutput: { capture.stdout($0) },
            standardError: { capture.stderr($0) }
        )

        let exitCode = await adapter.run(configPath: secretConfigPath, jsonPath: evidenceURL.path)

        XCTAssertEqual(exitCode, .failure)
        XCTAssertEqual(capture.stdoutText, "")
        XCTAssertTrue(capture.stderrText.contains("App verification live configuration failed"), capture.stderrText)
        XCTAssertTrue(capture.stderrText.contains("auto stream type could not be resolved"), capture.stderrText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path), capture.stderrText)
        assertSanitized(capture.stderrText, forbiddenLiteral: secretSource)
        assertSanitized(capture.stderrText, forbiddenLiteral: secretConfigPath)
        assertSanitized(capture.stderrText, forbiddenLiteral: "user:pass")
        assertSanitized(capture.stderrText, forbiddenLiteral: "synthetic-secret")
    }

    func testLivePassingEvidenceWritesJSONAndExitsZero() async throws {
        let secretSource = "https://user:pass@example.test/live.m3u8?token=synthetic-secret#frag"
        let secretConfigPath = "/tmp/sounding-live-config-user:pass@example.test?token=synthetic-secret#frag.json"
        let evidenceURL = temporaryEvidenceURL()
        defer { try? FileManager.default.removeItem(at: evidenceURL) }
        let capture = OutputCapture()
        let adapter = AppVerifyLiveCommandAdapter(
            configReader: { _ in Data(Self.liveConfigJSON(source: secretSource, streamType: "hls").utf8) },
            runnerFactory: { configuration in
                XCTAssertEqual(configuration.configPath, secretConfigPath)
                return FakeLiveRunner(evidence: Self.livePassingEvidence(secretSource: secretSource))
            },
            standardOutput: { capture.stdout($0) },
            standardError: { capture.stderr($0) }
        )

        let exitCode = await adapter.run(configPath: secretConfigPath, jsonPath: evidenceURL.path)

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(capture.stderrText, "")
        XCTAssertEqual(capture.stdoutLines.count, 1)
        XCTAssertTrue(capture.stdoutText.contains("app verification passed"), capture.stdoutText)
        XCTAssertTrue(capture.stdoutText.contains("status=pass"), capture.stdoutText)
        assertSanitized(capture.stdoutText, forbiddenLiteral: secretSource)
        assertSanitized(capture.stdoutText, forbiddenLiteral: secretConfigPath)
        assertSanitized(capture.stdoutText, forbiddenLiteral: evidenceURL.path)

        let evidenceText = try String(contentsOf: evidenceURL)
        XCTAssertTrue(evidenceText.contains("live_stream_registered"), evidenceText)
        XCTAssertTrue(evidenceText.contains("livePlayback" ) || evidenceText.contains("live_playback_scheduled"), evidenceText)
        XCTAssertTrue(evidenceText.contains("[redacted"), evidenceText)
        assertSanitized(evidenceText, forbiddenLiteral: secretSource)
        assertSanitized(evidenceText, forbiddenLiteral: secretConfigPath)
        assertSanitized(evidenceText, forbiddenLiteral: evidenceURL.path)
        assertSanitized(evidenceText, forbiddenLiteral: "user:pass")
        assertSanitized(evidenceText, forbiddenLiteral: "synthetic-secret")
        let decoded = try JSONDecoder().decode(AppVerifyEvidence.self, from: Data(evidenceText.utf8))
        XCTAssertEqual(decoded.summary.status, .pass)
    }

    func testLiveWarningEvidenceWritesJSONAndExitsZero() async throws {
        let secretSource = "https://user:pass@example.test/live.m3u8?token=synthetic-secret#frag"
        let evidenceURL = temporaryEvidenceURL()
        defer { try? FileManager.default.removeItem(at: evidenceURL) }
        let capture = OutputCapture()
        let adapter = AppVerifyLiveCommandAdapter(
            configReader: { _ in Data(Self.liveConfigJSON(source: secretSource, streamType: "hls").utf8) },
            runnerFactory: { _ in FakeLiveRunner(evidence: Self.liveWarningEvidence(secretSource: secretSource)) },
            standardOutput: { capture.stdout($0) },
            standardError: { capture.stderr($0) }
        )

        let exitCode = await adapter.run(configPath: "/tmp/private-config.json", jsonPath: evidenceURL.path)

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(capture.stderrText, "")
        XCTAssertEqual(capture.stdoutLines.count, 1)
        XCTAssertTrue(capture.stdoutText.contains("app verification warned"), capture.stdoutText)
        XCTAssertTrue(capture.stdoutText.contains("status=warn"), capture.stdoutText)
        XCTAssertTrue(capture.stdoutText.contains("warnings=1"), capture.stdoutText)
        let decoded = try JSONDecoder().decode(AppVerifyEvidence.self, from: Data(contentsOf: evidenceURL))
        XCTAssertEqual(decoded.summary.status, .warn)
        assertSanitized(capture.stdoutText, forbiddenLiteral: secretSource)
    }

    func testLiveFailedEvidenceWritesJSONThenReturnsNonZeroWithFailedCheckNames() async throws {
        let secretSource = "https://user:pass@example.test/live.m3u8?token=synthetic-secret#frag"
        let evidenceURL = temporaryEvidenceURL()
        defer { try? FileManager.default.removeItem(at: evidenceURL) }
        let capture = OutputCapture()
        let adapter = AppVerifyLiveCommandAdapter(
            configReader: { _ in Data(Self.liveConfigJSON(source: secretSource, streamType: "hls").utf8) },
            runnerFactory: { _ in FakeLiveRunner(evidence: Self.liveFailedEvidence(secretSource: secretSource)) },
            standardOutput: { capture.stdout($0) },
            standardError: { capture.stderr($0) }
        )

        let exitCode = await adapter.run(configPath: "/tmp/private-config.json", jsonPath: evidenceURL.path)

        XCTAssertEqual(exitCode, .failure)
        XCTAssertEqual(capture.stderrText, "")
        XCTAssertEqual(capture.stdoutLines.count, 1)
        XCTAssertTrue(capture.stdoutText.contains("app verification failed"), capture.stdoutText)
        XCTAssertTrue(capture.stdoutText.contains("requiredFailures=1"), capture.stdoutText)
        XCTAssertTrue(capture.stdoutText.contains("live_decode_opened:live_decode:required"), capture.stdoutText)
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidenceURL.path), capture.stdoutText)
        let decoded = try JSONDecoder().decode(AppVerifyEvidence.self, from: Data(contentsOf: evidenceURL))
        XCTAssertEqual(decoded.summary.status, .fail)
        assertSanitized(capture.stdoutText, forbiddenLiteral: secretSource)
        assertSanitized(capture.stdoutText, forbiddenLiteral: evidenceURL.path)
    }

    func testLiveUnwritableJSONPathFailsWithoutPathLeakageOrPartialEvidence() async throws {
        let secretSource = "https://user:pass@example.test/live.m3u8?token=synthetic-secret#frag"
        let secretDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-app-verify-live-user:pass@example.test?token=synthetic-secret#frag-")
            .appendingPathExtension(UUID().uuidString)
        let evidenceURL = secretDirectory.appendingPathComponent("evidence.json")
        defer { try? FileManager.default.removeItem(at: secretDirectory) }
        let capture = OutputCapture()
        let adapter = AppVerifyLiveCommandAdapter(
            configReader: { _ in Data(Self.liveConfigJSON(source: secretSource, streamType: "hls").utf8) },
            runnerFactory: { _ in FakeLiveRunner(evidence: Self.livePassingEvidence(secretSource: secretSource)) },
            standardOutput: { capture.stdout($0) },
            standardError: { capture.stderr($0) }
        )

        let exitCode = await adapter.run(configPath: "/tmp/private-config.json", jsonPath: evidenceURL.path)

        XCTAssertEqual(exitCode, .failure)
        XCTAssertEqual(capture.stdoutText, "")
        XCTAssertTrue(capture.stderrText.contains("App verification output failed"), capture.stderrText)
        XCTAssertTrue(capture.stderrText.contains("redacted output path"), capture.stderrText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path), capture.stderrText)
        assertSanitized(capture.stderrText, forbiddenLiteral: evidenceURL.path)
        assertSanitized(capture.stderrText, forbiddenLiteral: secretDirectory.path)
        assertSanitized(capture.stderrText, forbiddenLiteral: "user:pass")
        assertSanitized(capture.stderrText, forbiddenLiteral: "synthetic-secret")
        assertSanitized(capture.stderrText, forbiddenLiteral: "evidence.json")
    }

    /// Manual real-device proof for S03: run
    /// `swift run sounding app-verify fixture --json /tmp/sounding-app-verify-s03.json`
    /// on a macOS host with a usable AVFoundation output device; failed evidence should still be written
    /// and should identify the failing runtime/playback/control/diagnostics/projection phase without leaking raw sources.

    private static func passingEvidence() -> AppVerifyEvidence {
        AppVerifyEvidence(
            generatedAt: "2026-05-02T18:00:00Z",
            runID: "test-run",
            checks: passingChecks(),
            runtimeFacts: AppVerifyRuntimeFacts(
                phase: .diagnostics,
                processedChunks: 1,
                decodedChunks: 1,
                scheduledBuffers: 1,
                diagnosticCount: 8,
                recentDiagnosticEvents: [
                    "playback.prepare.succeeded",
                    "playback.play.scheduled",
                    "runtime.mute.requested",
                    "runtime.volume.requested",
                    "playback.volume.applied",
                    "runtime.stop.requested",
                    "runtime.start.requested",
                ],
                timelineSnapshotFields: ["decodedFrameCount": "1", "scheduledBufferCount": "1"]
            )
        )
    }

    private static func failedEvidence(secretSource: String) -> AppVerifyEvidence {
        var checks = passingChecks()
        checks.removeAll { $0.name == .playbackMuted }
        checks.append(
            AppVerifyCheckEvaluator.controlObserved(
                .playbackMuted,
                requestedAction: "mute \(secretSource)",
                observedRuntimePhase: .playbackControl,
                timelineState: "playing",
                volume: 0.75,
                muted: false,
                effectiveVolume: 0.75,
                diagnostics: [
                    AppVerifyParsedDiagnosticEntry(
                        event: "runtime.mute.requested",
                        phase: "runtime.volume",
                        streamID: 1,
                        message: "mute requested for \(secretSource)",
                        fields: ["source": secretSource]
                    ),
                ],
                requiredDiagnosticEvents: ["runtime.mute.requested", "playback.volume.applied"],
                beforeMarker: secretSource,
                afterMarker: secretSource
            )
        )
        return AppVerifyEvidence(
            generatedAt: "2026-05-02T18:00:00Z",
            runID: "token=synthetic-secret",
            checks: checks,
            artifacts: [
                AppVerifyRedactedArtifact(kind: "stream-source", path: secretSource),
                AppVerifyRedactedArtifact(kind: "runtime-events", path: "/tmp/sounding-app-verify/runtime-events.jsonl"),
            ],
            metadata: ["source": secretSource]
        )
    }

    private static func liveConfigJSON(source: String, streamType: String) -> String {
        """
        {
          "streams": [
            {
              "id": "main-live",
              "source": "\(source)",
              "streamType": "\(streamType)",
              "timeoutSeconds": 0.1,
              "maxChunks": 1,
              "required": true,
              "expectations": {
                "transcript": "warn",
                "metadata": "warn"
              }
            }
          ]
        }
        """
    }

    private static func livePassingEvidence(secretSource: String) -> AppVerifyEvidence {
        AppVerifyEvidence(
            generatedAt: "2026-05-02T18:00:00Z",
            runID: "live-run-token=synthetic-secret",
            checks: liveBaseChecks(secretSource: secretSource),
            artifacts: [
                AppVerifyRedactedArtifact(kind: "live-config", path: "/tmp/sounding-live-config-user:pass@example.test?token=synthetic-secret#frag.json"),
                AppVerifyRedactedArtifact(kind: "stream-source", path: secretSource),
            ],
            metadata: ["configPath": "/tmp/sounding-live-config-user:pass@example.test?token=synthetic-secret#frag.json"]
        )
    }

    private static func liveWarningEvidence(secretSource: String) -> AppVerifyEvidence {
        var checks = liveBaseChecks(secretSource: secretSource)
        checks.append(AppVerifyCheckEvaluator.liveTranscriptExpectation(
            observedCount: 0,
            expectation: .warn,
            required: true,
            streamID: "main-live",
            source: secretSource,
            facts: liveFacts(secretSource: secretSource, transcriptCount: 0, metadataCount: 1)
        ))
        return AppVerifyEvidence(
            generatedAt: "2026-05-02T18:00:00Z",
            runID: "live-warn-token=synthetic-secret",
            checks: checks,
            artifacts: [AppVerifyRedactedArtifact(kind: "stream-source", path: secretSource)]
        )
    }

    private static func liveFailedEvidence(secretSource: String) -> AppVerifyEvidence {
        var checks = liveBaseChecks(secretSource: secretSource)
        checks.removeAll { $0.name == .liveDecodeOpened }
        checks.append(.fail(
            .liveDecodeOpened,
            phase: .liveDecode,
            reason: "Live decode failed for \(secretSource)",
            liveFacts: liveFacts(secretSource: secretSource, processedChunks: 0, decodedChunks: 0),
            artifacts: [AppVerifyRedactedArtifact(kind: "stream-source", path: secretSource)]
        ))
        return AppVerifyEvidence(
            generatedAt: "2026-05-02T18:00:00Z",
            runID: "live-fail-token=synthetic-secret",
            checks: checks,
            artifacts: [AppVerifyRedactedArtifact(kind: "stream-source", path: secretSource)]
        )
    }

    private static func liveBaseChecks(secretSource: String) -> [AppVerifyCheckRecord] {
        let facts = liveFacts(secretSource: secretSource)
        return [
            .pass(.liveConfigValidated, phase: .liveConfig),
            .pass(.liveStreamRegistered, phase: .liveRegistration, liveFacts: facts),
            .pass(.liveRuntimeStarted, phase: .liveRuntimeStart, liveFacts: facts),
            .pass(.liveDecodeOpened, phase: .liveDecode, liveFacts: facts),
            .pass(.livePlaybackScheduled, phase: .livePlayback, liveFacts: facts),
            .pass(.liveRuntimeStopped, phase: .liveStop, liveFacts: facts),
            .pass(.liveDiagnosticsWritten, phase: .liveDiagnostics, liveFacts: facts),
            AppVerifyCheckEvaluator.liveTranscriptExpectation(
                observedCount: 1,
                expectation: .warn,
                required: true,
                streamID: "main-live",
                source: secretSource,
                facts: facts
            ),
            AppVerifyCheckEvaluator.liveMetadataExpectation(
                observedCount: 1,
                expectation: .warn,
                required: true,
                streamID: "main-live",
                source: secretSource,
                facts: facts
            ),
        ]
    }

    private static func liveFacts(
        secretSource: String,
        processedChunks: Int = 1,
        decodedChunks: Int = 1,
        transcriptCount: Int = 1,
        metadataCount: Int = 1
    ) -> AppVerifyLiveStreamFacts {
        AppVerifyLiveStreamFacts(
            streamID: "main-live",
            streamType: .hls,
            resolvedStreamType: .hls,
            source: secretSource,
            timeoutSeconds: 0.1,
            maxChunks: 1,
            required: true,
            transcriptExpectation: .warn,
            metadataExpectation: .warn,
            registeredStreamID: 1,
            processedChunks: processedChunks,
            decodedChunks: decodedChunks,
            scheduledBuffers: decodedChunks,
            transcriptCount: transcriptCount,
            metadataCount: metadataCount,
            diagnosticCount: 2,
            recentDiagnosticEvents: ["runtime.start.requested", "playback.play.scheduled"],
            fields: [
                "diagnosticsPath": "/tmp/sounding-live-diagnostics-user:pass@example.test?token=synthetic-secret#frag.jsonl",
                "source": secretSource,
            ]
        )
    }

    private static func passingChecks() -> [AppVerifyCheckRecord] {
        [
            .pass(.fixtureSourceCreated, phase: .fixture),
            .pass(.databaseOpened, phase: .database),
            .pass(.streamRegistered, phase: .registration),
            .pass(.runtimeStarted, phase: .runtimeStart),
            AppVerifyCheckEvaluator.decodeCompleted(processedChunks: 1, decodedChunks: 1),
            AppVerifyCheckEvaluator.playbackScheduled(
                scheduledBuffers: 1,
                diagnosticEvents: ["playback.prepare.succeeded", "playback.play.scheduled"]
            ),
            .pass(.runtimeStopped, phase: .runtimeStop),
            .pass(.diagnosticsWritten, phase: .diagnostics),
            AppVerifyCheckEvaluator.controlObserved(
                .playbackMuted,
                requestedAction: "mute",
                observedRuntimePhase: .playbackControl,
                timelineState: "playing",
                volume: 0.75,
                muted: true,
                effectiveVolume: 0,
                diagnostics: [
                    AppVerifyParsedDiagnosticEntry(event: "runtime.mute.requested", phase: "runtime.volume", streamID: 1),
                    AppVerifyParsedDiagnosticEntry(event: "playback.volume.applied", phase: "playback.volume", streamID: 1),
                ],
                requiredDiagnosticEvents: ["runtime.mute.requested", "playback.volume.applied"]
            ),
            AppVerifyCheckEvaluator.controlObserved(
                .playbackUnmuted,
                requestedAction: "unmute",
                observedRuntimePhase: .playbackControl,
                timelineState: "playing",
                volume: 0.75,
                muted: false,
                effectiveVolume: 0.75,
                diagnostics: [
                    AppVerifyParsedDiagnosticEntry(event: "runtime.mute.requested", phase: "runtime.volume", streamID: 1),
                    AppVerifyParsedDiagnosticEntry(event: "playback.volume.applied", phase: "playback.volume", streamID: 1),
                ],
                requiredDiagnosticEvents: ["runtime.mute.requested", "playback.volume.applied"]
            ),
            AppVerifyCheckEvaluator.controlObserved(
                .playbackVolumeChanged,
                requestedAction: "volume",
                observedRuntimePhase: .playbackControl,
                timelineState: "playing",
                volume: 0.25,
                muted: false,
                effectiveVolume: 0.25,
                diagnostics: [
                    AppVerifyParsedDiagnosticEntry(event: "runtime.volume.requested", phase: "runtime.volume", streamID: 1),
                    AppVerifyParsedDiagnosticEntry(event: "playback.volume.applied", phase: "playback.volume", streamID: 1),
                ],
                requiredDiagnosticEvents: ["runtime.volume.requested", "playback.volume.applied"]
            ),
            AppVerifyCheckEvaluator.controlObserved(
                .runtimeStopObserved,
                requestedAction: "stop",
                observedRuntimePhase: .runtimeStop,
                timelineState: "stopped",
                diagnostics: [
                    AppVerifyParsedDiagnosticEntry(event: "runtime.stop.requested", phase: "runtime.stop", streamID: 1),
                    AppVerifyParsedDiagnosticEntry(event: "playback.stop.applied", phase: "playback.stop", streamID: 1),
                ],
                requiredDiagnosticEvents: ["runtime.stop.requested", "playback.stop.applied"]
            ),
            AppVerifyCheckEvaluator.controlObserved(
                .runtimeRestartObserved,
                requestedAction: "restart",
                observedRuntimePhase: .runtimeRestart,
                timelineState: "playing",
                diagnostics: [
                    AppVerifyParsedDiagnosticEntry(event: "runtime.start.requested", phase: "runtime.start", streamID: 1),
                    AppVerifyParsedDiagnosticEntry(event: "playback.play.scheduled", phase: "playback.play", streamID: 1),
                ],
                requiredDiagnosticEvents: ["runtime.start.requested", "playback.play.scheduled"]
            ),
            AppVerifyCheckEvaluator.projectionPopulated(
                .transcriptPersistence,
                surface: "transcript persistence",
                rowCount: 2,
                sampleFields: ["persistedRows": "2"]
            ),
            AppVerifyCheckEvaluator.projectionPopulated(
                .transcriptTimelineProjection,
                surface: "transcript timeline",
                projectionCount: 2,
                sampleFields: ["timelineItems": "2"]
            ),
            AppVerifyCheckEvaluator.projectionPopulated(
                .transcriptSearchProjection,
                surface: "transcript search",
                projectionCount: 1,
                sampleFields: ["searchResults": "1"]
            ),
            AppVerifyCheckEvaluator.projectionPopulated(
                .songMetadataProjection,
                surface: "song metadata",
                metadataCount: 1,
                sampleFields: ["titlePresent": "true", "artistPresent": "true"]
            ),
            AppVerifyCheckEvaluator.projectionPopulated(
                .adMetadataProjection,
                surface: "ad metadata",
                metadataCount: 1,
                sampleFields: ["adMarkers": "1"]
            ),
        ]
    }

    private func temporaryEvidenceURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-app-verify-evidence-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }

    private func assertSanitized(
        _ text: String,
        forbiddenLiteral: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            text.contains(forbiddenLiteral),
            "Expected output to redact forbidden literal '\(forbiddenLiteral)', got: \(text)",
            file: file,
            line: line
        )
    }
}

private final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutMessages: [String] = []
    private var stderrMessages: [String] = []

    func stdout(_ message: String) {
        lock.lock()
        stdoutMessages.append(message)
        lock.unlock()
    }

    func stderr(_ message: String) {
        lock.lock()
        stderrMessages.append(message)
        lock.unlock()
    }

    var stdoutText: String {
        lock.lock()
        defer { lock.unlock() }
        return stdoutMessages.map { $0 + "\n" }.joined()
    }

    var stderrText: String {
        lock.lock()
        defer { lock.unlock() }
        return stderrMessages.map { $0 + "\n" }.joined()
    }

    var stdoutLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stdoutMessages
    }
}


private struct FakeLiveRunner: AppVerifyLiveRunning {
    var evidence: AppVerifyEvidence

    func run() async -> AppVerifyEvidence { evidence }
}
