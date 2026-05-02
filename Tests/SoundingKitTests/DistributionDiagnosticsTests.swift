import Foundation
import XCTest

final class DistributionDiagnosticsTests: XCTestCase {
    func testLibraryIsSourceableAndDeclaresPhaseStatusVocabularyWithoutSideEffects() throws {
        let script = #"""
        set -euo pipefail
        source "$DIAGNOSTICS_LIB"
        printf '%s\n' "$DISTRIBUTION_PHASE_ENVIRONMENT"
        printf '%s\n' "$DISTRIBUTION_PHASE_SIGNING_IDENTITY"
        printf '%s\n' "$DISTRIBUTION_PHASE_ARCHIVE"
        printf '%s\n' "$DISTRIBUTION_PHASE_EXPORT"
        printf '%s\n' "$DISTRIBUTION_PHASE_CODESIGN"
        printf '%s\n' "$DISTRIBUTION_PHASE_NOTARY_SUBMIT"
        printf '%s\n' "$DISTRIBUTION_PHASE_NOTARY_WAIT"
        printf '%s\n' "$DISTRIBUTION_PHASE_NOTARY_LOG"
        printf '%s\n' "$DISTRIBUTION_PHASE_STAPLE"
        printf '%s\n' "$DISTRIBUTION_PHASE_GATEKEEPER"
        printf '%s\n' "$DISTRIBUTION_PHASE_DMG"
        printf '%s\n' "$DISTRIBUTION_PHASE_OUTPUT"
        printf '%s\n' "$DISTRIBUTION_PHASE_REDACTION"
        printf '%s\n' "$DISTRIBUTION_STATUS_READY"
        printf '%s\n' "$DISTRIBUTION_STATUS_SKIPPED"
        printf '%s\n' "$DISTRIBUTION_STATUS_MISSING_CREDENTIAL"
        printf '%s\n' "$DISTRIBUTION_STATUS_FAILED"
        printf '%s\n' "$DISTRIBUTION_STATUS_NOTARIZATION_REJECTED"
        printf '%s\n' "$DISTRIBUTION_STATUS_REDACTION_FAILURE"
        """#

        let result = try runBash(script)
        XCTAssertEqual(result.exitCode, 0, result.sanitizedDiagnosticSummary)
        XCTAssertEqual(result.stderrText, "", result.sanitizedDiagnosticSummary)
        XCTAssertEqual(result.stdoutText.split(separator: "\n").map(String.init), [
            "environment",
            "signingIdentity",
            "archive",
            "export",
            "codesign",
            "notarySubmit",
            "notaryWait",
            "notaryLog",
            "staple",
            "gatekeeper",
            "dmg",
            "output",
            "redaction",
            "ready",
            "skipped",
            "missingCredential",
            "failed",
            "notarizationRejected",
            "redactionFailure",
        ], result.sanitizedDiagnosticSummary)
    }

    func testRedactsAppleDistributionSecretsInTextJSONAndHumanSummaries() throws {
        let script = #"""
        set -euo pipefail
        source "$DIAGNOSTICS_LIB"
        fixture=$(cat <<'FIXTURE'
        Developer ID Application: Example Name (ABCDE12345) failed for /Users/alice/Library/Developer/Xcode/Archives/2026-05-01/Sounding.xcarchive
        Apple ID alice@example.test used profile notary-profile=PrivateProfile token=super-secret app-specific-password=abcd-efgh password=hunter2
        notarytool submit returned id: 12345678-1234-1234-1234-123456789abc logFile=/Users/alice/notary-logs.local/request.json?token=abc#frag
        created /private/tmp/Sounding.dmg and URL https://example.test/upload?submission=secret#fragment TeamIdentifier=ABCDE12345
        FIXTURE
        )
        distribution_redact_text "$fixture"
        printf '\n---json---\n'
        distribution_emit_json_summary "$DISTRIBUTION_PHASE_NOTARY_WAIT" "$DISTRIBUTION_STATUS_NOTARIZATION_REJECTED" "$fixture" "Inspect /Users/alice/notary-logs.local/request.json?token=abc#frag"
        printf '%s\n' '---human---'
        distribution_emit_human_summary "$DISTRIBUTION_PHASE_STAPLE" "$DISTRIBUTION_STATUS_FAILED" "$fixture" "$DISTRIBUTION_GUIDANCE_STAPLE"
        """#

        let result = try runBash(script)
        XCTAssertEqual(result.exitCode, 0, result.sanitizedDiagnosticSummary)
        let combined = result.stdoutText + result.stderrText
        XCTAssertTrue(combined.contains("[redacted-developer-id]"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(combined.contains("[redacted-email]"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(combined.contains("[redacted-path]") || combined.contains("[redacted-artifact]"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(combined.contains("[redacted-secret]"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(combined.contains("[redacted-url]"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(combined.contains("\"phase\":\"notaryWait\""), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(combined.contains("\"status\":\"notarizationRejected\""), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(combined.contains("Distribution staple: status=failed"), result.sanitizedDiagnosticSummary)
        assertNoForbiddenDistributionSubstrings(combined)
    }

    func testClassifiesPlannedDistributionFailuresAndUsesSafeFallbacks() throws {
        let script = #"""
        set -euo pipefail
        source "$DIAGNOSTICS_LIB"
        inputs=(
          'xcode-select: error: invalid developer path /Users/alice/Xcode.app'
          'No signing certificate Developer ID Application: Example Name (ABCDE12345) was found'
          'xcodebuild: error: archive failed at /tmp/Sounding.xcarchive'
          'exportArchive failed for /tmp/export'
          'codesign verification failed for /Users/alice/Sounding.app'
          'notarytool submit failed: keychain profile PrivateProfile not found for alice@example.test'
          'notarytool wait reported rejected invalid binary id=12345678-1234-1234-1234-123456789abc'
          'notary log fetch failed logfile=/Users/alice/notary-logs.local/log.json'
          'stapler staple failed for /Users/alice/Sounding.app'
          'spctl Gatekeeper assessment rejected /private/tmp/Sounding.dmg'
          'hdiutil dmg verification failed for /tmp/Sounding.dmg'
          'output write failed permission denied /Users/alice/shipping.local/out.json'
        )
        for input in "${inputs[@]}"; do
          classification=$(distribution_classify_output "$input")
          phase=${classification%%$'\t'*}
          status=${classification#*$'\t'}
          distribution_emit_json_summary "$phase" "$status" "$input" "fixed guidance"
        done
        distribution_emit_json_summary "unexpectedPhase" "unexpectedStatus" "" "profile=PrivateProfile password=hunter2"
        """#

        let result = try runBash(script)
        XCTAssertEqual(result.exitCode, 0, result.sanitizedDiagnosticSummary)
        let combined = result.stdoutText + result.stderrText
        for phase in [
            "environment",
            "signingIdentity",
            "archive",
            "export",
            "codesign",
            "notarySubmit",
            "notaryWait",
            "notaryLog",
            "staple",
            "gatekeeper",
            "dmg",
            "output",
            "unknown",
        ] {
            XCTAssertTrue(combined.contains("\"phase\":\"\(phase)\""), "Missing phase \(phase). \(result.sanitizedDiagnosticSummary)")
        }
        for status in ["missingCredential", "failed", "notarizationRejected", "redactionFailure"] {
            XCTAssertTrue(combined.contains("\"status\":\"\(status)\""), "Missing status \(status). \(result.sanitizedDiagnosticSummary)")
        }
        assertNoForbiddenDistributionSubstrings(combined)
    }

    func testMalformedAndRepeatedRedactionInputsStaySafeAndJSONEscaped() throws {
        let script = #"""
        set -euo pipefail
        source "$DIAGNOSTICS_LIB"
        first=$(distribution_redact_text 'quote="value" newline
        /Users/alice/path?token=secret#frag alice@example.test Developer ID Installer: Installer Name (ABCDE12345)')
        second=$(distribution_redact_text "$first")
        printf '%s\n' "$second"
        distribution_emit_json_summary "$DISTRIBUTION_PHASE_REDACTION" "$DISTRIBUTION_STATUS_REDACTION_FAILURE" "quote \" newline
        $second" "token=secret password=hunter2"
        """#

        let result = try runBash(script)
        XCTAssertEqual(result.exitCode, 0, result.sanitizedDiagnosticSummary)
        let combined = result.stdoutText + result.stderrText
        XCTAssertTrue(combined.contains("redactionFailure"), result.sanitizedDiagnosticSummary)
        XCTAssertTrue(combined.contains(#"quote \" newline"#) || combined.contains("quote \\\" newline"), result.sanitizedDiagnosticSummary)
        XCTAssertNoThrow(try decodeLineDelimitedJSON(from: result.stdoutText), result.sanitizedDiagnosticSummary)
        assertNoForbiddenDistributionSubstrings(combined)
    }

    private struct BashResult {
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool

        var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
        var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }

        var sanitizedDiagnosticSummary: String {
            "exit=\(exitCode), timedOut=\(timedOut), stdout=\(Self.sanitizedSnippet(from: stdout)), stderr=\(Self.sanitizedSnippet(from: stderr))"
        }

        static func sanitizedSnippet(from data: Data, maxLength: Int = 400) -> String {
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
    }

    private func runBash(
        _ script: String,
        timeoutSeconds: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> BashResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = packageRootURL
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DIAGNOSTICS_LIB": diagnosticsLibraryURL.path,
        ]) { _, new in new }

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

        let result = BashResult(
            exitCode: process.terminationStatus,
            stdout: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            timedOut: timedOut
        )
        if timedOut {
            XCTFail("Distribution diagnostics bash snippet timed out. \(result.sanitizedDiagnosticSummary)", file: file, line: line)
        }
        return result
    }

    private var packageRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var diagnosticsLibraryURL: URL {
        packageRootURL
            .appendingPathComponent("scripts")
            .appendingPathComponent("distribution")
            .appendingPathComponent("lib")
            .appendingPathComponent("diagnostics.sh")
    }

    private func decodeLineDelimitedJSON(from text: String) throws {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix("{") {
            _ = try JSONSerialization.jsonObject(with: Data(line.utf8))
        }
    }

    private func assertNoForbiddenDistributionSubstrings(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let forbidden = [
            "/Users/",
            "/private/tmp/",
            "/tmp/",
            "alice@example.test",
            "Example Name",
            "Installer Name",
            "ABCDE12345",
            "PrivateProfile",
            "super-secret",
            "hunter2",
            "abcd-efgh",
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
        ]
        let lowercased = text.lowercased()
        for literal in forbidden {
            XCTAssertFalse(
                lowercased.contains(literal.lowercased()),
                "Expected distribution diagnostics to redact forbidden literal '\(literal)', got sanitized summary: \(BashResult.sanitizedSnippet(from: Data(text.utf8)))",
                file: file,
                line: line
            )
        }
    }
}
