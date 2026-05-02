import Foundation
import XCTest

final class DistributionScriptSmokeTests: XCTestCase {
    func testHelpDocumentsCredentialSafeReadinessUsage() throws {
        let result = try runCheck(["--help"])
        XCTAssertEqual(result.exitCode, 0, result.sanitizedDiagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("Usage: scripts/distribution/check"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("--json"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("--developer-id-identity <selector>"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("--notary-profile <profile>"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("Credential-gated checks are skipped"), result.sanitizedDiagnosticSummary)
        XCTAssertFalse(result.stdoutText.localizedCaseInsensitiveContains(".env"), "Help must not ask users to store credentials in env files. \(result.sanitizedDiagnosticSummary)")
        assertNoForbiddenDistributionSubstrings(result.stdoutText + result.stderrText)
    }

    func testJSONOutputDecodesAndReportsRequiredPhasesWithoutCredentials() throws {
        let result = try runCheck(["--json"])
        XCTAssertEqual(result.exitCode, 0, result.sanitizedDiagnosticSummary)
        XCTAssertEqual(result.stderrText, "", result.sanitizedDiagnosticSummary)
        let report = try result.decodeJSON(CheckReport.self)
        XCTAssertEqual(report.schemaVersion, 1, result.sanitizedDiagnosticSummary)
        XCTAssertFalse(report.checks.isEmpty, result.sanitizedDiagnosticSummary)
        XCTAssertTrue(report.checks.contains { $0.phase == "environment" }, result.sanitizedDiagnosticSummary)
        XCTAssertTrue(report.checks.contains { $0.phase == "signingIdentity" && $0.status == "skipped" }, result.sanitizedDiagnosticSummary)
        XCTAssertTrue(report.checks.contains { $0.phase == "notarySubmit" && $0.status == "skipped" }, result.sanitizedDiagnosticSummary)
        XCTAssertTrue(["ready", "missingCredential", "failed"].contains(report.overallStatus), result.sanitizedDiagnosticSummary)
        assertNoForbiddenDistributionSubstrings(result.stdoutText + result.stderrText)
    }

    func testMissingCredentialSelectorsProduceControlledStatusesWithoutLeakingSelectors() throws {
        let identitySelector = "DefinitelyMissingDeveloperIDSelectorForSmokeTest"
        let notaryProfile = "DefinitelyMissingNotaryProfileForSmokeTest"
        let result = try runCheck([
            "--json",
            "--developer-id-identity", identitySelector,
            "--notary-profile", notaryProfile,
        ])
        XCTAssertEqual(result.exitCode, 0, result.sanitizedDiagnosticSummary)
        let report = try result.decodeJSON(CheckReport.self)
        let credentialStatuses = Set(report.checks.filter { $0.phase == "signingIdentity" || $0.phase == "notarySubmit" }.map(\.status))
        XCTAssertFalse(credentialStatuses.isEmpty, result.sanitizedDiagnosticSummary)
        XCTAssertTrue(credentialStatuses.isSubset(of: Set(["ready", "missingCredential", "failed"])), result.sanitizedDiagnosticSummary)
        XCTAssertFalse(result.stdoutText.contains(identitySelector), result.sanitizedDiagnosticSummary)
        XCTAssertFalse(result.stdoutText.contains(notaryProfile), result.sanitizedDiagnosticSummary)
        assertNoForbiddenDistributionSubstrings(result.stdoutText + result.stderrText, additionalForbidden: [identitySelector, notaryProfile])
    }

    func testInvalidOptionsAndUnsupportedArchitecturesFailWithoutSensitiveEcho() throws {
        let unknown = try runCheck(["--not-a-real-option"])
        XCTAssertEqual(unknown.exitCode, 64, unknown.sanitizedDiagnosticSummary)
        XCTAssertTrue(unknown.stderrText.contains("unknown option"), unknown.sanitizedDiagnosticSummary)
        XCTAssertFalse(unknown.stderrText.contains("--not-a-real-option"), unknown.sanitizedDiagnosticSummary)

        let unsupportedArch = try runCheck(["--arch", "x86_64"])
        XCTAssertEqual(unsupportedArch.exitCode, 64, unsupportedArch.sanitizedDiagnosticSummary)
        XCTAssertTrue(unsupportedArch.stderrText.contains("unsupported architecture"), unsupportedArch.sanitizedDiagnosticSummary)

        let emptyIdentity = try runCheck(["--developer-id-identity", ""])
        XCTAssertEqual(emptyIdentity.exitCode, 64, emptyIdentity.sanitizedDiagnosticSummary)
        XCTAssertTrue(emptyIdentity.stderrText.contains("requires a non-empty value"), emptyIdentity.sanitizedDiagnosticSummary)
    }

    func testSecretLikeArgumentsAreRejectedAndNeverEchoed() throws {
        let secretBearingSelector = "Developer ID Application: Alice Example (ABCDE12345) alice@example.test /Users/alice/Sounding.xcarchive token=super-secret"
        let result = try runCheck(["--developer-id-identity", secretBearingSelector])
        XCTAssertEqual(result.exitCode, 64, result.sanitizedDiagnosticSummary)
        XCTAssertTrue(result.stderrText.contains("looks sensitive"), result.sanitizedDiagnosticSummary)
        XCTAssertFalse(result.stderrText.contains(secretBearingSelector), result.sanitizedDiagnosticSummary)
        assertNoForbiddenDistributionSubstrings(result.stdoutText + result.stderrText, additionalForbidden: [
            "Alice Example",
            "alice@example.test",
            "ABCDE12345",
            "super-secret",
            "token=",
        ])
    }

    private struct CheckReport: Decodable {
        var checks: [Check]
        var overallStatus: String
        var schemaVersion: Int
    }

    private struct Check: Decodable {
        var guidance: String
        var message: String
        var phase: String
        var status: String
    }

    private struct ScriptResult {
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
        var arguments: [String]

        var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
        var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }

        var sanitizedDiagnosticSummary: String {
            "exit=\(exitCode), timedOut=\(timedOut), args=\(Self.sanitizedArguments(arguments)), stdout=\(Self.sanitizedSnippet(from: stdout)), stderr=\(Self.sanitizedSnippet(from: stderr))"
        }

        func decodeJSON<T: Decodable>(_ type: T.Type, file: StaticString = #filePath, line: UInt = #line) throws -> T {
            do {
                return try JSONDecoder().decode(type, from: stdout)
            } catch {
                XCTFail("Failed to decode check JSON: \(error). \(sanitizedDiagnosticSummary)", file: file, line: line)
                throw CLIError.invalidJSON
            }
        }

        static func sanitizedSnippet(from data: Data, maxLength: Int = 500) -> String {
            var text = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            text = text
                .replacingOccurrences(of: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s]+"#, with: "<redacted-url>", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)(Developer ID Application:|Developer ID Installer:).*"#, with: "<redacted-developer-id>", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)(token|secret|password|profile)=([^\s&]+)"#, with: "$1=<redacted>", options: .regularExpression)
                .replacingOccurrences(of: #"(?<![A-Za-z0-9])(?:/Users|/private/tmp|/tmp)/[^\s]+"#, with: "<redacted-path>", options: .regularExpression)
                .replacingOccurrences(of: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, with: "<redacted-email>", options: [.regularExpression, .caseInsensitive])
            if text.count > maxLength {
                text = String(text.prefix(maxLength)) + "…"
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func sanitizedArguments(_ arguments: [String]) -> [String] {
            var sanitized: [String] = []
            var redactNext = false
            for argument in arguments {
                if redactNext {
                    sanitized.append("<redacted>")
                    redactNext = false
                } else if argument == "--developer-id-identity" || argument == "--notary-profile" {
                    sanitized.append(argument)
                    redactNext = true
                } else {
                    sanitized.append(argument)
                }
            }
            return sanitized
        }
    }

    private func runCheck(
        _ arguments: [String],
        timeoutSeconds: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ScriptResult {
        let process = Process()
        process.executableURL = checkScriptURL
        process.arguments = arguments
        process.currentDirectoryURL = packageRootURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            semaphore.signal()
        }
        let timedOut = semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut
        if timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 1)
        }

        let result = ScriptResult(
            exitCode: process.terminationStatus,
            stdout: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            timedOut: timedOut,
            arguments: arguments
        )
        if timedOut {
            XCTFail("Distribution check timed out. \(result.sanitizedDiagnosticSummary)", file: file, line: line)
        }
        return result
    }

    private var packageRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var checkScriptURL: URL {
        packageRootURL
            .appendingPathComponent("scripts")
            .appendingPathComponent("distribution")
            .appendingPathComponent("check")
    }

    private func assertNoForbiddenDistributionSubstrings(
        _ text: String,
        additionalForbidden: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let forbidden = [
            "/Users/",
            "/private/tmp/",
            "/tmp/",
            "alice@example.test",
            "Alice Example",
            "ABCDE12345",
            "super-secret",
            "hunter2",
            "token=",
            "password=",
            "app-specific-password=",
            "notary-profile=",
            "TeamIdentifier=",
            "12345678-1234-1234-1234-123456789abc",
            "?token=",
            "?submission=",
            "#frag",
            "#fragment",
            "notary-logs.local",
            "shipping.local",
            ".xcarchive",
            ".dmg",
        ] + additionalForbidden
        let lowercased = text.lowercased()
        for literal in forbidden {
            XCTAssertFalse(
                lowercased.contains(literal.lowercased()),
                "Expected distribution check output to redact forbidden literal '\(literal)', got sanitized summary: \(ScriptResult.sanitizedSnippet(from: Data(text.utf8)))",
                file: file,
                line: line
            )
        }
    }
}
