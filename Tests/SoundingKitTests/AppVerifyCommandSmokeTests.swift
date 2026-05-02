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
        XCTAssertTrue(result.stderrText.contains("Unknown subcommand"), result.diagnosticSummary)
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
        let decoded = try JSONDecoder().decode(AppVerifyEvidence.self, from: Data(evidenceText.utf8))
        XCTAssertEqual(decoded.summary.status, .pass)
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
        XCTAssertTrue(capture.stdoutText.contains("database_opened:database:required"), capture.stdoutText)
        assertSanitized(capture.stdoutText, forbiddenLiteral: secretSource)
        assertSanitized(capture.stdoutText, forbiddenLiteral: evidenceURL.path)

        let evidenceText = try String(contentsOf: evidenceURL)
        XCTAssertTrue(evidenceText.contains("database_opened"), evidenceText)
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

        XCTAssertTrue(line.contains("fixture_source_created:fixture:required"), line)
        assertSanitized(line, forbiddenLiteral: secretSource)
        assertSanitized(line, forbiddenLiteral: "user:pass")
        assertSanitized(line, forbiddenLiteral: "synthetic-secret")
        assertSanitized(line, forbiddenLiteral: "private-fragment")
    }

    /// Manual real-device proof for S01: run
    /// `swift run sounding app-verify fixture --json /tmp/sounding-app-verify-fixture.json`
    /// on a macOS host with a usable AVFoundation output device; failed evidence should still be written
    /// and should identify the failing runtime/playback/diagnostics phase without leaking raw sources.

    private static func passingEvidence() -> AppVerifyEvidence {
        AppVerifyEvidence(
            generatedAt: "2026-05-02T18:00:00Z",
            runID: "test-run",
            checks: [
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
            ],
            runtimeFacts: AppVerifyRuntimeFacts(
                phase: .diagnostics,
                processedChunks: 1,
                decodedChunks: 1,
                scheduledBuffers: 1,
                diagnosticCount: 2,
                recentDiagnosticEvents: ["playback.prepare.succeeded", "playback.play.scheduled"],
                timelineSnapshotFields: ["decodedFrameCount": "1"]
            )
        )
    }

    private static func failedEvidence(secretSource: String) -> AppVerifyEvidence {
        AppVerifyEvidence(
            generatedAt: "2026-05-02T18:00:00Z",
            runID: "token=synthetic-secret",
            checks: [
                .pass(.fixtureSourceCreated, phase: .fixture),
                .fail(
                    .databaseOpened,
                    phase: .database,
                    reason: "could not open temporary database for \(secretSource)"
                ),
            ],
            artifacts: [
                AppVerifyRedactedArtifact(kind: "stream-source", path: secretSource),
            ],
            metadata: ["source": secretSource]
        )
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
