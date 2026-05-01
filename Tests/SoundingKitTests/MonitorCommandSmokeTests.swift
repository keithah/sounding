import Foundation
import XCTest

final class MonitorCommandSmokeTests: XCTestCase {
    func testHLSSCTE35CLIEmitsManifestUnknownThenSegmentAdStart() throws {
        let result = try runMonitor(
            fixture: "Fixtures/HLS/manifest-scte35.m3u8",
            streamType: "hls",
            filter: "all"
        )

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 2, result.diagnosticSummary)
        let objects = try parseCLIStdout(result, sourceClass: "cli-hls-scte35")

        XCTAssertEqual(objects.count, 2, result.diagnosticSummary)
        assertSemanticMarker(objects, at: 0, sourceClass: "cli-hls-scte35", type: "SCTE35", source: "hls_manifest", classification: "UNKNOWN")
        assertSemanticMarker(objects, at: 1, sourceClass: "cli-hls-scte35", type: "SCTE35", source: "hls_segment", classification: "AD_START")
        try assertNoTopLevelBreakDurationKeys(objects, sourceClass: "cli-hls-scte35")
        XCTAssertEqual(semanticValue(at: "Command.Name", in: objects[0]) as? String, "Splice Null")
        XCTAssertEqual(semanticValue(at: "Command.Name", in: objects[1]) as? String, "Splice Insert")
        XCTAssertEqual(semanticValue(at: "Tags.MediaSequence", in: objects[1]) as? String, "7")
    }

    func testHLSID3CLIEmitsFilteredAdStart() throws {
        let result = try runMonitor(
            fixture: "Fixtures/HLS/manifest-id3.m3u8",
            streamType: "hls",
            filter: "ad_start"
        )

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 1, result.diagnosticSummary)
        let objects = try parseCLIStdout(result, sourceClass: "cli-hls-id3")

        XCTAssertEqual(objects.count, 1, result.diagnosticSummary)
        assertSemanticMarker(objects, at: 0, sourceClass: "cli-hls-id3", type: "ID3", source: "hls_segment", classification: "AD_START")
        try assertNoTopLevelBreakDurationKeys(objects, sourceClass: "cli-hls-id3")
        XCTAssertEqual(objects[0]["Segment"] as? String, "42")
        XCTAssertEqual(semanticValue(at: "Tags.TXXX:TIDEMARK", in: objects[0]) as? String, "AD|START")
        XCTAssertEqual(semanticValue(at: "Fields.SourceClass", in: objects[0]) as? String, "hls_segment")
    }

    func testMPEGTSCLIEmitsFilteredUnknownMarker() throws {
        let result = try runMonitor(
            fixture: "Fixtures/MPEGTS/scte35_splice_null.ts",
            streamType: "mpegts",
            filter: "unknown"
        )

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 1, result.diagnosticSummary)
        let objects = try parseCLIStdout(result, sourceClass: "cli-mpegts")

        XCTAssertEqual(objects.count, 1, result.diagnosticSummary)
        assertSemanticMarker(objects, at: 0, sourceClass: "cli-mpegts", type: "SCTE35", source: "mpegts", classification: "UNKNOWN")
        try assertNoTopLevelBreakDurationKeys(objects, sourceClass: "cli-mpegts")
        XCTAssertEqual(semanticValue(at: "Command.Name", in: objects[0]) as? String, "Splice Null")
        XCTAssertEqual(semanticValue(at: "Tags.SourceClass", in: objects[0]) as? String, "mpegts_stream")
        XCTAssertEqual(semanticValue(at: "Tags.StreamType", in: objects[0]) as? String, "mpegts")
    }

    func testUDPReplayCLIEmitsFilteredUnknownMarkerWithDistinctSourceClass() throws {
        let result = try runMonitor(
            fixture: "Fixtures/MPEGTS/scte35_splice_null.ts",
            streamType: "udp",
            filter: "unknown"
        )

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 1, result.diagnosticSummary)
        let objects = try parseCLIStdout(result, sourceClass: "cli-udp")

        XCTAssertEqual(objects.count, 1, result.diagnosticSummary)
        assertSemanticMarker(objects, at: 0, sourceClass: "cli-udp", type: "SCTE35", source: "udp", classification: "UNKNOWN")
        try assertNoTopLevelBreakDurationKeys(objects, sourceClass: "cli-udp")
        XCTAssertEqual(semanticValue(at: "Command.Name", in: objects[0]) as? String, "Splice Null")
        XCTAssertEqual(semanticValue(at: "Tags.SourceClass", in: objects[0]) as? String, "udp_datagram_replay")
        XCTAssertEqual(semanticValue(at: "Tags.StreamType", in: objects[0]) as? String, "udp")
    }

    func testJSONOutWritesSemanticMarkerNDJSONToTemporaryFile() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-monitor-smoke-\(UUID().uuidString)")
            .appendingPathExtension("ndjson")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let result = try runMonitor(
            fixture: "Fixtures/MPEGTS/scte35_splice_null.ts",
            streamType: "mpegts",
            filter: "unknown",
            emitJSON: false,
            extraArguments: ["--json-out", outputURL.path]
        )

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path), result.diagnosticSummary)

        let fileData = try Data(contentsOf: outputURL)
        let objects = try parseNDJSON(fileData, sourceClass: "cli-json-out", context: result.diagnosticSummary)

        XCTAssertEqual(objects.count, 1, result.diagnosticSummary)
        assertSemanticMarker(objects, at: 0, sourceClass: "cli-json-out", type: "SCTE35", source: "mpegts", classification: "UNKNOWN")
        try assertNoTopLevelBreakDurationKeys(objects, sourceClass: "cli-json-out")
    }

    func testJSONOutMissingDirectoryFailsWithRedactedOutputPhaseDiagnostic() throws {
        let secretEnvironmentValue = "sounding-env-secret-\(UUID().uuidString)"
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-json-out-user:pass@example.test?token=secret#frag-\(UUID().uuidString)", isDirectory: true)
        let outputURL = missingDirectory.appendingPathComponent("markers.ndjson")
        defer { try? FileManager.default.removeItem(at: missingDirectory) }

        let result = try runMonitor(
            fixture: "Fixtures/MPEGTS/scte35_splice_null.ts",
            streamType: "mpegts",
            filter: "unknown",
            emitJSON: false,
            extraArguments: ["--json-out", outputURL.path],
            environment: ["SOUNDING_MONITOR_SECRET_TEST_VALUE": secretEnvironmentValue]
        )

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)

        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("Monitor output failed"), result.diagnosticSummary)
        XCTAssertTrue(stderr.contains("mpegts"), result.diagnosticSummary)
        XCTAssertTrue(stderr.contains("outputPath=[redacted]"), result.diagnosticSummary)
        assertSanitized(stderr, forbiddenLiteral: outputURL.path)
        assertSanitized(stderr, forbiddenLiteral: missingDirectory.path)
        assertSanitized(stderr, forbiddenLiteral: "example.test")
        assertSanitized(stderr, forbiddenLiteral: "user:pass")
        assertSanitized(stderr, forbiddenLiteral: "token=secret")
        assertSanitized(stderr, forbiddenLiteral: "?token")
        assertSanitized(stderr, forbiddenLiteral: "#frag")
        assertSanitized(stderr, forbiddenLiteral: "markers.ndjson")
        assertSanitized(stderr, forbiddenLiteral: secretEnvironmentValue)
        assertSanitized(stderr, forbiddenLiteral: "0x47")
        assertSanitized(stderr, forbiddenLiteral: "FC30")
    }

    func testCLIRejectsInvalidFilterWithConfigurationDiagnostic() throws {
        let result = try runSounding(arguments: [
            "monitor",
            "https://viewer:letmein@example.test/live/manifest.m3u8?token=synthetic-secret#private-fragment",
            "--stream-type", "hls",
            "--filter", "bogus",
            "--json"
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)

        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("Monitor configuration failed"), result.diagnosticSummary)
        XCTAssertTrue(stderr.contains("unknown filter"), result.diagnosticSummary)
        assertSanitized(stderr, forbiddenLiteral: "viewer")
        assertSanitized(stderr, forbiddenLiteral: "letmein")
        assertSanitized(stderr, forbiddenLiteral: "synthetic-secret")
        assertSanitized(stderr, forbiddenLiteral: "?token")
        assertSanitized(stderr, forbiddenLiteral: "private-fragment")
    }

    func testCLIRejectsNegativeTimeoutWithRedactedConfigurationDiagnostic() throws {
        let result = try runSounding(arguments: [
            "monitor",
            "https://viewer:letmein@example.test/live/manifest.m3u8?token=synthetic-secret#private-fragment",
            "--stream-type", "hls",
            "--timeout=-1",
            "--json"
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)

        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("Monitor configuration failed"), result.diagnosticSummary)
        XCTAssertTrue(stderr.contains("timeout must be non-negative"), result.diagnosticSummary)
        XCTAssertTrue(stderr.contains("hls"), result.diagnosticSummary)
        XCTAssertTrue(stderr.contains("https://example.test/live/manifest.m3u8"), result.diagnosticSummary)
        assertSanitized(stderr, forbiddenLiteral: "viewer")
        assertSanitized(stderr, forbiddenLiteral: "letmein")
        assertSanitized(stderr, forbiddenLiteral: "synthetic-secret")
        assertSanitized(stderr, forbiddenLiteral: "?token")
        assertSanitized(stderr, forbiddenLiteral: "private-fragment")
    }

    func testCLISourceOpenFailureReportsPhaseAndRedactsURLSource() throws {
        let result = try runSounding(arguments: [
            "monitor",
            "file:///tmp/missing-live.ts?token=synthetic-secret#private-fragment",
            "--stream-type", "mpegts",
            "--quiet",
            "--filter", "all",
            "--json"
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)

        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("Monitor sourceOpen failed"), result.diagnosticSummary)
        XCTAssertTrue(stderr.contains("mpegts"), result.diagnosticSummary)
        XCTAssertTrue(stderr.contains("file:///tmp/missing-live.ts"), result.diagnosticSummary)
        assertSanitized(stderr, forbiddenLiteral: "synthetic-secret")
        assertSanitized(stderr, forbiddenLiteral: "?token")
        assertSanitized(stderr, forbiddenLiteral: "private-fragment")
        assertSanitized(stderr, forbiddenLiteral: "#")
    }

    func testMonitorHelpAdvertisesPublicSmokeOptions() throws {
        let result = try runSounding(arguments: ["monitor", "--help"])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        let helpText = String(data: result.stdout, encoding: .utf8) ?? ""
        for option in ["--stream-type", "--filter", "--json", "--json-out", "--quiet", "--timeout"] {
            XCTAssertTrue(helpText.contains(option), "Expected help to advertise \(option). \(result.diagnosticSummary)")
        }
    }

    private func runMonitor(
        fixture: String,
        streamType: String,
        filter: String,
        emitJSON: Bool = true,
        extraArguments: [String] = [],
        environment: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CLIResult {
        let source = fixtureURL(fixture, file: file, line: line).path
        var arguments = [
            "monitor",
            source,
            "--stream-type", streamType,
            "--quiet",
            "--filter", filter
        ]
        if emitJSON {
            arguments.append("--json")
        }
        return try runSounding(
            arguments: arguments + extraArguments,
            environment: environment,
            file: file,
            line: line
        )
    }

    private func runSounding(
        arguments: [String],
        environment: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CLIResult {
        let executable = try soundingExecutableURL(file: file, line: line)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = packageRootURL
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

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

    private func parseCLIStdout(
        _ result: CLIResult,
        sourceClass: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [[String: Any]] {
        try parseNDJSON(result.stdout, sourceClass: sourceClass, context: result.diagnosticSummary, file: file, line: line)
    }

    private func parseNDJSON(
        _ data: Data,
        sourceClass: String,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [[String: Any]] {
        do {
            if let text = String(data: data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertFalse(trimmed.hasPrefix("["), "\(sourceClass): monitor JSON output must be NDJSON objects, not a top-level array. \(context)", file: file, line: line)
            }
            let objects = try semanticJSONObjects(fromNDJSON: data, sourceClass: sourceClass, recordFailure: false, file: file, line: line)
            for object in objects {
                try assertPublicMarkerKeySet(object, sourceClass: sourceClass, recordFailure: false, file: file, line: line)
            }
            return objects
        } catch {
            XCTFail("\(sourceClass): failed to parse semantic marker NDJSON: \(error). \(context)", file: file, line: line)
            throw error
        }
    }

    private func soundingExecutableURL(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let binPath = try swiftBuildBinPath(file: file, line: line)
        let executable = binPath.appendingPathComponent("sounding")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            XCTFail("Missing compiled sounding executable at \(executable.path). Run `swift build --product sounding` before `swift test --filter MonitorCommandSmokeTests`.", file: file, line: line)
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

    private func fixtureURL(_ relativePath: String, file: StaticString, line: UInt) -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing fixture at \(relativePath)", file: file, line: line)
        return url
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
            "exit=\(exitCode), args=\(Self.sanitizedArguments(arguments)), stdoutLines=\(stdoutLineCount), stderr=\(MonitorCommandSmokeTests.sanitizedSnippet(from: stderr))"
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
                if argument == "--json-out" {
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
