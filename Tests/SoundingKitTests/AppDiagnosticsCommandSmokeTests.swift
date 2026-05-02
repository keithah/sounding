import Foundation
import XCTest

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
        XCTAssertTrue(output.contains("event=runtime.decode.completed stream=42 phase=decode"), output)
        XCTAssertTrue(output.contains("fields=detail:kept-diagnostic-context"), output)
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
        XCTAssertTrue(jsonLines.contains { $0.contains(#""event":"runtime.decode.completed""#) }, output)
        XCTAssertTrue(jsonLines.contains { $0.contains(#""event":"runtime.failure""#) }, output)
        XCTAssertTrue(jsonLines.contains { $0.contains(#""fields":{"[redacted-secret-key]":"[redacted-secret]"#) }, output)
        XCTAssertTrue(jsonLines.allSatisfy { $0.first == "{" && $0.contains(#""timestamp""#) }, output)
        XCTAssertFalse(output.contains("malformed-secret"), output)
        XCTAssertFalse(output.contains("not-json"), output)
        assertSanitized(output, forbiddenLiterals: fixture.forbidden)
    }

    func testMissingAndEmptyLogsExitZeroWithoutPathLeakage() throws {
        let directory = try makeTemporaryDirectory(name: "missing-user:pass-token=synthetic-secret#frag")
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
        assertSanitized(output, forbiddenLiterals: [
            directory.path,
            "user:pass",
            "synthetic-secret",
            "token=",
            "#frag",
            "runtime-events.jsonl",
        ])
    }

    private struct RuntimeLogFixture {
        var directory: URL
        var forbidden: [String]
    }

    private func makeRuntimeLogFixture() throws -> RuntimeLogFixture {
        let directory = try Self.makeTemporaryDirectory(name: "app-diagnostics-user:pass-token=synthetic-secret#frag")
        let secretPath = directory.appendingPathComponent("private-config-token=synthetic-secret.json").path
        let secretSource = "https://viewer:letmein@example.test/live.m3u8?token=synthetic-secret#private-fragment"
        let secretMessage = "opened \(secretSource) from \(secretPath) password=synthetic-secret"
        let malformedLine = "not-json malformed-secret token=synthetic-secret \(secretPath)"

        let events = [
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

        let failures = [
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

        try events.write(to: directory.appendingPathComponent("runtime-events.jsonl"), atomically: true, encoding: .utf8)
        try failures.write(to: directory.appendingPathComponent("runtime-errors.jsonl"), atomically: true, encoding: .utf8)

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
