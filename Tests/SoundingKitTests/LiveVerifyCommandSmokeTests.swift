import Foundation
import XCTest

final class LiveVerifyCommandSmokeTests: XCTestCase {
    func testLiveVerifyHelpAdvertisesPublicOptions() throws {
        let result = try runSounding(arguments: ["live-verify", "--help"])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        let helpText = String(data: result.stdout, encoding: .utf8) ?? ""
        for option in ["--config", "--evidence-out", "--format"] {
            XCTAssertTrue(helpText.contains(option), "Expected help to advertise \(option). \(result.diagnosticSummary)")
        }
    }

    func testMissingConfigPathFailsWithSanitizedConfigurationDiagnostic() throws {
        let missingConfig = FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-live-config-user:pass@example.test?token=synthetic-secret#frag-")
            .appendingPathExtension(UUID().uuidString)
        let evidenceURL = temporaryEvidenceURL(extension: "json")
        defer { try? FileManager.default.removeItem(at: evidenceURL) }

        let result = try runSounding(arguments: [
            "live-verify",
            "--config", missingConfig.path,
            "--evidence-out", evidenceURL.path
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("Live verification configuration failed"), result.diagnosticSummary)
        XCTAssertTrue(stderr.contains("redacted config path"), result.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path), result.diagnosticSummary)
        assertSanitized(stderr, forbiddenLiteral: missingConfig.path)
        assertSanitized(stderr, forbiddenLiteral: "user:pass")
        assertSanitized(stderr, forbiddenLiteral: "synthetic-secret")
        assertSanitized(stderr, forbiddenLiteral: "?token")
        assertSanitized(stderr, forbiddenLiteral: "#frag")
    }

    func testMalformedConfigFailsBeforeRunningStreamsWithoutSourceLeakage() throws {
        let secretSource = "https://viewer:letmein@example.test/live/manifest.m3u8?token=synthetic-secret#private-fragment"
        let configURL = temporaryConfigURL()
        let evidenceURL = temporaryEvidenceURL(extension: "json")
        defer {
            try? FileManager.default.removeItem(at: configURL)
            try? FileManager.default.removeItem(at: evidenceURL)
        }
        let malformedJSON = "{\"streams\":[{\"id\":\"bad\",\"source\":\"\(secretSource)\" "
        try malformedJSON.write(to: configURL, atomically: true, encoding: .utf8)

        let result = try runSounding(arguments: [
            "live-verify",
            "--config", configURL.path,
            "--evidence-out", evidenceURL.path
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path), result.diagnosticSummary)
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("Live verification configuration failed"), result.diagnosticSummary)
        XCTAssertTrue(stderr.contains("malformed JSON"), result.diagnosticSummary)
        assertSanitized(stderr, forbiddenLiteral: "viewer")
        assertSanitized(stderr, forbiddenLiteral: "letmein")
        assertSanitized(stderr, forbiddenLiteral: "synthetic-secret")
        assertSanitized(stderr, forbiddenLiteral: "private-fragment")
    }

    func testFixturePassAndOptionalFailureWritesRedactedJSONWithoutFailing() throws {
        let optionalSecretSource = "/tmp/private/missing-optional.ts?token=synthetic-secret#private-fragment"
        let configURL = temporaryConfigURL()
        let evidenceURL = temporaryEvidenceURL(extension: "json")
        defer {
            try? FileManager.default.removeItem(at: configURL)
            try? FileManager.default.removeItem(at: evidenceURL)
        }
        try writeConfig(
            streams: [
                liveStreamJSON(
                    id: "fixture-required",
                    source: mpegtsFixtureURL().path,
                    streamType: "mpegts",
                    filter: "scte35",
                    minimumMarkers: 1,
                    required: true
                ),
                liveStreamJSON(
                    id: "optional-missing",
                    source: optionalSecretSource,
                    streamType: "mpegts",
                    filter: "all",
                    minimumMarkers: 1,
                    required: false
                )
            ],
            to: configURL
        )

        let result = try runSounding(arguments: [
            "live-verify",
            "--config", configURL.path,
            "--evidence-out", evidenceURL.path
        ])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(stdout.contains("live verification passed"), result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("optionalFailures=1"), result.diagnosticSummary)
        assertSanitized(stdout, forbiddenLiteral: optionalSecretSource)
        assertSanitized(stdout, forbiddenLiteral: evidenceURL.path)

        let evidence = try jsonObject(at: evidenceURL)
        XCTAssertEqual(evidence["passed"] as? Bool, true, result.diagnosticSummary)
        XCTAssertEqual(evidence["requiredFailures"] as? Int, 0, result.diagnosticSummary)
        XCTAssertEqual(evidence["optionalFailures"] as? Int, 1, result.diagnosticSummary)
        let evidenceText = try String(contentsOf: evidenceURL)
        XCTAssertTrue(evidenceText.contains("stream_unavailable"), evidenceText)
        XCTAssertTrue(evidenceText.contains("optional-missing"), evidenceText)
        assertSanitized(evidenceText, forbiddenLiteral: "synthetic-secret")
        assertSanitized(evidenceText, forbiddenLiteral: "private-fragment")
        assertSanitized(evidenceText, forbiddenLiteral: "?token")
    }

    func testRequiredMissingSourceReturnsNonZeroAndWritesEvidence() throws {
        let requiredSecretSource = "/tmp/private/missing-required.ts?token=synthetic-secret#private-fragment"
        let configURL = temporaryConfigURL()
        let evidenceURL = temporaryEvidenceURL(extension: "json")
        defer {
            try? FileManager.default.removeItem(at: configURL)
            try? FileManager.default.removeItem(at: evidenceURL)
        }
        try writeConfig(
            streams: [
                liveStreamJSON(
                    id: "required-missing",
                    source: requiredSecretSource,
                    streamType: "mpegts",
                    filter: "all",
                    minimumMarkers: 1,
                    required: true
                )
            ],
            to: configURL
        )

        let result = try runSounding(arguments: [
            "live-verify",
            "--config", configURL.path,
            "--evidence-out", evidenceURL.path
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(stdout.contains("live verification failed"), result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("requiredFailures=1"), result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("required-missing:stream_unavailable:required"), result.diagnosticSummary)
        assertSanitized(stdout, forbiddenLiteral: requiredSecretSource)
        assertSanitized(stdout, forbiddenLiteral: evidenceURL.path)

        let evidenceText = try String(contentsOf: evidenceURL)
        XCTAssertTrue(evidenceText.contains("stream_unavailable"), evidenceText)
        XCTAssertTrue(evidenceText.contains("required-missing"), evidenceText)
        assertSanitized(evidenceText, forbiddenLiteral: "synthetic-secret")
        assertSanitized(evidenceText, forbiddenLiteral: "private-fragment")
        assertSanitized(evidenceText, forbiddenLiteral: "?token")
    }

    func testNDJSONFormatWritesOneObjectPerLine() throws {
        let configURL = temporaryConfigURL()
        let evidenceURL = temporaryEvidenceURL(extension: "ndjson")
        defer {
            try? FileManager.default.removeItem(at: configURL)
            try? FileManager.default.removeItem(at: evidenceURL)
        }
        try writeConfig(
            streams: [
                liveStreamJSON(
                    id: "fixture-required",
                    source: mpegtsFixtureURL().path,
                    streamType: "mpegts",
                    filter: "scte35",
                    minimumMarkers: 1,
                    required: true
                ),
                liveStreamJSON(
                    id: "optional-missing",
                    source: "/tmp/private/missing-optional.ts?token=synthetic-secret#private-fragment",
                    streamType: "mpegts",
                    filter: "all",
                    minimumMarkers: 1,
                    required: false
                )
            ],
            to: configURL
        )

        let result = try runSounding(arguments: [
            "live-verify",
            "--config", configURL.path,
            "--evidence-out", evidenceURL.path,
            "--format", "ndjson"
        ])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        let evidenceText = try String(contentsOf: evidenceURL)
        let lines = evidenceText.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2, evidenceText)
        XCTAssertFalse(evidenceText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("["), evidenceText)
        for line in lines {
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertNotNil(object["category"], evidenceText)
        }
        assertSanitized(evidenceText, forbiddenLiteral: "synthetic-secret")
    }

    func testUnwritableEvidencePathFailsWithoutOutputPathLeakage() throws {
        let configURL = temporaryConfigURL()
        let secretDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-live-evidence-user:pass@example.test?token=synthetic-secret#frag-")
            .appendingPathExtension(UUID().uuidString)
        let evidenceURL = secretDirectory.appendingPathComponent("evidence.json")
        defer {
            try? FileManager.default.removeItem(at: configURL)
            try? FileManager.default.removeItem(at: secretDirectory)
        }
        try writeConfig(
            streams: [
                liveStreamJSON(
                    id: "fixture-required",
                    source: mpegtsFixtureURL().path,
                    streamType: "mpegts",
                    filter: "scte35",
                    minimumMarkers: 1,
                    required: true
                )
            ],
            to: configURL
        )

        let result = try runSounding(arguments: [
            "live-verify",
            "--config", configURL.path,
            "--evidence-out", evidenceURL.path
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("Live verification output failed"), result.diagnosticSummary)
        XCTAssertTrue(stderr.contains("redacted output path"), result.diagnosticSummary)
        assertSanitized(stderr, forbiddenLiteral: evidenceURL.path)
        assertSanitized(stderr, forbiddenLiteral: secretDirectory.path)
        assertSanitized(stderr, forbiddenLiteral: "user:pass")
        assertSanitized(stderr, forbiddenLiteral: "synthetic-secret")
        assertSanitized(stderr, forbiddenLiteral: "?token")
        assertSanitized(stderr, forbiddenLiteral: "#frag")
        assertSanitized(stderr, forbiddenLiteral: "evidence.json")
    }

    private func runSounding(
        arguments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CLIResult {
        let executable = try soundingExecutableURL(file: file, line: line)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = packageRootURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        return CLIResult(
            exitCode: process.terminationStatus,
            stdout: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            arguments: arguments
        )
    }

    private func soundingExecutableURL(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let binPath = try swiftBuildBinPath(file: file, line: line)
        let executable = binPath.appendingPathComponent("sounding")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            XCTFail("Missing compiled sounding executable at \(executable.path). Run `swift build --product sounding` before `swift test --filter LiveVerifyCommandSmokeTests`.", file: file, line: line)
            throw CLIError.missingExecutable
        }
        return executable
    }

    private func swiftBuildBinPath(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "build", "--show-bin-path"]
        process.currentDirectoryURL = packageRootURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let path = String(data: stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            let stderrSnippet = Self.sanitizedSnippet(from: stderr)
            XCTFail("Could not resolve Swift build bin path; exit=\(process.terminationStatus), stderr=\(stderrSnippet)", file: file, line: line)
            throw CLIError.missingExecutable
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func writeConfig(streams: [String], to url: URL) throws {
        let payload = "{\"streams\":[\(streams.joined(separator: ","))]}"
        try payload.write(to: url, atomically: true, encoding: .utf8)
    }

    private func liveStreamJSON(
        id: String,
        source: String,
        streamType: String,
        filter: String,
        minimumMarkers: Int,
        required: Bool
    ) throws -> String {
        let object: [String: Any] = [
            "id": id,
            "source": source,
            "streamType": streamType,
            "filter": filter,
            "minimumMarkers": minimumMarkers,
            "required": required
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func temporaryConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-live-config-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }

    private func temporaryEvidenceURL(extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-live-evidence-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }

    private func mpegtsFixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/MPEGTS/scte35_splice_null.ts")
    }

    private var packageRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private enum CLIError: Error {
        case missingExecutable
    }

    private struct CLIResult {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
        let arguments: [String]

        var stdoutLineCount: Int {
            String(data: stdout, encoding: .utf8)?
                .split(separator: "\n", omittingEmptySubsequences: true)
                .count ?? 0
        }

        var diagnosticSummary: String {
            "exit=\(exitCode), args=\(Self.sanitizedArguments(arguments)), stdoutLines=\(stdoutLineCount), stderr=\(LiveVerifyCommandSmokeTests.sanitizedSnippet(from: stderr))"
        }

        private static func sanitizedArguments(_ arguments: [String]) -> [String] {
            var sanitized: [String] = []
            var redactNext = false
            for argument in arguments {
                if redactNext {
                    sanitized.append("<redacted-path>")
                    redactNext = false
                    continue
                }
                if ["--config", "--evidence-out"].contains(argument) {
                    sanitized.append(argument)
                    redactNext = true
                } else if argument.contains("://") || argument.contains("?") || argument.contains("#") {
                    sanitized.append("<redacted-source>")
                } else {
                    sanitized.append(argument)
                }
            }
            return sanitized
        }
    }

    private static func sanitizedSnippet(from data: Data, maxLength: Int = 300) -> String {
        let text = String(data: data, encoding: .utf8) ?? "<non-utf8 stderr>"
        var sanitized = text
            .replacingOccurrences(of: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s]+"#, with: "<redacted-url>", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(token|secret|password|key)=([^\s&]+)"#, with: "$1=<redacted>", options: .regularExpression)
            .replacingOccurrences(of: #"\?.*"#, with: "?<redacted>", options: .regularExpression)
        if sanitized.count > maxLength {
            sanitized = String(sanitized.prefix(maxLength)) + "…"
        }
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func assertSanitized(
        _ text: String,
        forbiddenLiteral: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            text.contains(forbiddenLiteral),
            "Expected diagnostic to redact forbidden literal '\(forbiddenLiteral)', got: \(text)",
            file: file,
            line: line
        )
    }
}
