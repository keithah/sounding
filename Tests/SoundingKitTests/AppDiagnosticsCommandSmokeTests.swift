import Foundation
import XCTest

@testable import SoundingKit
@testable import sounding

final class AppDiagnosticsCommandSmokeTests: XCTestCase {
    func testSummaryRedactsLogDirectoryAndDecodedRuntimeFields() throws {
        let fixture = try makeRuntimeLogFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try CLIRunner().runSounding(arguments: [
            "app-diagnostics",
            "--log-directory", fixture.directory.path,
            "--tail", "1",
        ])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        let output = result.stdoutText
        XCTAssertTrue(output.contains("app-diagnostics logDirectory=[redacted-path]"), output)
        XCTAssertTrue(output.contains("app-diagnostics events=2 failures=1"), output)
        XCTAssertTrue(output.contains("app-diagnostics event-counts"), output)
        XCTAssertTrue(output.contains("runtime.started=1"), output)
        XCTAssertTrue(output.contains("runtime.decode.completed=1"), output)
        XCTAssertTrue(output.contains("app-diagnostics phase-counts"), output)
        XCTAssertTrue(output.contains("decode=1"), output)
        XCTAssertTrue(output.contains("runtime_start=1"), output)
        XCTAssertTrue(output.contains("app-diagnostics recent-events"), output)
        XCTAssertTrue(
            output.contains("event=runtime.decode.completed stream=42 phase=decode"), output)
        XCTAssertTrue(
            output.contains("fields=[redacted-secret-key]:[redacted-secret],detail:kept-diagnostic-context"),
            output)
        XCTAssertTrue(output.contains("app-diagnostics recent-failures"), output)
        XCTAssertTrue(output.contains("event=runtime.failure stream=99 phase=playback"), output)
        XCTAssertEqual(lines(in: output, containing: " event=runtime."), 2, output)
        assertSanitized(output, forbiddenLiterals: fixture.forbidden)
    }

    func testRawModeReencodesOnlySanitizedDecodedEntriesWithSortedKeys() throws {
        let fixture = try makeRuntimeLogFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try CLIRunner().runSounding(arguments: [
            "app-diagnostics",
            "--log-directory", fixture.directory.path,
            "--tail", "10",
            "--raw",
        ])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        let output = result.stdoutText
        let jsonLines = output.split(separator: "\n").filter { $0.hasPrefix("{") }
        XCTAssertEqual(jsonLines.count, 3, output)
        XCTAssertTrue(jsonLines.contains { $0.contains(#""event":"runtime.started""#) }, output)
        XCTAssertTrue(
            jsonLines.contains { $0.contains(#""event":"runtime.decode.completed""#) }, output)
        XCTAssertTrue(jsonLines.contains { $0.contains(#""event":"runtime.failure""#) }, output)
        XCTAssertTrue(
            jsonLines.contains {
                $0.contains(#""fields":{"[redacted-secret-key]":"[redacted-secret]"#)
            }, output)
        XCTAssertTrue(
            jsonLines.allSatisfy { $0.first == "{" && $0.contains(#""timestamp""#) }, output)
        XCTAssertFalse(output.contains("malformed-secret"), output)
        XCTAssertFalse(output.contains("not-json"), output)
        assertSanitized(output, forbiddenLiterals: fixture.forbidden)
    }

    func testMissingAndEmptyLogsExitZeroWithoutPathLeakage() throws {
        let directory = try makeTemporaryDirectory(
            name: "missing-user:pass-token=synthetic-secret#frag")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("runtime-events.jsonl"))

        let result = try CLIRunner().runSounding(arguments: [
            "app-diagnostics",
            "--log-directory", directory.path,
            "--tail", "-10",
        ])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        let output = result.stdoutText
        XCTAssertTrue(output.contains("app-diagnostics logDirectory=[redacted-path]"), output)
        XCTAssertTrue(output.contains("app-diagnostics events=0 failures=0"), output)
        XCTAssertTrue(output.contains("app-diagnostics event-counts"), output)
        XCTAssertTrue(output.contains("app-diagnostics phase-counts"), output)
        XCTAssertTrue(output.contains("app-diagnostics recent-events"), output)
        XCTAssertTrue(output.contains("app-diagnostics recent-failures"), output)
        XCTAssertEqual(lines(in: output, containing: " event="), 0, output)
        assertSanitized(
            output,
            forbiddenLiterals: [
                directory.path,
                "user:pass",
                "synthetic-secret",
                "token=",
                "#frag",
                "runtime-events.jsonl",
            ])
    }

    func testEvidenceReviewRendersTypedPassWarnAndFailEvidenceWithoutPathLeakage() throws {
        let fixture = try makeEvidenceReviewFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try CLIRunner().runSounding(arguments: [
            "app-diagnostics",
            "--log-directory", fixture.emptyLogDirectory.path,
            "--evidence", fixture.passURL.path,
            "--evidence", fixture.warnURL.path,
            "--evidence", fixture.failURL.path,
        ])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        let output = result.stdoutText
        XCTAssertEqual(
            lines(in: output, containing: "app-diagnostics evidence=[redacted-path]"), 3, output)
        XCTAssertTrue(output.contains("schemaVersion=1 runID=fixture-pass status=pass"), output)
        XCTAssertTrue(
            output.contains("schemaVersion=1 runID=live-warn-[redacted-secret] status=warn"), output
        )
        XCTAssertTrue(
            output.contains("schemaVersion=1 runID=fixture-fail-[redacted-secret] status=fail"),
            output)
        XCTAssertTrue(output.contains("required=2 requiredFailures=0 warnings=0 checks=2"), output)
        XCTAssertTrue(output.contains("required=1 requiredFailures=0 warnings=1 checks=2"), output)
        XCTAssertTrue(output.contains("required=2 requiredFailures=1 warnings=0 checks=2"), output)
        XCTAssertTrue(output.contains("phase-counts"), output)
        XCTAssertTrue(output.contains("live_transcript=1"), output)
        XCTAssertTrue(output.contains("failed-required-checks"), output)
        XCTAssertTrue(
            output.contains(
                "check=playback_muted phase=playback_control required=true status=fail"), output)
        XCTAssertTrue(output.contains("warnings"), output)
        XCTAssertTrue(
            output.contains(
                "check=live_transcript_observed phase=live_transcript required=false status=warn"),
            output)
        XCTAssertTrue(output.contains("facts=control("), output)
        XCTAssertTrue(output.contains("facts=live("), output)
        XCTAssertTrue(output.contains("artifacts"), output)
        XCTAssertTrue(output.contains("kind=runtime-events path=[redacted-path]"), output)
        XCTAssertTrue(
            output.contains("kind=stream-source path=https://example.test/live.m3u8"), output)
        XCTAssertTrue(output.contains("recent-diagnostic-events"), output)
        XCTAssertTrue(output.contains("runtime.mute.requested"), output)
        XCTAssertTrue(output.contains("live.transcript.timeout"), output)
        XCTAssertTrue(output.contains("diagnosis"), output)
        XCTAssertTrue(
            output.contains(
                "diagnosis category=runtime check=decode_completed phase=decode status=pass"),
            output)
        XCTAssertTrue(
            output.contains(
                "diagnosis category=control check=playback_muted phase=playback_control status=fail"
            ), output)
        XCTAssertTrue(
            output.contains(
                "diagnosis category=live check=live_transcript_observed phase=live_transcript status=warn"
            ), output)
        assertSanitized(output, forbiddenLiterals: fixture.forbidden)
    }

    func testEvidenceReviewRendersSymptomDiagnosisHintsWithoutChangingWarnSemantics() throws {
        let fixture = try makeDiagnosisHintFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try CLIRunner().runSounding(arguments: [
            "app-diagnostics",
            "--log-directory", fixture.emptyLogDirectory.path,
            "--evidence", fixture.evidenceURL.path,
        ])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        let output = result.stdoutText
        XCTAssertTrue(output.contains("schemaVersion=1 runID=s06-diagnosis status=warn"), output)
        XCTAssertTrue(output.contains("required=4 requiredFailures=0 warnings=1 checks=4"), output)
        XCTAssertTrue(
            output.contains(
                "diagnosis category=runtime check=runtime_stopped phase=runtime_stop status=pass required=true"
            ), output)
        XCTAssertTrue(
            output.contains("events=runtime.running.detected|runtime.stop.requested"), output)
        XCTAssertTrue(
            output.contains(
                "diagnosis category=control check=playback_muted phase=playback_control status=pass"
            ), output)
        XCTAssertTrue(
            output.contains(
                "action=mute observedPhase=playback_control timeline=playing muted=true effectiveVolume=0.000"
            ), output)
        XCTAssertTrue(
            output.contains(
                "diagnosis category=projection check=transcript_search_projection phase=transcript_search_projection status=pass"
            ), output)
        XCTAssertTrue(output.contains("surface=search rows=0 projections=1 metadata=0"), output)
        XCTAssertTrue(
            output.contains(
                "diagnosis category=live check=live_metadata_observed phase=live_metadata status=warn required=false"
            ), output)
        XCTAssertTrue(
            output.contains("reason=Live metadata missing without optional facts"), output)
        XCTAssertFalse(output.contains("status=fail"), output)
        assertSanitized(output, forbiddenLiterals: fixture.forbidden)
    }

    func testMalformedEvidenceFailsWithControlledPathFreeError() throws {
        let directory = try makeTemporaryDirectory(
            name: "evidence-malformed-user:pass-token=synthetic-secret#frag")
        defer { try? FileManager.default.removeItem(at: directory) }
        let evidenceURL = directory.appendingPathComponent(
            "private-evidence-token=synthetic-secret.json")
        try #"{ "schemaVersion": 1, "runID": "token=synthetic-secret" "#.write(
            to: evidenceURL, atomically: true, encoding: .utf8)

        let result = try CLIRunner().runSounding(arguments: [
            "app-diagnostics",
            "--log-directory", directory.path,
            "--evidence", evidenceURL.path,
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertTrue(
            result.stderrText.contains(
                "app-diagnostics evidence=[redacted-path] error=malformed-app-verify-evidence"),
            result.stderrText)
        XCTAssertFalse(result.stderrText.contains("Foundation"), result.stderrText)
        assertSanitized(
            result.stdoutText + result.stderrText,
            forbiddenLiterals: [
                directory.path,
                evidenceURL.path,
                "user:pass",
                "synthetic-secret",
                "token=",
                "#frag",
                "private-evidence-token=synthetic-secret.json",
            ])
    }

    func testUnreadableEvidenceFailsWithControlledPathFreeError() throws {
        let directory = try makeTemporaryDirectory(
            name: "evidence-missing-user:pass-token=synthetic-secret#frag")
        defer { try? FileManager.default.removeItem(at: directory) }
        let evidenceURL = directory.appendingPathComponent("missing-token=synthetic-secret.json")

        let result = try CLIRunner().runSounding(arguments: [
            "app-diagnostics",
            "--log-directory", directory.path,
            "--evidence", evidenceURL.path,
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertTrue(
            result.stderrText.contains("app-diagnostics evidence=[redacted-path] error=unreadable"),
            result.stderrText)
        XCTAssertFalse(result.stderrText.contains("No such file"), result.stderrText)
        assertSanitized(
            result.stdoutText + result.stderrText,
            forbiddenLiterals: [
                directory.path,
                evidenceURL.path,
                "user:pass",
                "synthetic-secret",
                "token=",
                "#frag",
                "missing-token=synthetic-secret.json",
            ])
    }

    private struct RuntimeLogFixture {
        var directory: URL
        var forbidden: [String]
    }

    private func makeRuntimeLogFixture() throws -> RuntimeLogFixture {
        let directory = try Self.makeTemporaryDirectory(
            name: "app-diagnostics-user:pass-token=synthetic-secret#frag")
        let secretPath = directory.appendingPathComponent(
            "private-config-token=synthetic-secret.json"
        ).path
        let secretSource =
            "https://viewer:letmein@example.test/live.m3u8?token=synthetic-secret#private-fragment"
        let secretMessage = "opened \(secretSource) from \(secretPath) password=synthetic-secret"
        let malformedLine = "not-json malformed-secret token=synthetic-secret \(secretPath)"

        let events =
            [
                jsonLine([
                    "timestamp": "2026-05-02T01:00:00Z",
                    "level": "info",
                    "event": "runtime.started",
                    "streamID": 41,
                    "streamName": "Private stream token=synthetic-secret",
                    "source": secretSource,
                    "phase": "runtime_start",
                    "message": secretMessage,
                    "fields": [
                        "api_key": "synthetic-secret",
                        "configPath": secretPath,
                        "detail": "first-context",
                        "url": secretSource,
                    ],
                ]),
                malformedLine,
                jsonLine([
                    "timestamp": "2026-05-02T01:00:01Z",
                    "level": "info",
                    "event": "runtime.decode.completed",
                    "streamID": 42,
                    "streamName": "Public fixture",
                    "source": "file://\(secretPath)",
                    "phase": "decode",
                    "message": "decoded segment path=\(secretPath) access_token=synthetic-secret",
                    "fields": [
                        "detail": "kept-diagnostic-context",
                        "password": "synthetic-secret",
                    ],
                ]),
            ].joined(separator: "\n") + "\n"

        let failures =
            [
                malformedLine,
                jsonLine([
                    "timestamp": "2026-05-02T01:00:02Z",
                    "level": "error",
                    "event": "runtime.failure",
                    "streamID": 99,
                    "streamName": "Failure stream",
                    "source": secretSource,
                    "phase": "playback",
                    "errorType": "SyntheticError",
                    "message": "failed with user:pass token=synthetic-secret at \(secretPath)",
                    "fields": [
                        "detail": "failure-context",
                        "credential": "viewer:letmein",
                    ],
                ]),
            ].joined(separator: "\n") + "\n"

        try events.write(
            to: directory.appendingPathComponent("runtime-events.jsonl"), atomically: true,
            encoding: .utf8)
        try failures.write(
            to: directory.appendingPathComponent("runtime-errors.jsonl"), atomically: true,
            encoding: .utf8)

        return RuntimeLogFixture(
            directory: directory,
            forbidden: [
                directory.path,
                secretPath,
                secretSource,
                "viewer:letmein",
                "user:pass",
                "letmein",
                "synthetic-secret",
                "token=",
                "access_token=",
                "password=",
                "private-fragment",
                "#private-fragment",
                "private-config-token=synthetic-secret.json",
                malformedLine,
            ]
        )
    }

    private struct EvidenceReviewFixture {
        var directory: URL
        var emptyLogDirectory: URL
        var passURL: URL
        var warnURL: URL
        var failURL: URL
        var forbidden: [String]
    }

    private struct DiagnosisHintFixture {
        var directory: URL
        var emptyLogDirectory: URL
        var evidenceURL: URL
        var forbidden: [String]
    }

    private func makeDiagnosisHintFixture() throws -> DiagnosisHintFixture {
        let directory = try Self.makeTemporaryDirectory(
            name: "app-diagnostics-diagnosis-user:pass-token=synthetic-secret#frag")
        let emptyLogDirectory = directory.appendingPathComponent("empty-logs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: emptyLogDirectory, withIntermediateDirectories: true)
        let evidenceURL = directory.appendingPathComponent("diagnosis-token=synthetic-secret.json")
        let secretPath = directory.appendingPathComponent(
            "runtime-events-token=synthetic-secret.jsonl"
        ).path

        try evidenceJSON(
            runID: "s06-diagnosis",
            status: "warn",
            required: 4,
            failedRequired: 0,
            warnings: 1,
            checks: [
                checkJSON(
                    name: "runtime_stopped",
                    status: "pass",
                    required: true,
                    phase: "runtime_stop",
                    facts:
                        #""facts":{"phase":"runtime_stop","processedChunks":3,"decodedChunks":3,"scheduledBuffers":2,"diagnosticCount":2,"recentDiagnosticEvents":["runtime.running.detected","runtime.stop.requested"],"timelineSnapshotFields":{"state":"running"}}"#,
                    artifacts: [artifactJSON(kind: "runtime-events", path: secretPath)]
                ),
                checkJSON(
                    name: "playback_muted",
                    status: "pass",
                    required: true,
                    phase: "playback_control",
                    controlFacts:
                        #""controlFacts":{"requestedAction":"mute","observedRuntimePhase":"playback_control","timelineState":"playing","volume":0.5,"muted":true,"effectiveVolume":0,"diagnosticEventNames":["runtime.mute.requested"],"diagnostics":[],"beforeMarker":null,"afterMarker":null}"#
                ),
                checkJSON(
                    name: "transcript_search_projection",
                    status: "pass",
                    required: true,
                    phase: "transcript_search_projection",
                    projectionFacts:
                        #""projectionFacts":{"surface":"search","rowCount":0,"projectionCount":1,"metadataCount":0,"sampleFields":{"results":"1"},"recentDiagnosticEvents":["projection.search.updated"]}"#
                ),
                checkJSON(
                    name: "live_metadata_observed",
                    status: "warn",
                    required: false,
                    phase: "live_metadata",
                    reason: "Live metadata missing without optional facts"
                ),
            ],
            artifacts: [artifactJSON(kind: "runtime-events", path: secretPath)]
        ).write(to: evidenceURL, atomically: true, encoding: .utf8)

        return DiagnosisHintFixture(
            directory: directory,
            emptyLogDirectory: emptyLogDirectory,
            evidenceURL: evidenceURL,
            forbidden: [
                directory.path,
                emptyLogDirectory.path,
                evidenceURL.path,
                secretPath,
                "user:pass",
                "synthetic-secret",
                "token=",
                "private-fragment",
                "#frag",
                "diagnosis-token=synthetic-secret.json",
                "runtime-events-token=synthetic-secret.jsonl",
            ]
        )
    }

    private func makeEvidenceReviewFixture() throws -> EvidenceReviewFixture {
        let directory = try Self.makeTemporaryDirectory(
            name: "app-diagnostics-evidence-user:pass-token=synthetic-secret#frag")
        let emptyLogDirectory = directory.appendingPathComponent("empty-logs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: emptyLogDirectory, withIntermediateDirectories: true)
        let passURL = directory.appendingPathComponent("pass-token=synthetic-secret.json")
        let warnURL = directory.appendingPathComponent("warn-token=synthetic-secret.json")
        let failURL = directory.appendingPathComponent("fail-token=synthetic-secret.json")
        let secretSource =
            "https://user:pass@example.test/live.m3u8?token=synthetic-secret#private-fragment"
        let secretPath = directory.appendingPathComponent(
            "runtime-events-token=synthetic-secret.jsonl"
        ).path

        try evidenceJSON(
            runID: "fixture-pass",
            status: "pass",
            required: 2,
            failedRequired: 0,
            warnings: 0,
            checks: [
                checkJSON(
                    name: "fixture_source_created", status: "pass", required: true, phase: "fixture"
                ),
                checkJSON(
                    name: "decode_completed",
                    status: "pass",
                    required: true,
                    phase: "decode",
                    facts:
                        #""facts":{"phase":"decode","processedChunks":2,"decodedChunks":2,"scheduledBuffers":0,"diagnosticCount":1,"recentDiagnosticEvents":["decode.completed"],"timelineSnapshotFields":{}}"#
                ),
            ],
            artifacts: []
        ).write(to: passURL, atomically: true, encoding: .utf8)

        try evidenceJSON(
            runID: "live-warn-token=synthetic-secret",
            status: "warn",
            required: 1,
            failedRequired: 0,
            warnings: 1,
            checks: [
                checkJSON(
                    name: "live_stream_registered", status: "pass", required: true,
                    phase: "live_registration"),
                checkJSON(
                    name: "live_transcript_observed",
                    status: "warn",
                    required: false,
                    phase: "live_transcript",
                    reason: "Live transcript missing for \(secretSource)",
                    liveFacts: liveFactsJSON(
                        secretSource: secretSource, event: "live.transcript.timeout")
                ),
            ],
            artifacts: [artifactJSON(kind: "stream-source", path: secretSource)]
        ).write(to: warnURL, atomically: true, encoding: .utf8)

        try evidenceJSON(
            runID: "fixture-fail-token=synthetic-secret",
            status: "fail",
            required: 2,
            failedRequired: 1,
            warnings: 0,
            checks: [
                checkJSON(
                    name: "runtime_started", status: "pass", required: true, phase: "runtime_start"),
                checkJSON(
                    name: "playback_muted",
                    status: "fail",
                    required: true,
                    phase: "playback_control",
                    reason: "Missing mute proof from \(secretPath) for \(secretSource)",
                    controlFacts: controlFactsJSON(secretSource: secretSource),
                    artifacts: [artifactJSON(kind: "runtime-events", path: secretPath)]
                ),
            ],
            artifacts: [artifactJSON(kind: "runtime-events", path: secretPath)],
            metadata: ["source": secretSource, "configPath": secretPath]
        ).write(to: failURL, atomically: true, encoding: .utf8)

        return EvidenceReviewFixture(
            directory: directory,
            emptyLogDirectory: emptyLogDirectory,
            passURL: passURL,
            warnURL: warnURL,
            failURL: failURL,
            forbidden: [
                directory.path,
                emptyLogDirectory.path,
                passURL.path,
                warnURL.path,
                failURL.path,
                secretPath,
                secretSource,
                "user:pass",
                "synthetic-secret",
                "token=",
                "private-fragment",
                "#private-fragment",
                "pass-token=synthetic-secret.json",
                "warn-token=synthetic-secret.json",
                "fail-token=synthetic-secret.json",
                "runtime-events-token=synthetic-secret.jsonl",
            ]
        )
    }

    private func evidenceJSON(
        runID: String,
        status: String,
        required: Int,
        failedRequired: Int,
        warnings: Int,
        checks: [String],
        artifacts: [String],
        metadata: [String: String] = [:]
    ) -> String {
        let metadataJSON = metadata.map { #""\#($0.key)":"\#($0.value)""# }.sorted().joined(
            separator: ",")
        return """
            {
              "schemaVersion": 1,
              "generatedAt": "2026-05-02T18:00:00Z",
              "runID": "\(runID)",
              "summary": {
                "status": "\(status)",
                "requiredCheckCount": \(required),
                "failedRequiredCheckCount": \(failedRequired),
                "warningCheckCount": \(warnings),
                "message": "summary token=synthetic-secret"
              },
              "checks": [\(checks.joined(separator: ","))],
              "runtimeFacts": {"phase":"diagnostics","processedChunks":1,"decodedChunks":1,"scheduledBuffers":1,"diagnosticCount":1,"recentDiagnosticEvents":["runtime.summary.event"],"timelineSnapshotFields":{}},
              "artifacts": [\(artifacts.joined(separator: ","))],
              "metadata": {\(metadataJSON)}
            }
            """
    }

    private func checkJSON(
        name: String,
        status: String,
        required: Bool,
        phase: String,
        reason: String? = nil,
        facts: String? = nil,
        controlFacts: String? = nil,
        projectionFacts: String? = nil,
        liveFacts: String? = nil,
        artifacts: [String] = []
    ) -> String {
        let reasonField = reason.map { #","reason":"\#($0)""# } ?? ""
        let factsField = facts.map { ",\($0)" } ?? ""
        let controlFactsField = controlFacts.map { ",\($0)" } ?? ""
        let projectionFactsField = projectionFacts.map { ",\($0)" } ?? ""
        let liveFactsField = liveFacts.map { ",\($0)" } ?? ""
        return
            #"{"name":"\#(name)","status":"\#(status)","required":\#(required),"phase":"\#(phase)"\#(reasonField)\#(factsField)\#(controlFactsField)\#(projectionFactsField)\#(liveFactsField),"artifacts":[\#(artifacts.joined(separator: ","))]}"#
    }

    private func artifactJSON(kind: String, path: String) -> String {
        #"{"kind":"\#(kind)","path":"\#(path)","note":"note token=synthetic-secret"}"#
    }

    private func controlFactsJSON(secretSource: String) -> String {
        #""controlFacts":{"requestedAction":"mute \#(secretSource)","observedRuntimePhase":"playback_control","timelineState":"playing","volume":0.75,"muted":false,"effectiveVolume":0.75,"diagnosticEventNames":["runtime.mute.requested"],"diagnostics":[{"event":"runtime.mute.requested","phase":"runtime.volume","streamID":1,"message":"mute \#(secretSource)","fields":{"source":"\#(secretSource)"}}],"beforeMarker":"\#(secretSource)","afterMarker":"\#(secretSource)"}"#
    }

    private func liveFactsJSON(secretSource: String, event: String) -> String {
        #""liveFacts":{"streamID":"main-live-token=synthetic-secret","streamType":"hls","resolvedStreamType":"hls","redactedSource":"\#(secretSource)","timeoutSeconds":0.1,"maxChunks":1,"required":true,"transcriptExpectation":"warn","metadataExpectation":"warn","registeredStreamID":1,"processedChunks":1,"decodedChunks":1,"scheduledBuffers":1,"transcriptCount":0,"metadataCount":1,"diagnosticCount":1,"recentDiagnosticEvents":["\#(event)"],"fields":{"diagnosticsPath":"/tmp/sounding-token=synthetic-secret/events.jsonl","source":"\#(secretSource)"}}"#
    }

    private static func makeTemporaryDirectory(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeTemporaryDirectory(name: String) throws -> URL {
        try Self.makeTemporaryDirectory(name: name)
    }

    private func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func lines(in text: String, containing needle: String) -> Int {
        text.split(separator: "\n").filter { $0.contains(needle) }.count
    }

    private func assertSanitized(
        _ text: String,
        forbiddenLiterals: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for literal in forbiddenLiterals where !literal.isEmpty {
            XCTAssertFalse(
                text.contains(literal),
                "Expected app-diagnostics output to redact forbidden literal '\(literal)', got: \(text)",
                file: file,
                line: line
            )
        }
    }
}
