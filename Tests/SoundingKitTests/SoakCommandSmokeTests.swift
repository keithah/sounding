import Foundation
import XCTest

final class SoakCommandSmokeTests: XCTestCase {
    func testHelpAdvertisesSoakProofOptions() throws {
        let root = try CLIRunner().runSounding(arguments: ["--help"])
        XCTAssertEqual(root.exitCode, 0, root.diagnosticSummary)
        XCTAssertTrue(root.stdoutText.contains("soak"), root.diagnosticSummary)

        let soak = try CLIRunner().runSounding(arguments: ["soak", "--help"])
        XCTAssertEqual(soak.exitCode, 0, soak.diagnosticSummary)
        XCTAssertTrue(soak.stdoutText.contains("proof"), soak.diagnosticSummary)

        let proof = try CLIRunner().runSounding(arguments: ["soak", "proof", "--help"])
        XCTAssertEqual(proof.exitCode, 0, proof.diagnosticSummary)
        for option in ["--db", "--evidence-out", "--duration-seconds", "--sample-interval-seconds", "--format", "--json"] {
            XCTAssertTrue(proof.stdoutText.contains(option), "Expected help to advertise \(option). \(proof.diagnosticSummary)")
        }
    }

    func testJSONSuccessDecodesWritesEvidenceAndRedactsPathsAndSecrets() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "json-user:pass@example.test?token=synthetic-secret#frag")
        let evidenceURL = temporaryEvidenceURL(secretComponent: "json-user:pass@example.test?token=synthetic-secret#frag", extension: "json")
        defer { cleanup(dbURL: dbURL, evidenceURL: evidenceURL) }

        let result = try CLIRunner().runSounding(arguments: [
            "soak", "proof",
            "--db", dbURL.path,
            "--evidence-out", evidenceURL.path,
            "--duration-seconds", "0.1",
            "--sample-interval-seconds", "0.1",
            "--json"
        ])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stderr.count, 0, result.diagnosticSummary)
        let summary = try result.decodeJSON(Summary.self)
        XCTAssertEqual(summary.ok, true, result.diagnosticSummary)
        XCTAssertEqual(summary.verdict, "pass", result.diagnosticSummary)
        XCTAssertGreaterThanOrEqual(summary.streamCount, 2, result.diagnosticSummary)
        XCTAssertGreaterThanOrEqual(summary.reconnectCount, 1, result.diagnosticSummary)
        XCTAssertGreaterThan(summary.queueMaxDepth, 0, result.diagnosticSummary)
        XCTAssertEqual(summary.databaseHealthStatus, "healthy", result.diagnosticSummary)
        XCTAssertEqual(summary.checkpointStatus, "healthy", result.diagnosticSummary)
        XCTAssertEqual(summary.failureCount, 0, result.diagnosticSummary)
        XCTAssertEqual(summary.redactionAuditStatus, "pass", result.diagnosticSummary)

        let evidenceData = try Data(contentsOf: evidenceURL)
        let evidence = try JSONDecoder().decode(Evidence.self, from: evidenceData)
        XCTAssertEqual(evidence.summary.verdict, "pass")
        XCTAssertEqual(evidence.redactionAudit.passed, true)
        XCTAssertGreaterThanOrEqual(evidence.streams.count, 2)
        XCTAssertTrue(evidence.runtimeEvents.contains { $0.phase == "reconnecting" })
        XCTAssertTrue(evidence.queueSnapshots.contains { $0.maxDepth > 0 })
        XCTAssertTrue(evidence.databaseSnapshots.contains { $0.status == "healthy" })
        assertNoForbiddenSoakCommandSubstrings(result.stdoutText + result.stderrText + String(decoding: evidenceData, as: UTF8.self), dbURL: dbURL, evidenceURL: evidenceURL)
    }

    func testNDJSONSuccessWritesOneRedactedEvidenceObject() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "ndjson-token=synthetic-secret")
        let evidenceURL = temporaryEvidenceURL(secretComponent: "ndjson-token=synthetic-secret", extension: "ndjson")
        defer { cleanup(dbURL: dbURL, evidenceURL: evidenceURL) }

        let result = try CLIRunner().runSounding(arguments: [
            "soak", "proof",
            "--db", dbURL.path,
            "--evidence-out", evidenceURL.path,
            "--duration-seconds", "0.1",
            "--sample-interval-seconds", "0.1",
            "--format", "ndjson",
            "--json"
        ])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        let evidenceText = try String(contentsOf: evidenceURL)
        let lines = evidenceText.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1, evidenceText)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertNotNil(object["summary"], evidenceText)
        XCTAssertFalse(evidenceText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("["), evidenceText)
        assertNoForbiddenSoakCommandSubstrings(result.stdoutText + result.stderrText + evidenceText, dbURL: dbURL, evidenceURL: evidenceURL)
    }

    func testInvalidNumericOptionsAndUnsupportedFormatFailBeforeDatabaseWork() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "invalid-token=synthetic-secret")
        let evidenceURL = temporaryEvidenceURL(secretComponent: "invalid-token=synthetic-secret", extension: "json")
        defer { cleanup(dbURL: dbURL, evidenceURL: evidenceURL) }

        let invalidDuration = try CLIRunner().runSounding(arguments: [
            "soak", "proof", "--db", dbURL.path, "--evidence-out", evidenceURL.path, "--duration-seconds", "0"
        ])
        XCTAssertNotEqual(invalidDuration.exitCode, 0, invalidDuration.diagnosticSummary)
        XCTAssertEqual(invalidDuration.stdoutLineCount, 0, invalidDuration.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path), invalidDuration.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path), invalidDuration.diagnosticSummary)
        assertNoForbiddenSoakCommandSubstrings(invalidDuration.stdoutText + invalidDuration.stderrText, dbURL: dbURL, evidenceURL: evidenceURL)

        let invalidInterval = try CLIRunner().runSounding(arguments: [
            "soak", "proof", "--db", dbURL.path, "--evidence-out", evidenceURL.path, "--sample-interval-seconds", "nan"
        ])
        XCTAssertNotEqual(invalidInterval.exitCode, 0, invalidInterval.diagnosticSummary)
        XCTAssertEqual(invalidInterval.stdoutLineCount, 0, invalidInterval.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path), invalidInterval.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path), invalidInterval.diagnosticSummary)
        assertNoForbiddenSoakCommandSubstrings(invalidInterval.stdoutText + invalidInterval.stderrText, dbURL: dbURL, evidenceURL: evidenceURL)

        let unsupportedFormat = try CLIRunner().runSounding(arguments: [
            "soak", "proof", "--db", dbURL.path, "--evidence-out", evidenceURL.path, "--format", "xml"
        ])
        XCTAssertNotEqual(unsupportedFormat.exitCode, 0, unsupportedFormat.diagnosticSummary)
        XCTAssertEqual(unsupportedFormat.stdoutLineCount, 0, unsupportedFormat.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path), unsupportedFormat.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path), unsupportedFormat.diagnosticSummary)
        assertNoForbiddenSoakCommandSubstrings(unsupportedFormat.stdoutText + unsupportedFormat.stderrText, dbURL: dbURL, evidenceURL: evidenceURL)
    }

    func testInaccessibleDatabaseFailsWithRedactedGuidanceBeforeEvidenceWrite() throws {
        let secretDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-soak-db-user:pass@example.test?token=synthetic-secret#frag", isDirectory: true)
        let dbURL = secretDirectory.appendingPathComponent("private.sqlite")
        let evidenceURL = temporaryEvidenceURL(secretComponent: "db-open-token=synthetic-secret", extension: "json")
        defer { cleanup(dbURL: dbURL, evidenceURL: evidenceURL); try? FileManager.default.removeItem(at: secretDirectory) }

        let result = try CLIRunner().runSounding(arguments: [
            "soak", "proof", "--db", dbURL.path, "--evidence-out", evidenceURL.path, "--json"
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path), result.diagnosticSummary)
        XCTAssertTrue(result.stderrText.contains("Soak proof database failed"), result.diagnosticSummary)
        XCTAssertTrue(result.stderrText.contains("redacted database path"), result.diagnosticSummary)
        assertNoForbiddenSoakCommandSubstrings(result.stdoutText + result.stderrText, dbURL: dbURL, evidenceURL: evidenceURL)
    }

    func testUnwritableEvidencePathFailsWithoutLeakingOutputPathOrLeavingPartialEvidence() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "output-db-token=synthetic-secret")
        let secretDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-soak-output-user:pass@example.test?token=synthetic-secret#frag", isDirectory: true)
        let evidenceURL = secretDirectory.appendingPathComponent("private-soak-evidence.json")
        defer { cleanup(dbURL: dbURL, evidenceURL: evidenceURL); try? FileManager.default.removeItem(at: secretDirectory) }

        let result = try CLIRunner().runSounding(arguments: [
            "soak", "proof",
            "--db", dbURL.path,
            "--evidence-out", evidenceURL.path,
            "--duration-seconds", "0.1",
            "--sample-interval-seconds", "0.1"
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path), result.diagnosticSummary)
        XCTAssertTrue(result.stderrText.contains("Soak proof output failed"), result.diagnosticSummary)
        XCTAssertTrue(result.stderrText.contains("redacted output path"), result.diagnosticSummary)
        assertNoForbiddenSoakCommandSubstrings(result.stdoutText + result.stderrText, dbURL: dbURL, evidenceURL: evidenceURL)
    }

    func testThresholdFailureWritesRedactedEvidenceThenExitsNonZero() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "threshold-token=synthetic-secret")
        let evidenceURL = temporaryEvidenceURL(secretComponent: "threshold-token=synthetic-secret", extension: "json")
        defer { cleanup(dbURL: dbURL, evidenceURL: evidenceURL) }

        let result = try CLIRunner().runSounding(arguments: [
            "soak", "proof",
            "--db", dbURL.path,
            "--evidence-out", evidenceURL.path,
            "--duration-seconds", "0.1",
            "--sample-interval-seconds", "0.1",
            "--maximum-queue-depth", "0",
            "--json"
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stderr.count, 0, result.diagnosticSummary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidenceURL.path), result.diagnosticSummary)
        let summary = try result.decodeJSON(Summary.self)
        XCTAssertEqual(summary.ok, false, result.diagnosticSummary)
        XCTAssertEqual(summary.verdict, "fail", result.diagnosticSummary)
        XCTAssertGreaterThan(summary.failureCount, 0, result.diagnosticSummary)

        let evidenceData = try Data(contentsOf: evidenceURL)
        let evidence = try JSONDecoder().decode(Evidence.self, from: evidenceData)
        XCTAssertEqual(evidence.summary.verdict, "fail")
        XCTAssertTrue(evidence.thresholds.contains { $0.name == "queueMaxDepth" && $0.status == "fail" })
        XCTAssertEqual(evidence.redactionAudit.passed, true)
        assertNoForbiddenSoakCommandSubstrings(result.stdoutText + result.stderrText + String(decoding: evidenceData, as: UTF8.self), dbURL: dbURL, evidenceURL: evidenceURL)
    }

    private struct Summary: Decodable {
        var ok: Bool
        var verdict: String
        var streamCount: Int
        var reconnectCount: Int
        var queueMaxDepth: Int
        var databaseHealthStatus: String
        var checkpointStatus: String
        var failureCount: Int
        var redactionAuditStatus: String
    }

    private struct Evidence: Decodable {
        var summary: EvidenceSummary
        var streams: [Stream]
        var runtimeEvents: [RuntimeEvent]
        var queueSnapshots: [QueueSnapshot]
        var databaseSnapshots: [DatabaseSnapshot]
        var thresholds: [Threshold]
        var redactionAudit: RedactionAudit
    }

    private struct EvidenceSummary: Decodable { var verdict: String }
    private struct Stream: Decodable { var sourceDescription: String }
    private struct RuntimeEvent: Decodable { var phase: String; var reason: String }
    private struct QueueSnapshot: Decodable { var maxDepth: Int }
    private struct DatabaseSnapshot: Decodable { var status: String? }
    private struct Threshold: Decodable { var name: String; var status: String }
    private struct RedactionAudit: Decodable { var passed: Bool }

    private func temporaryDatabaseURL(secretComponent: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-soak-db-\(secretComponent)-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func temporaryEvidenceURL(secretComponent: String, extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-proof-\(secretComponent)-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }

    private func cleanup(dbURL: URL, evidenceURL: URL) {
        for path in [dbURL.path, dbURL.path + "-wal", dbURL.path + "-shm", evidenceURL.path, evidenceURL.path + ".tmp"] {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func assertNoForbiddenSoakCommandSubstrings(
        _ text: String,
        dbURL: URL,
        evidenceURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let forbidden = [
            dbURL.path,
            dbURL.deletingLastPathComponent().path,
            evidenceURL.path,
            evidenceURL.deletingLastPathComponent().path,
            "token=",
            "synthetic-secret",
            "user:pass",
            "#frag",
            ".sqlite",
            ".wal",
            ".shm",
            "-wal",
            "-shm",
            "/tmp/",
            "/private/tmp/",
            "/Users/",
            "private-soak-evidence",
            "SQLite error",
            "GRDB"
        ]
        let lowercased = text.lowercased()
        for literal in forbidden {
            let candidate = literal.lowercased()
            XCTAssertFalse(
                lowercased.contains(candidate),
                "Expected soak command output/evidence to redact forbidden literal '\(literal)', got: \(text)",
                file: file,
                line: line
            )
        }
    }
}
