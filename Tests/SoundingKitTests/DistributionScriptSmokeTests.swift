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

    func testPackageHelpDocumentsDryRunAndRealModeCredentialGating() throws {
        let result = try runPackage(["--help"])
        XCTAssertEqual(result.exitCode, 0, result.sanitizedDiagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("Usage: scripts/distribution/package"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("--dry-run"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("--real"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("--output-dir <ignored-dir>"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("--developer-id-identity <selector>"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("--notary-profile <profile>"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("--app-verify-fixture-evidence <json>"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(result.stdoutText.contains("--app-verify-live-evidence <json>"), result.sanitizedDiagnosticSummary)
        XCTAssertFalse(result.stdoutText.localizedCaseInsensitiveContains(".env"), result.sanitizedDiagnosticSummary)
        assertNoForbiddenDistributionSubstrings(result.stdoutText + result.stderrText)
    }

    func testDryRunPackageBuildsStagesAndReportsCredentialGatedStatuses() throws {
        let outputDir = try makeIgnoredOutputDirectory(name: "package-dry-run")
        let evidence = try writeAppVerifyEvidencePair(in: outputDir, fixtureStatus: "pass", liveStatus: "pass")
        let result = try runPackage([
            "--dry-run", "--json", "--output-dir", outputDir.path,
            "--app-verify-fixture-evidence", evidence.fixture.path,
            "--app-verify-live-evidence", evidence.live.path,
        ], timeoutSeconds: 900)
        XCTAssertEqual(result.exitCode, 0, result.sanitizedDiagnosticSummary)
        XCTAssertEqual(result.stderrText, "", result.sanitizedDiagnosticSummary)
        let report = try result.decodeJSON(PackageReport.self)
        XCTAssertEqual(report.schemaVersion, 1, result.sanitizedDiagnosticSummary)
        XCTAssertTrue(report.dryRun, result.sanitizedDiagnosticSummary)
        XCTAssertEqual(report.overallStatus, "ready", result.sanitizedDiagnosticSummary)
        XCTAssertTrue(report.checks.contains { $0.phase == "appVerify" && $0.status == "ready" }, result.sanitizedDiagnosticSummary)
        XCTAssertTrue(report.checks.contains { $0.phase == "archive" && $0.status == "ready" }, result.sanitizedDiagnosticSummary)
        XCTAssertTrue(report.checks.contains { $0.phase == "codesign" && $0.status == "skipped" }, result.sanitizedDiagnosticSummary)
        XCTAssertTrue(report.checks.contains { $0.phase == "notarySubmit" && $0.status == "skipped" }, result.sanitizedDiagnosticSummary)
        XCTAssertTrue(report.checks.contains { $0.phase == "staple" && $0.status == "skipped" }, result.sanitizedDiagnosticSummary)
        XCTAssertTrue(report.checks.contains { $0.phase == "gatekeeper" && $0.status == "skipped" }, result.sanitizedDiagnosticSummary)
        XCTAssertTrue(report.checks.contains { $0.phase == "dmg" && ["ready", "skipped"].contains($0.status) }, result.sanitizedDiagnosticSummary)
        assertNoForbiddenDistributionSubstrings(result.stdoutText + result.stderrText)
    }

    func testPackageRejectsInvalidRealModeCombinationsBeforeToolSubmission() throws {
        let outputDir = try makeIgnoredOutputDirectory(name: "package-invalid-real")
        let missingCredentials = try runPackage(["--real", "--json", "--output-dir", outputDir.path])
        XCTAssertEqual(missingCredentials.exitCode, 64, missingCredentials.sanitizedDiagnosticSummary)
        XCTAssertTrue(missingCredentials.stderrText.contains("--real requires both"), missingCredentials.sanitizedDiagnosticSummary)
        assertNoForbiddenDistributionSubstrings(missingCredentials.stdoutText + missingCredentials.stderrText)

        let conflictingModes = try runPackage(["--real", "--dry-run", "--json", "--output-dir", outputDir.path, "--developer-id-identity", "LocalSelector", "--notary-profile", "LocalProfile"])
        XCTAssertEqual(conflictingModes.exitCode, 64, conflictingModes.sanitizedDiagnosticSummary)
        XCTAssertTrue(conflictingModes.stderrText.contains("choose either --dry-run or --real"), conflictingModes.sanitizedDiagnosticSummary)
        assertNoForbiddenDistributionSubstrings(conflictingModes.stdoutText + conflictingModes.stderrText, additionalForbidden: ["LocalSelector", "LocalProfile"])
    }

    func testPackageRejectsSecretLikeOutputAndCredentialArgumentsWithoutEchoing() throws {
        let secretPath = "shipping.local/token=super-secret"
        let secretOutput = try runPackage(["--dry-run", "--json", "--output-dir", secretPath])
        XCTAssertEqual(secretOutput.exitCode, 64, secretOutput.sanitizedDiagnosticSummary)
        XCTAssertTrue(secretOutput.stderrText.contains("looks sensitive"), secretOutput.sanitizedDiagnosticSummary)
        XCTAssertFalse(secretOutput.stderrText.contains(secretPath), secretOutput.sanitizedDiagnosticSummary)

        let secretSelector = "Developer ID Application: Alice Example (ABCDE12345) alice@example.test token=super-secret"
        let outputDir = try makeIgnoredOutputDirectory(name: "package-secret-args")
        let secretCredential = try runPackage(["--real", "--json", "--output-dir", outputDir.path, "--developer-id-identity", secretSelector, "--notary-profile", "LocalProfile"])
        XCTAssertEqual(secretCredential.exitCode, 64, secretCredential.sanitizedDiagnosticSummary)
        XCTAssertTrue(secretCredential.stderrText.contains("looks sensitive"), secretCredential.sanitizedDiagnosticSummary)
        XCTAssertFalse(secretCredential.stderrText.contains(secretSelector), secretCredential.sanitizedDiagnosticSummary)
        assertNoForbiddenDistributionSubstrings(secretOutput.stdoutText + secretOutput.stderrText + secretCredential.stdoutText + secretCredential.stderrText, additionalForbidden: [
            "Alice Example",
            "alice@example.test",
            "ABCDE12345",
            "super-secret",
            "LocalProfile",
            "token=",
        ])
    }

    func testPackageRequiresAppVerifyEvidenceFlagsBeforeWorkspaceUse() throws {
        let outputDir = try makeIgnoredOutputDirectory(name: "package-missing-evidence-flags")
        let result = try runPackage(["--dry-run", "--json", "--output-dir", outputDir.path])
        XCTAssertEqual(result.exitCode, 64, result.sanitizedDiagnosticSummary)
        XCTAssertTrue(result.stderrText.contains("--app-verify-fixture-evidence"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(result.stderrText.contains("--app-verify-live-evidence"), result.sanitizedDiagnosticSummary)
        XCTAssertEqual(result.stdoutText, "", result.sanitizedDiagnosticSummary)
        assertNoForbiddenDistributionSubstrings(result.stdoutText + result.stderrText)
    }

    func testPackageReportsMissingAppVerifyEvidenceFilesBeforeArchiveOrDMG() throws {
        let outputDir = try makeIgnoredOutputDirectory(name: "package-missing-evidence-files")
        let missingFixture = outputDir.appendingPathComponent("missing-fixture.json")
        let missingLive = outputDir.appendingPathComponent("missing-live.json")
        let result = try runPackage([
            "--dry-run", "--json", "--output-dir", outputDir.path,
            "--app-verify-fixture-evidence", missingFixture.path,
            "--app-verify-live-evidence", missingLive.path,
            "--skip-build",
        ])
        try assertPackageAppVerifyGateFailure(
            result,
            expectedMessageFragments: ["Fixture App verification evidence is missing.", "Live App verification evidence is missing."],
            additionalForbidden: [missingFixture.path, missingLive.path]
        )
    }

    func testPackageReportsMalformedAppVerifyEvidenceBeforeArchiveOrDMG() throws {
        let outputDir = try makeIgnoredOutputDirectory(name: "package-malformed-evidence")
        let evidence = try writeAppVerifyEvidencePair(in: outputDir, fixtureStatus: "pass", liveStatus: "pass")
        try "{\"schemaVersion\": 1,".write(to: evidence.fixture, atomically: true, encoding: .utf8)
        let result = try runPackage([
            "--dry-run", "--json", "--output-dir", outputDir.path,
            "--app-verify-fixture-evidence", evidence.fixture.path,
            "--app-verify-live-evidence", evidence.live.path,
            "--skip-build",
        ])
        try assertPackageAppVerifyGateFailure(
            result,
            expectedMessageFragments: ["Fixture App verification evidence is malformed or incomplete."],
            additionalForbidden: [evidence.fixture.path, evidence.live.path, "schemaVersion"]
        )
    }

    func testPackageReportsFixtureMissingS03CheckBeforeArchiveOrDMG() throws {
        let outputDir = try makeIgnoredOutputDirectory(name: "package-fixture-missing-s03")
        let evidence = try writeAppVerifyEvidencePair(in: outputDir, fixtureStatus: "pass", liveStatus: "pass", omitFixtureCheck: "song_metadata_projection")
        let result = try runPackage([
            "--dry-run", "--json", "--output-dir", outputDir.path,
            "--app-verify-fixture-evidence", evidence.fixture.path,
            "--app-verify-live-evidence", evidence.live.path,
            "--skip-build",
        ])
        try assertPackageAppVerifyGateFailure(
            result,
            expectedMessageFragments: ["Fixture App verification evidence is missing required check names."],
            additionalForbidden: [evidence.fixture.path, evidence.live.path, "song_metadata_projection"]
        )
    }

    func testPackageReportsFixtureFailedSummaryBeforeArchiveOrDMG() throws {
        let outputDir = try makeIgnoredOutputDirectory(name: "package-fixture-fail")
        let evidence = try writeAppVerifyEvidencePair(in: outputDir, fixtureStatus: "fail", liveStatus: "pass")
        let result = try runPackage([
            "--dry-run", "--json", "--output-dir", outputDir.path,
            "--app-verify-fixture-evidence", evidence.fixture.path,
            "--app-verify-live-evidence", evidence.live.path,
            "--skip-build",
        ])
        try assertPackageAppVerifyGateFailure(
            result,
            expectedMessageFragments: ["Fixture App verification evidence did not report an acceptable summary status."],
            additionalForbidden: [evidence.fixture.path, evidence.live.path]
        )
    }

    func testPackageReportsLiveFailedRequiredCountBeforeArchiveOrDMG() throws {
        let outputDir = try makeIgnoredOutputDirectory(name: "package-live-failed-required")
        let evidence = try writeAppVerifyEvidencePair(in: outputDir, fixtureStatus: "pass", liveStatus: "warn", liveFailedRequiredCount: 1)
        let result = try runPackage([
            "--dry-run", "--json", "--output-dir", outputDir.path,
            "--app-verify-fixture-evidence", evidence.fixture.path,
            "--app-verify-live-evidence", evidence.live.path,
            "--skip-build",
        ])
        try assertPackageAppVerifyGateFailure(
            result,
            expectedMessageFragments: ["Live App verification evidence reported failed required checks."],
            additionalForbidden: [evidence.fixture.path, evidence.live.path]
        )
    }

    func testPackageAcceptsLiveWarnEvidenceWithNoFailedRequiredChecks() throws {
        let outputDir = try makeIgnoredOutputDirectory(name: "package-live-warn-success")
        let evidence = try writeAppVerifyEvidencePair(in: outputDir, fixtureStatus: "pass", liveStatus: "warn")
        try FileManager.default.createDirectory(at: outputDir.appendingPathComponent("package-20990101-000000/Sounding.app", isDirectory: true), withIntermediateDirectories: true)
        let result = try runPackage([
            "--dry-run", "--json", "--output-dir", outputDir.path,
            "--app-verify-fixture-evidence", evidence.fixture.path,
            "--app-verify-live-evidence", evidence.live.path,
            "--skip-build",
        ])
        // The timestamped workspace is not predictable, so skip-build may still fail at archive; the gate itself must pass first.
        let report = try result.decodeJSON(PackageReport.self)
        XCTAssertTrue(report.checks.contains { $0.phase == "appVerify" && $0.status == "ready" }, result.sanitizedDiagnosticSummary)
        XCTAssertFalse(report.checks.contains { $0.phase == "dmg" && $0.status == "ready" }, result.sanitizedDiagnosticSummary)
        assertNoForbiddenDistributionSubstrings(result.stdoutText + result.stderrText, additionalForbidden: [evidence.fixture.path, evidence.live.path])
    }

    func testPackageRejectsSecretLikeAppVerifyEvidenceArgumentsWithoutEchoing() throws {
        let outputDir = try makeIgnoredOutputDirectory(name: "package-secret-evidence-args")
        let secretEvidencePath = "fixture.json?token=super-secret#frag"
        let result = try runPackage([
            "--dry-run", "--json", "--output-dir", outputDir.path,
            "--app-verify-fixture-evidence", secretEvidencePath,
            "--app-verify-live-evidence", outputDir.appendingPathComponent("live.json").path,
        ])
        XCTAssertEqual(result.exitCode, 64, result.sanitizedDiagnosticSummary)
        XCTAssertTrue(result.stderrText.contains("looks sensitive"), result.sanitizedDiagnosticSummary)
        XCTAssertFalse(result.stderrText.contains(secretEvidencePath), result.sanitizedDiagnosticSummary)
        assertNoForbiddenDistributionSubstrings(result.stdoutText + result.stderrText, additionalForbidden: ["fixture.json", "super-secret", "token="])
    }

    func testShippingRunbookExampleAndReadmeLinksAreSafeForTrackedDocs() throws {
        let runbookURL = packageRootURL.appendingPathComponent("Docs/shipping.md")
        let exampleURL = packageRootURL.appendingPathComponent("Docs/shipping-diagnostics.example.json")
        let readmeURL = packageRootURL.appendingPathComponent("README.md")

        let runbookText = try readUTF8(runbookURL)
        let readmeText = try readUTF8(readmeURL)
        let exampleData = try Data(contentsOf: exampleURL)
        let exampleText = String(data: exampleData, encoding: .utf8) ?? ""
        let example = try JSONDecoder().decode(ShippingDiagnosticsExample.self, from: exampleData)

        XCTAssertEqual(example.schemaVersion, 1)
        XCTAssertEqual(Set(example.examples.map(\.name)), Set(["readinessWithoutCredentials", "packageDryRun", "realModeRejectedNotarization"]))
        XCTAssertTrue(example.examples.contains { $0.output.checks.contains { $0.phase == "signingIdentity" && $0.status == "missingCredential" } })
        XCTAssertTrue(example.examples.contains { $0.output.checks.contains { $0.phase == "notarySubmit" && $0.status == "notarizationRejected" } })
        XCTAssertTrue(example.examples.contains { $0.output.checks.contains { $0.phase == "staple" && $0.status == "failed" } })
        XCTAssertTrue(example.examples.contains { $0.output.checks.contains { $0.phase == "gatekeeper" && $0.status == "failed" } })
        XCTAssertTrue(example.examples.contains { $0.output.checks.contains { $0.phase == "dmg" && $0.status == "failed" } })
        XCTAssertTrue(example.examples.contains { $0.output.checks.contains { $0.phase == "redaction" && $0.status == "redactionFailure" } })

        XCTAssertTrue(readmeText.contains("[`Docs/shipping.md`](Docs/shipping.md)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runbookURL.path), "README shipping link must match tracked Docs path capitalization.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exampleURL.path), "README/example references must resolve to tracked Docs path capitalization.")
        XCTAssertTrue(runbookText.contains("sounding soak proof"))
        XCTAssertTrue(runbookText.contains("sounding database health"))
        XCTAssertTrue(runbookText.contains("sounding database checkpoint"))
        XCTAssertTrue(runbookText.contains("missingCredential"))
        XCTAssertTrue(runbookText.contains("notarizationRejected"))
        XCTAssertTrue(runbookText.contains("redactionFailure"))

        let readmeShippingSection = readmeText
            .components(separatedBy: "## Distribution and shipping")
            .dropFirst()
            .joined(separator: "## Distribution and shipping")
            .components(separatedBy: "## Database health and recovery")
            .first ?? ""

        assertTrackedDistributionDocsAreSanitized(runbookText + "\n" + readmeShippingSection + "\n" + exampleText)
    }

    private struct CheckReport: Decodable {
        var checks: [Check]
        var overallStatus: String
        var schemaVersion: Int
    }

    private struct PackageReport: Decodable {
        var checks: [Check]
        var dryRun: Bool
        var overallStatus: String
        var schemaVersion: Int
    }

    private struct ShippingDiagnosticsExample: Decodable {
        var description: String
        var examples: [ShippingDiagnosticsCase]
        var schemaVersion: Int
    }

    private struct ShippingDiagnosticsCase: Decodable {
        var command: String
        var name: String
        var output: ShippingDiagnosticsOutput
    }

    private struct ShippingDiagnosticsOutput: Decodable {
        var checks: [Check]
        var dryRun: Bool?
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
                XCTFail("Failed to decode distribution JSON: \(error). \(sanitizedDiagnosticSummary)", file: file, line: line)
                throw CLIError.invalidJSON
            }
        }

        static func sanitizedSnippet(from data: Data, maxLength: Int = 500) -> String {
            var text = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            text = text
                .replacingOccurrences(of: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s]+"#, with: "<redacted-url>", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)(Developer ID Application:|Developer ID Installer:).*"#, with: "<redacted-developer-id>", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)(token|secret|password|profile)=([^\s&]+)"#, with: "$1=<redacted>", options: .regularExpression)
                .replacingOccurrences(of: #"(?<![A-Za-z0-9])(?:/Users|/private/tmp|/tmp|/var/folders)/[^\s]+"#, with: "<redacted-path>", options: .regularExpression)
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
                } else if argument == "--developer-id-identity" || argument == "--notary-profile" || argument == "--output-dir" || argument == "--app-verify-fixture-evidence" || argument == "--app-verify-live-evidence" {
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
        try runScript(checkScriptURL, arguments: arguments, timeoutSeconds: timeoutSeconds, file: file, line: line)
    }

    private func runPackage(
        _ arguments: [String],
        timeoutSeconds: TimeInterval = 60,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ScriptResult {
        try runScript(packageScriptURL, arguments: arguments, timeoutSeconds: timeoutSeconds, file: file, line: line)
    }

    private func runScript(
        _ scriptURL: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        file: StaticString,
        line: UInt
    ) throws -> ScriptResult {
        let process = Process()
        process.executableURL = scriptURL
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
            XCTFail("Distribution script timed out. \(result.sanitizedDiagnosticSummary)", file: file, line: line)
        }
        return result
    }

    private let fixtureRequiredChecks = [
        "fixture_source_created",
        "database_opened",
        "stream_registered",
        "runtime_started",
        "decode_completed",
        "avfoundation_playback_scheduled",
        "runtime_stopped",
        "diagnostics_written",
        "playback_muted",
        "playback_unmuted",
        "playback_volume_changed",
        "runtime_stop_observed",
        "runtime_restart_observed",
        "transcript_persistence",
        "transcript_timeline_projection",
        "transcript_search_projection",
        "song_metadata_projection",
        "ad_metadata_projection",
    ]

    private let liveRequiredChecks = [
        "live_config_validated",
        "live_stream_registered",
        "live_runtime_started",
        "live_decode_opened",
        "live_playback_scheduled",
        "live_runtime_stopped",
        "live_diagnostics_written",
        "live_transcript_observed",
        "live_metadata_observed",
    ]

    private func writeAppVerifyEvidencePair(
        in outputDir: URL,
        fixtureStatus: String,
        liveStatus: String,
        liveFailedRequiredCount: Int = 0,
        omitFixtureCheck: String? = nil
    ) throws -> (fixture: URL, live: URL) {
        let fixture = outputDir.appendingPathComponent("fixture-evidence.json")
        let live = outputDir.appendingPathComponent("live-evidence.json")
        try writeEvidence(
            at: fixture,
            status: fixtureStatus,
            failedRequiredCheckCount: fixtureStatus == "fail" ? 1 : 0,
            checks: fixtureRequiredChecks.filter { $0 != omitFixtureCheck }
        )
        try writeEvidence(
            at: live,
            status: liveStatus,
            failedRequiredCheckCount: liveFailedRequiredCount,
            checks: liveRequiredChecks
        )
        return (fixture, live)
    }

    private func writeEvidence(at url: URL, status: String, failedRequiredCheckCount: Int, checks: [String]) throws {
        let payload: [String: Any] = [
            "checks": checks.map { name in
                ["name": name, "status": "pass", "required": true, "phase": "output"]
            },
            "generatedAt": "2026-05-02T00:00:00Z",
            "runID": "synthetic",
            "schemaVersion": 1,
            "summary": [
                "failedRequiredCheckCount": failedRequiredCheckCount,
                "message": "synthetic",
                "requiredCheckCount": checks.count,
                "status": status,
                "warningCheckCount": 0,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: url, options: [.atomic])
    }

    private func assertPackageAppVerifyGateFailure(
        _ result: ScriptResult,
        expectedMessageFragments: [String],
        additionalForbidden: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(result.exitCode, 1, result.sanitizedDiagnosticSummary, file: file, line: line)
        XCTAssertEqual(result.stderrText, "", result.sanitizedDiagnosticSummary, file: file, line: line)
        let report = try result.decodeJSON(PackageReport.self, file: file, line: line)
        XCTAssertEqual(report.overallStatus, "failed", result.sanitizedDiagnosticSummary, file: file, line: line)
        XCTAssertTrue(report.checks.contains { $0.phase == "appVerify" && $0.status == "failed" }, result.sanitizedDiagnosticSummary, file: file, line: line)
        for fragment in expectedMessageFragments {
            XCTAssertTrue(report.checks.contains { $0.phase == "appVerify" && $0.message.contains(fragment) }, "Missing appVerify fragment: \(fragment). \(result.sanitizedDiagnosticSummary)", file: file, line: line)
        }
        XCTAssertFalse(report.checks.contains { $0.phase == "archive" && $0.status == "ready" }, result.sanitizedDiagnosticSummary, file: file, line: line)
        XCTAssertFalse(report.checks.contains { $0.phase == "dmg" && $0.status == "ready" }, result.sanitizedDiagnosticSummary, file: file, line: line)
        XCTAssertFalse(result.stdoutText.contains("Traceback"), result.sanitizedDiagnosticSummary, file: file, line: line)
        XCTAssertFalse(result.stdoutText.contains("JSONDecodeError"), result.sanitizedDiagnosticSummary, file: file, line: line)
        assertNoForbiddenDistributionSubstrings(result.stdoutText + result.stderrText, additionalForbidden: additionalForbidden, file: file, line: line)
    }

    private func makeIgnoredOutputDirectory(name: String) throws -> URL {
        let root = packageRootURL
            .appendingPathComponent("shipping.local", isDirectory: true)
            .appendingPathComponent("tests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
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

    private var packageScriptURL: URL {
        packageRootURL
            .appendingPathComponent("scripts")
            .appendingPathComponent("distribution")
            .appendingPathComponent("package")
    }

    private func readUTF8(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            XCTFail("Expected UTF-8 text at \(url.lastPathComponent)", file: file, line: line)
            throw CLIError.invalidJSON
        }
        return text
    }

    private func assertTrackedDistributionDocsAreSanitized(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let forbiddenLiterals = [
            "Alice Example",
            "alice@example.test",
            "ABCDE12345",
            "super-secret",
            "hunter2",
            "Developer ID Application:",
            "Developer ID Installer:",
            "/Users/",
            "/private/tmp/",
            "/tmp/",
            "/var/folders/",
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
        ]
        let lowercased = text.lowercased()
        for literal in forbiddenLiterals {
            XCTAssertFalse(
                lowercased.contains(literal.lowercased()),
                "Tracked distribution docs/examples contain forbidden literal '\(literal)'.",
                file: file,
                line: line
            )
        }

        let forbiddenPatterns: [(String, NSRegularExpression.Options)] = [
            (#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, [.caseInsensitive]),
            (#"\b[A-Z0-9]{10}\b"#, []),
            (#"Developer ID (Application|Installer):"#, [.caseInsensitive]),
        ]
        for (pattern, options) in forbiddenPatterns {
            let regex = try! NSRegularExpression(pattern: pattern, options: options)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            XCTAssertNil(
                regex.firstMatch(in: text, options: [], range: range),
                "Tracked distribution docs/examples contain forbidden pattern '\(pattern)'.",
                file: file,
                line: line
            )
        }
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
            "/var/folders/",
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
                "Expected distribution output to redact forbidden literal '\(literal)', got sanitized summary: \(ScriptResult.sanitizedSnippet(from: Data(text.utf8)))",
                file: file,
                line: line
            )
        }
    }
}
