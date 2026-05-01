import Foundation
import XCTest

@testable import SoundingKit

final class ReportCommandSmokeTests: XCTestCase {
    func testHelpAdvertisesReportPlaysCommandAndOptions() throws {
        let root = try runSounding(arguments: ["--help"])
        XCTAssertEqual(root.exitCode, 0, root.diagnosticSummary)
        let rootHelp = String(data: root.stdout, encoding: .utf8) ?? ""
        for command in ["monitor", "live-verify", "ingest", "search", "count", "report"] {
            XCTAssertTrue(
                rootHelp.contains(command),
                "Expected root help to advertise \(command). \(root.diagnosticSummary)")
        }

        let report = try runSounding(arguments: ["report", "--help"])
        XCTAssertEqual(report.exitCode, 0, report.diagnosticSummary)
        let reportHelp = String(data: report.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(reportHelp.contains("plays"), report.diagnosticSummary)

        let plays = try runSounding(arguments: ["report", "plays", "--help"])
        XCTAssertEqual(plays.exitCode, 0, plays.diagnosticSummary)
        let playsHelp = String(data: plays.stdout, encoding: .utf8) ?? ""
        for flag in ["--db", "--json", "--stream", "--start-seconds", "--end-seconds"] {
            XCTAssertTrue(
                playsHelp.contains(flag),
                "Expected report plays help to advertise \(flag). \(plays.diagnosticSummary)")
        }
    }

    func testFixtureBackedIngestReportsSongPlaysAsHumanAndJSON() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "fixture-report")
        defer { removeDatabaseFiles(dbURL) }
        let fixture =
            packageRootURL
            .appendingPathComponent("Tests/SoundingKitTests/Fixtures/HLS/manifest-scte35.m3u8")

        let ingest = try runSounding(
            arguments: [
                "ingest",
                fixture.path,
                "--db", dbURL.path,
                "--stream-type", "hls",
                "--max-chunks", "1",
            ],
            environment: ["SOUNDING_DETERMINISTIC_ML": "1"]
        )
        XCTAssertEqual(ingest.exitCode, 0, ingest.diagnosticSummary)

        let human = try runSounding(arguments: [
            "report", "plays",
            "--db", dbURL.path,
        ])
        XCTAssertEqual(human.exitCode, 0, human.diagnosticSummary)
        let humanText = String(data: human.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(humanText.contains("Play 1:"), human.diagnosticSummary)
        XCTAssertTrue(humanText.contains("stream="), human.diagnosticSummary)
        XCTAssertTrue(humanText.contains("run="), human.diagnosticSummary)
        XCTAssertTrue(humanText.contains("song=unknown("), human.diagnosticSummary)
        XCTAssertTrue(humanText.contains("song_key=fingerprint:"), human.diagnosticSummary)
        XCTAssertTrue(
            humanText.contains("source=deterministic_fingerprint"), human.diagnosticSummary)
        assertSanitized(humanText, forbiddenLiteral: fixture.path)
        assertSanitized(humanText, forbiddenLiteral: dbURL.path)

        let json = try runSounding(arguments: [
            "report", "plays",
            "--db", dbURL.path,
            "--json",
        ])
        XCTAssertEqual(json.exitCode, 0, json.diagnosticSummary)
        let payload = try decodeJSON(
            PlaysPayload.self, from: json.stdout, context: json.diagnosticSummary)
        XCTAssertEqual(payload.results.count, 1, json.diagnosticSummary)
        let play = try XCTUnwrap(payload.results.first, json.diagnosticSummary)
        XCTAssertEqual(play.identity.streamType, "hls", json.diagnosticSummary)
        XCTAssertTrue(play.song.songKey.hasPrefix("fingerprint:"), json.diagnosticSummary)
        XCTAssertTrue(play.song.isUnknown, json.diagnosticSummary)
        XCTAssertEqual(play.source, "deterministic_fingerprint", json.diagnosticSummary)
        let jsonText = String(data: json.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"))
        XCTAssertFalse(jsonText.contains("Play 1:"), json.diagnosticSummary)
        assertSanitized(jsonText, forbiddenLiteral: fixture.path)
        assertSanitized(jsonText, forbiddenLiteral: dbURL.path)
    }

    func testFiltersAndEmptyDatabaseReportStableShapes() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "empty-report")
        defer { removeDatabaseFiles(dbURL) }
        _ = try SoundingDatabase(fileURL: dbURL)

        let human = try runSounding(arguments: ["report", "plays", "--db", dbURL.path])
        XCTAssertEqual(human.exitCode, 0, human.diagnosticSummary)
        XCTAssertEqual(String(data: human.stdout, encoding: .utf8), "No song plays found.\n")

        let json = try runSounding(arguments: [
            "report", "plays", "--db", dbURL.path, "--json",
        ])
        XCTAssertEqual(json.exitCode, 0, json.diagnosticSummary)
        let payload = try decodeJSON(
            PlaysPayload.self, from: json.stdout, context: json.diagnosticSummary)
        XCTAssertEqual(payload.results.count, 0, json.diagnosticSummary)
        let jsonText = String(data: json.stdout, encoding: .utf8) ?? ""
        XCTAssertFalse(jsonText.contains("No song plays found"), json.diagnosticSummary)
    }

    func testValidationRejectsMalformedInputsBeforeOpeningDatabase() throws {
        let invalidCases: [[String]] = [
            [
                "report", "plays",
                "--db",
                temporaryDatabaseURL(secretComponent: "blank-stream-token=synthetic-secret").path,
                "--stream", "   \t",
            ],
            [
                "report", "plays",
                "--db",
                temporaryDatabaseURL(secretComponent: "bad-time-token=synthetic-secret").path,
                "--start-seconds", "30",
                "--end-seconds", "20",
            ],
            [
                "report", "plays",
                "--db",
                temporaryDatabaseURL(secretComponent: "nan-time-token=synthetic-secret").path,
                "--start-seconds", "nan",
            ],
        ]

        for arguments in invalidCases {
            let dbIndex =
                try XCTUnwrap(arguments.firstIndex(of: "--db"), "Expected --db argument") + 1
            let dbPath = arguments[dbIndex]
            defer { removeDatabaseFiles(URL(fileURLWithPath: dbPath)) }

            let result = try runSounding(arguments: arguments)
            XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
            XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath), result.diagnosticSummary)
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            XCTAssertTrue(stderr.contains("Report configuration failed"), result.diagnosticSummary)
            assertSanitized(stderr, forbiddenLiteral: dbPath)
            assertSanitized(stderr, forbiddenLiteral: "synthetic-secret")
        }

        let missingDB = try runSounding(arguments: ["report", "plays"])
        XCTAssertNotEqual(missingDB.exitCode, 0, missingDB.diagnosticSummary)
        XCTAssertEqual(missingDB.stdoutLineCount, 0, missingDB.diagnosticSummary)
        let missingDBStderr = String(data: missingDB.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(missingDBStderr.contains("--db"), missingDB.diagnosticSummary)
    }

    func testUnopenableDatabasePathIsRedacted() throws {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sounding-report-db-user:pass@example.test?token=synthetic-secret#frag",
                isDirectory: true)
        let dbURL = missingDirectory.appendingPathComponent("report.sqlite")
        defer { try? FileManager.default.removeItem(at: missingDirectory) }

        let result = try runSounding(arguments: [
            "report", "plays",
            "--db", dbURL.path,
            "--stream", "https://user:pass@example.test/live.m3u8?token=synthetic-secret#frag",
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("Report database failed"), result.diagnosticSummary)
        XCTAssertTrue(stderr.contains("redacted database path"), result.diagnosticSummary)
        assertSanitized(stderr, forbiddenLiteral: dbURL.path)
        assertSanitized(stderr, forbiddenLiteral: missingDirectory.path)
        assertSanitized(stderr, forbiddenLiteral: "synthetic-secret")
        assertSanitized(stderr, forbiddenLiteral: "user:pass")
    }

    private struct PlaysPayload: Decodable {
        var results: [Play]
    }

    private struct Play: Decodable {
        var identity: Identity
        var song: Song
        var source: String?
    }

    private struct Identity: Decodable {
        var streamType: String
    }

    private struct Song: Decodable {
        var songKey: String
        var isUnknown: Bool
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
            process.environment = ProcessInfo.processInfo.environment.merging(environment) {
                _, new in new
            }
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

    private func soundingExecutableURL(file: StaticString = #filePath, line: UInt = #line) throws
        -> URL
    {
        let binPath = try swiftBuildBinPath(file: file, line: line)
        let executable = binPath.appendingPathComponent("sounding")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            XCTFail(
                "Missing compiled sounding executable at \(executable.path). Run `swift build --product sounding` before `swift test --filter ReportCommandSmokeTests`.",
                file: file, line: line)
            throw CLIError.missingExecutable
        }
        return executable
    }

    private func swiftBuildBinPath(file: StaticString = #filePath, line: UInt = #line) throws -> URL
    {
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
            let path = String(data: stdout, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            !path.isEmpty
        else {
            let stderrSnippet = Self.sanitizedSnippet(from: stderr)
            XCTFail(
                "Could not resolve Swift build bin path; exit=\(process.terminationStatus), stderr=\(stderrSnippet)",
                file: file,
                line: line
            )
            throw CLIError.missingExecutable
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            XCTFail(
                "Failed to decode CLI JSON as \(type): \(error). \(context); stdout=\(Self.sanitizedSnippet(from: data))",
                file: file,
                line: line
            )
            throw CLIError.invalidJSON
        }
    }

    private func temporaryDatabaseURL(secretComponent: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-report-\(secretComponent)-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func removeDatabaseFiles(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    private var packageRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private enum CLIError: Error {
        case missingExecutable
        case invalidJSON
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
            "exit=\(exitCode), args=\(Self.sanitizedArguments(arguments)), stdoutLines=\(stdoutLineCount), stderr=\(ReportCommandSmokeTests.sanitizedSnippet(from: stderr))"
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
                if argument == "--db" {
                    sanitized.append(argument)
                    redactNext = true
                } else if argument.contains("://") || argument.contains("?")
                    || argument.contains("#")
                {
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
        var sanitized =
            text
            .replacingOccurrences(
                of: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s]+"#, with: "<redacted-url>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)(token|secret|password|key)=([^\s&]+)"#, with: "$1=<redacted>",
                options: .regularExpression
            )
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
