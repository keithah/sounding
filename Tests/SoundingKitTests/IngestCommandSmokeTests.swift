import Foundation
import GRDB
import XCTest

final class IngestCommandSmokeTests: XCTestCase {
    func testIngestHelpAdvertisesPublicBoundOptions() throws {
        let result = try runSounding(arguments: ["ingest", "--help"])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        let helpText = String(data: result.stdout, encoding: .utf8) ?? ""
        for text in ["--db", "--duration", "--max-chunks", "--stream-type"] {
            XCTAssertTrue(
                helpText.contains(text),
                "Expected help to advertise \(text). \(result.diagnosticSummary)")
        }
    }

    func testRejectsMissingBoundBeforeCreatingDatabase() throws {
        let dbURL = temporaryDatabaseURL(
            secretComponent: "missing-bound-user:pass@example.test?token=synthetic-secret#frag")
        defer { removeDatabaseFiles(dbURL) }

        let result = try runSounding(arguments: [
            "ingest",
            "https://viewer:letmein@example.test/live.m3u8?token=synthetic-secret#private-fragment",
            "--db", dbURL.path,
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path), result.diagnosticSummary)
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("Ingest configuration failed"), result.diagnosticSummary)
        XCTAssertTrue(stderr.contains("duration or max-chunks"), result.diagnosticSummary)
        assertSanitized(stderr, forbiddenLiteral: "viewer")
        assertSanitized(stderr, forbiddenLiteral: "letmein")
        assertSanitized(stderr, forbiddenLiteral: "synthetic-secret")
        assertSanitized(stderr, forbiddenLiteral: "private-fragment")
        assertSanitized(stderr, forbiddenLiteral: dbURL.path)
    }

    func testRejectsNonPositiveMaxChunksBeforeCreatingDatabase() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "bad-max-chunks-token=synthetic-secret")
        defer { removeDatabaseFiles(dbURL) }

        let result = try runSounding(arguments: [
            "ingest",
            "https://example.test/live.m3u8?token=synthetic-secret",
            "--db", dbURL.path,
            "--max-chunks", "0",
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path), result.diagnosticSummary)
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("Ingest configuration failed"), result.diagnosticSummary)
        XCTAssertTrue(
            stderr.contains("max-chunks must be greater than zero"), result.diagnosticSummary)
        assertSanitized(stderr, forbiddenLiteral: "synthetic-secret")
        assertSanitized(stderr, forbiddenLiteral: dbURL.path)
    }

    func testUnwritableDatabasePathFailsBeforeOpeningSourceOrModels() throws {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sounding-ingest-db-user:pass@example.test?token=synthetic-secret#frag",
                isDirectory: true)
        let dbURL = missingDirectory.appendingPathComponent("ingest.sqlite")
        defer { try? FileManager.default.removeItem(at: missingDirectory) }

        let result = try runSounding(arguments: [
            "ingest",
            "https://viewer:letmein@example.test/live.m3u8?token=synthetic-secret#private-fragment",
            "--db", dbURL.path,
            "--max-chunks", "1",
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("Ingest database failed"), result.diagnosticSummary)
        XCTAssertTrue(stderr.contains("redacted database path"), result.diagnosticSummary)
        assertSanitized(stderr, forbiddenLiteral: dbURL.path)
        assertSanitized(stderr, forbiddenLiteral: missingDirectory.path)
        assertSanitized(stderr, forbiddenLiteral: "viewer")
        assertSanitized(stderr, forbiddenLiteral: "letmein")
        assertSanitized(stderr, forbiddenLiteral: "synthetic-secret")
        assertSanitized(stderr, forbiddenLiteral: "private-fragment")
    }

    func testSourceOpenFailurePersistsRedactedDiagnosticRows() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "source-open")
        defer { removeDatabaseFiles(dbURL) }

        let result = try runSounding(arguments: [
            "ingest",
            "/tmp/sounding-missing-audio-token=synthetic-secret.wav",
            "--db", dbURL.path,
            "--stream-type", "icecast",
            "--max-chunks", "1",
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("Ingest sourceOpen failed"), result.diagnosticSummary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path), result.diagnosticSummary)

        let database = try DatabaseQueue(path: dbURL.path)
        let row = try database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT ingest_runs.status AS status,
                           ingest_diagnostics.phase AS phase,
                           ingest_diagnostics.reason AS reason,
                           ingest_diagnostics.source AS source,
                           ingest_diagnostics.context_json AS context
                    FROM ingest_runs
                    JOIN ingest_diagnostics ON ingest_diagnostics.run_id = ingest_runs.id
                    """)
        }
        XCTAssertEqual(row?["status"] as String?, "failed")
        XCTAssertEqual(row?["phase"] as String?, "sourceOpen")
        XCTAssertEqual(row?["reason"] as String?, "source-open-failed")
        let source: String? = row?["source"]
        let context: String? = row?["context"]
        XCTAssertFalse(source?.contains("synthetic-secret") ?? true, source ?? "nil")
        XCTAssertFalse(context?.contains("synthetic-secret") ?? true, context ?? "nil")
        assertSanitized(stderr, forbiddenLiteral: "synthetic-secret")
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

    private func soundingExecutableURL(file: StaticString = #filePath, line: UInt = #line) throws
        -> URL
    {
        let binPath = try swiftBuildBinPath(file: file, line: line)
        let executable = binPath.appendingPathComponent("sounding")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            XCTFail(
                "Missing compiled sounding executable at \(executable.path). Run `swift build --product sounding` before `swift test --filter IngestCommandSmokeTests`.",
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
                file: file, line: line)
            throw CLIError.missingExecutable
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func temporaryDatabaseURL(secretComponent: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-ingest-\(secretComponent)-\(UUID().uuidString)")
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
            "exit=\(exitCode), args=\(Self.sanitizedArguments(arguments)), stdoutLines=\(stdoutLineCount), stderr=\(IngestCommandSmokeTests.sanitizedSnippet(from: stderr))"
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
