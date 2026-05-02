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
        printf '%s\n' "$DISTRIBUTION_PHASE_APP_VERIFY"
        printf '%s\n' "$DISTRIBUTION_PHASE_OUTPUT"
        printf '%s\n' "$DISTRIBUTION_PHASE_REDACTION"
        printf '%s\n' "$DISTRIBUTION_STATUS_READY"
        printf '%s\n' "$DISTRIBUTION_STATUS_SKIPPED"
        printf '%s\n' "$DISTRIBUTION_STATUS_MISSING_CREDENTIAL"
        printf '%s\n' "$DISTRIBUTION_STATUS_FAILED"
        printf '%s\n' "$DISTRIBUTION_STATUS_NOTARIZATION_REJECTED"
        printf '%s\n' "$DISTRIBUTION_STATUS_REDACTION_FAILURE"
        printf '%s\n' "$DISTRIBUTION_GUIDANCE_APP_VERIFY"
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
            "appVerify",
            "output",
            "redaction",
            "ready",
            "skipped",
            "missingCredential",
            "failed",
            "notarizationRejected",
            "redactionFailure",
            "Run fixture and live app verification, then retry packaging with their evidence JSON files.",
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
        distribution_emit_json_summary "$DISTRIBUTION_PHASE_APP_VERIFY" "$DISTRIBUTION_STATUS_FAILED" "App verification evidence is missing." "$DISTRIBUTION_GUIDANCE_APP_VERIFY"
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
            "appVerify",
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

    func testAppVerifyGateValidatesBoundedEvidenceWithControlledOutput() throws {
        let script = #"""
        set -euo pipefail
        source "$APP_VERIFY_GATE_LIB"
        workspace=$(mktemp -d)
        trap 'rm -rf "$workspace"' EXIT
        fixture="$workspace/fixture.json"
        live="$workspace/live.json"
        cat > "$fixture" <<'JSON'
        {
          "schemaVersion": 1,
          "summary": {"status": "pass", "failedRequiredCheckCount": 0},
          "checks": [
            {"name":"fixture_source_created"},
            {"name":"database_opened"},
            {"name":"stream_registered"},
            {"name":"runtime_started"},
            {"name":"decode_completed"},
            {"name":"avfoundation_playback_scheduled"},
            {"name":"runtime_stopped"},
            {"name":"diagnostics_written"},
            {"name":"playback_muted"},
            {"name":"playback_unmuted"},
            {"name":"playback_volume_changed"},
            {"name":"runtime_stop_observed"},
            {"name":"runtime_restart_observed"},
            {"name":"transcript_persistence"},
            {"name":"transcript_timeline_projection"},
            {"name":"transcript_search_projection"},
            {"name":"song_metadata_projection"},
            {"name":"ad_metadata_projection"}
          ],
          "metadata": {"ignoredPath": "/Users/alice/private.json?token=secret#frag"}
        }
        JSON
        cat > "$live" <<'JSON'
        {
          "schemaVersion": 1,
          "summary": {"status": "warn", "failedRequiredCheckCount": 0},
          "checks": [
            {"name":"live_config_validated"},
            {"name":"live_stream_registered"},
            {"name":"live_runtime_started"},
            {"name":"live_decode_opened"},
            {"name":"live_playback_scheduled"},
            {"name":"live_runtime_stopped"},
            {"name":"live_diagnostics_written"},
            {"name":"live_transcript_observed"},
            {"name":"live_metadata_observed"}
          ],
          "artifacts": [{"path": "/private/tmp/live.json?token=secret#frag"}]
        }
        JSON
        app_verify_gate_validate_evidence fixture "$fixture"
        app_verify_gate_validate_evidence live "$live"
        """#

        let result = try runBash(script)
        XCTAssertEqual(result.exitCode, 0, result.sanitizedDiagnosticSummary)
        XCTAssertEqual(result.stderrText, "", result.sanitizedDiagnosticSummary)
        let lines = result.stdoutText.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, result.sanitizedDiagnosticSummary)
        for line in lines {
            XCTAssertTrue(line.hasPrefix("ready\tapp_verify_evidence_ready\t"), result.sanitizedDiagnosticSummary)
            XCTAssertTrue(line.contains("App verification evidence is ready for packaging."), result.sanitizedDiagnosticSummary)
        }
        assertNoForbiddenDistributionSubstrings(result.stdoutText + result.stderrText)
    }

    func testAppVerifyGateFailsClosedForMalformedFailedAndIncompleteEvidence() throws {
        let script = #"""
        set -euo pipefail
        source "$APP_VERIFY_GATE_LIB"
        workspace=$(mktemp -d)
        trap 'rm -rf "$workspace"' EXIT
        malformed="$workspace/malformed.json"
        wrong_schema="$workspace/wrong-schema.json"
        fixture_warn="$workspace/fixture-warn.json"
        live_failed_required="$workspace/live-failed-required.json"
        duplicate_missing="$workspace/duplicate-missing.json"
        printf '{"schemaVersion": 1, ' > "$malformed"
        cat > "$wrong_schema" <<'JSON'
        {"schemaVersion":2,"summary":{"status":"pass","failedRequiredCheckCount":0},"checks":[]}
        JSON
        cat > "$fixture_warn" <<'JSON'
        {
          "schemaVersion": 1,
          "summary": {"status": "warn", "failedRequiredCheckCount": 0},
          "checks": [
            {"name":"fixture_source_created"}, {"name":"database_opened"}, {"name":"stream_registered"},
            {"name":"runtime_started"}, {"name":"decode_completed"}, {"name":"avfoundation_playback_scheduled"},
            {"name":"runtime_stopped"}, {"name":"diagnostics_written"}, {"name":"playback_muted"},
            {"name":"playback_unmuted"}, {"name":"playback_volume_changed"}, {"name":"runtime_stop_observed"},
            {"name":"runtime_restart_observed"}, {"name":"transcript_persistence"},
            {"name":"transcript_timeline_projection"}, {"name":"transcript_search_projection"},
            {"name":"song_metadata_projection"}, {"name":"ad_metadata_projection"}
          ]
        }
        JSON
        cat > "$live_failed_required" <<'JSON'
        {
          "schemaVersion": 1,
          "summary": {"status": "warn", "failedRequiredCheckCount": 1},
          "checks": [
            {"name":"live_config_validated"}, {"name":"live_stream_registered"}, {"name":"live_runtime_started"},
            {"name":"live_decode_opened"}, {"name":"live_playback_scheduled"}, {"name":"live_runtime_stopped"},
            {"name":"live_diagnostics_written"}, {"name":"live_transcript_observed"}, {"name":"live_metadata_observed"}
          ]
        }
        JSON
        cat > "$duplicate_missing" <<'JSON'
        {
          "schemaVersion": 1,
          "summary": {"status": "pass", "failedRequiredCheckCount": 0},
          "checks": [
            {"name":"fixture_source_created"}, {"name":"fixture_source_created"}, {"name":"database_opened"}
          ],
          "metadata": {"source": "https://example.test/path?token=secret#frag", "path": "/Users/alice/evidence.json"}
        }
        JSON

        set +e
        app_verify_gate_validate_evidence fixture "$workspace/missing.json"
        app_verify_gate_validate_evidence fixture "$malformed"
        app_verify_gate_validate_evidence fixture "$wrong_schema"
        app_verify_gate_validate_evidence fixture "$fixture_warn"
        app_verify_gate_validate_evidence live "$live_failed_required"
        app_verify_gate_validate_evidence fixture "$duplicate_missing"
        exit 0
        """#

        let result = try runBash(script)
        XCTAssertEqual(result.exitCode, 0, result.sanitizedDiagnosticSummary)
        XCTAssertEqual(result.stderrText, "", result.sanitizedDiagnosticSummary)
        let combined = result.stdoutText + result.stderrText
        for code in [
            "app_verify_evidence_missing",
            "app_verify_evidence_malformed",
            "app_verify_evidence_wrong_schema",
            "app_verify_evidence_failed_summary",
            "app_verify_evidence_failed_required_checks",
            "app_verify_evidence_missing_required_checks",
        ] {
            XCTAssertTrue(combined.contains("failed\t\(code)\t"), "Missing controlled code \(code). \(result.sanitizedDiagnosticSummary)")
        }
        XCTAssertFalse(combined.contains("Traceback"), result.sanitizedDiagnosticSummary)
        XCTAssertFalse(combined.contains("JSONDecodeError"), result.sanitizedDiagnosticSummary)
        XCTAssertFalse(combined.contains("schemaVersion"), result.sanitizedDiagnosticSummary)
        XCTAssertFalse(combined.contains("fixture_source_created"), result.sanitizedDiagnosticSummary)
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
            "APP_VERIFY_GATE_LIB": appVerifyGateLibraryURL.path,
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

    private var appVerifyGateLibraryURL: URL {
        packageRootURL
            .appendingPathComponent("scripts")
            .appendingPathComponent("distribution")
            .appendingPathComponent("lib")
            .appendingPathComponent("app_verify_gate.sh")
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
