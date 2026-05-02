import Foundation
import XCTest

final class DatabaseCommandSmokeTests: XCTestCase {
    func testHelpAdvertisesDatabaseCommandsAndOptions() throws {
        let root = try runSounding(arguments: ["--help"])
        XCTAssertEqual(root.exitCode, 0, root.diagnosticSummary)
        XCTAssertTrue((String(data: root.stdout, encoding: .utf8) ?? "").contains("database"), root.diagnosticSummary)

        let database = try runSounding(arguments: ["database", "--help"])
        XCTAssertEqual(database.exitCode, 0, database.diagnosticSummary)
        let databaseHelp = String(data: database.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(databaseHelp.contains("health"), database.diagnosticSummary)
        XCTAssertTrue(databaseHelp.contains("checkpoint"), database.diagnosticSummary)

        let health = try runSounding(arguments: ["database", "health", "--help"])
        XCTAssertEqual(health.exitCode, 0, health.diagnosticSummary)
        let healthHelp = String(data: health.stdout, encoding: .utf8) ?? ""
        for text in ["--db", "--json", "--check-depth"] {
            XCTAssertTrue(healthHelp.contains(text), health.diagnosticSummary)
        }

        let checkpoint = try runSounding(arguments: ["database", "checkpoint", "--help"])
        XCTAssertEqual(checkpoint.exitCode, 0, checkpoint.diagnosticSummary)
        let checkpointHelp = String(data: checkpoint.stdout, encoding: .utf8) ?? ""
        for text in ["--db", "--json", "--mode", "--check-depth"] {
            XCTAssertTrue(checkpointHelp.contains(text), checkpoint.diagnosticSummary)
        }
    }

    func testHealthHumanAndJSONOutputsAreRedactedAndDeterministic() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "health-token=synthetic-secret")
        defer { removeDatabaseFiles(dbURL) }

        let human = try runSounding(arguments: ["database", "health", "--db", dbURL.path])
        XCTAssertEqual(human.exitCode, 0, human.diagnosticSummary)
        XCTAssertEqual(human.stderr.count, 0, human.diagnosticSummary)
        let humanText = String(data: human.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(humanText.contains("Database health: status=healthy"), human.diagnosticSummary)
        XCTAssertTrue(humanText.contains("journal_mode=wal"), human.diagnosticSummary)
        XCTAssertTrue(humanText.contains("Check quick_check: status=ok"), human.diagnosticSummary)
        XCTAssertTrue(humanText.contains("Check foreign_key_check: status=ok"), human.diagnosticSummary)
        assertDatabaseOutputSanitized(humanText, dbURL: dbURL)

        let json = try runSounding(arguments: [
            "database", "health", "--db", dbURL.path, "--json", "--check-depth", "integrity",
        ])
        XCTAssertEqual(json.exitCode, 0, json.diagnosticSummary)
        XCTAssertEqual(json.stderr.count, 0, json.diagnosticSummary)
        let jsonText = String(data: json.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonText.hasSuffix("\n"), json.diagnosticSummary)
        XCTAssertLessThan(jsonText.range(of: "\"checkDepth\"")!.lowerBound, jsonText.range(of: "\"command\"")!.lowerBound)
        let payload = try decodeJSON(DatabasePayload.self, from: json.stdout, context: json.diagnosticSummary)
        XCTAssertEqual(payload.command, "health", json.diagnosticSummary)
        XCTAssertEqual(payload.checkDepth, "integrity", json.diagnosticSummary)
        XCTAssertEqual(payload.ok, true, json.diagnosticSummary)
        XCTAssertEqual(payload.health.status, "healthy", json.diagnosticSummary)
        XCTAssertEqual(payload.health.journalMode, "wal", json.diagnosticSummary)
        XCTAssertGreaterThan(payload.health.files.databaseBytes, 0, json.diagnosticSummary)
        XCTAssertEqual(payload.health.quickCheck.status, "ok", json.diagnosticSummary)
        XCTAssertEqual(payload.health.foreignKeyCheck.status, "ok", json.diagnosticSummary)
        XCTAssertEqual(payload.health.integrityCheck?.status, "ok", json.diagnosticSummary)
        XCTAssertNil(payload.health.failure, json.diagnosticSummary)
        assertDatabaseOutputSanitized(jsonText, dbURL: dbURL)
    }

    func testCheckpointHumanAndJSONOutputsDecodeAndRemainRedacted() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "checkpoint-token=synthetic-secret")
        defer { removeDatabaseFiles(dbURL) }
        XCTAssertEqual(try runSounding(arguments: ["database", "health", "--db", dbURL.path]).exitCode, 0)

        let human = try runSounding(arguments: [
            "database", "checkpoint", "--db", dbURL.path, "--mode", "passive",
        ])
        XCTAssertEqual(human.exitCode, 0, human.diagnosticSummary)
        XCTAssertEqual(human.stderr.count, 0, human.diagnosticSummary)
        let humanText = String(data: human.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(humanText.contains("Database checkpoint: mode=passive status=healthy"), human.diagnosticSummary)
        XCTAssertTrue(humanText.contains("Checkpoint frames: busy="), human.diagnosticSummary)
        XCTAssertTrue(humanText.contains("Post-checkpoint health: status=healthy"), human.diagnosticSummary)
        assertDatabaseOutputSanitized(humanText, dbURL: dbURL)

        let json = try runSounding(arguments: [
            "database", "checkpoint", "--db", dbURL.path, "--json", "--mode", "passive",
        ])
        XCTAssertEqual(json.exitCode, 0, json.diagnosticSummary)
        XCTAssertEqual(json.stderr.count, 0, json.diagnosticSummary)
        let payload = try decodeJSON(DatabasePayload.self, from: json.stdout, context: json.diagnosticSummary)
        XCTAssertEqual(payload.command, "checkpoint", json.diagnosticSummary)
        XCTAssertEqual(payload.mode, "passive", json.diagnosticSummary)
        XCTAssertEqual(payload.ok, true, json.diagnosticSummary)
        XCTAssertEqual(payload.checkpoint?.status, "healthy", json.diagnosticSummary)
        XCTAssertGreaterThanOrEqual(payload.checkpoint?.busyFrameCount ?? -1, 0, json.diagnosticSummary)
        XCTAssertGreaterThanOrEqual(payload.checkpoint?.logFrameCount ?? -1, 0, json.diagnosticSummary)
        XCTAssertGreaterThanOrEqual(payload.checkpoint?.checkpointedFrameCount ?? -1, 0, json.diagnosticSummary)
        assertDatabaseOutputSanitized(String(data: json.stdout, encoding: .utf8) ?? "", dbURL: dbURL)
    }

    func testInvalidModeAndCheckDepthFailBeforeDatabaseWork() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "invalid-token=synthetic-secret")
        defer { removeDatabaseFiles(dbURL) }

        let invalidMode = try runSounding(arguments: [
            "database", "checkpoint", "--db", dbURL.path, "--mode", "vacuum",
        ])
        XCTAssertNotEqual(invalidMode.exitCode, 0, invalidMode.diagnosticSummary)
        XCTAssertEqual(invalidMode.stdoutLineCount, 0, invalidMode.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path), invalidMode.diagnosticSummary)

        let invalidDepth = try runSounding(arguments: [
            "database", "health", "--db", dbURL.path, "--check-depth", "deep",
        ])
        XCTAssertNotEqual(invalidDepth.exitCode, 0, invalidDepth.diagnosticSummary)
        XCTAssertEqual(invalidDepth.stdoutLineCount, 0, invalidDepth.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path), invalidDepth.diagnosticSummary)
    }

    func testOpenAndCorruptFailuresAreNonZeroActionableAndRedacted() throws {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sounding-database-user:pass@example.test?token=synthetic-secret#frag",
                isDirectory: true
            )
        let missingURL = missingDirectory.appendingPathComponent("database.sqlite")
        defer { try? FileManager.default.removeItem(at: missingDirectory) }

        let missing = try runSounding(arguments: [
            "database", "health", "--db", missingURL.path,
        ])
        XCTAssertNotEqual(missing.exitCode, 0, missing.diagnosticSummary)
        XCTAssertEqual(missing.stdoutLineCount, 0, missing.diagnosticSummary)
        let missingStderr = String(data: missing.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(missingStderr.contains("Database health failed"), missing.diagnosticSummary)
        XCTAssertTrue(missingStderr.contains("phase=open"), missing.diagnosticSummary)
        XCTAssertTrue(missingStderr.contains("redacted database path"), missing.diagnosticSummary)
        assertDatabaseOutputSanitized(missingStderr, dbURL: missingURL)

        let corruptURL = temporaryDatabaseURL(secretComponent: "corrupt-token=synthetic-secret")
        try Data("not sqlite".utf8).write(to: corruptURL)
        defer { removeDatabaseFiles(corruptURL) }

        let corrupt = try runSounding(arguments: [
            "database", "checkpoint", "--db", corruptURL.path, "--json",
        ])
        XCTAssertNotEqual(corrupt.exitCode, 0, corrupt.diagnosticSummary)
        XCTAssertEqual(corrupt.stdoutLineCount, 0, corrupt.diagnosticSummary)
        let payload = try decodeJSON(DatabasePayload.self, from: corrupt.stderr, context: corrupt.diagnosticSummary)
        XCTAssertEqual(payload.command, "checkpoint", corrupt.diagnosticSummary)
        XCTAssertEqual(payload.ok, false, corrupt.diagnosticSummary)
        XCTAssertEqual(payload.health.failure?.phase, "open", corrupt.diagnosticSummary)
        XCTAssertEqual(payload.health.failure?.guidance.contains("restore from a known-good copy"), true, corrupt.diagnosticSummary)
        let corruptStderr = String(data: corrupt.stderr, encoding: .utf8) ?? ""
        XCTAssertFalse(corruptStderr.contains("SQLite error"), corrupt.diagnosticSummary)
        XCTAssertFalse(corruptStderr.contains("GRDB"), corrupt.diagnosticSummary)
        assertDatabaseOutputSanitized(corruptStderr, dbURL: corruptURL)
    }

    private struct DatabasePayload: Decodable {
        var checkDepth: String
        var checkpoint: Checkpoint?
        var command: String
        var health: Health
        var mode: String?
        var ok: Bool
    }

    private struct Health: Decodable {
        var status: String
        var journalMode: String
        var files: Files
        var quickCheck: CheckSummary
        var foreignKeyCheck: CheckSummary
        var integrityCheck: CheckSummary?
        var failure: Failure?
    }

    private struct Files: Decodable {
        var databaseBytes: Int64
        var walBytes: Int64?
        var shmBytes: Int64?
    }

    private struct CheckSummary: Decodable {
        var status: String
    }

    private struct Checkpoint: Decodable {
        var status: String
        var busyFrameCount: Int
        var logFrameCount: Int
        var checkpointedFrameCount: Int
    }

    private struct Failure: Decodable {
        var phase: String
        var guidance: String
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
            XCTFail(
                "Missing compiled sounding executable at \(executable.path). Run `swift build --product sounding` before `swift test --filter DatabaseCommandSmokeTests`.",
                file: file,
                line: line
            )
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
            !path.isEmpty
        else {
            XCTFail(
                "Could not resolve Swift build bin path; exit=\(process.terminationStatus), stderr=\(Self.sanitizedSnippet(from: stderr))",
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
                "Failed to decode CLI JSON as \(type): \(error). \(context); payload=\(Self.sanitizedSnippet(from: data))",
                file: file,
                line: line
            )
            throw CLIError.invalidJSON
        }
    }

    private func temporaryDatabaseURL(secretComponent: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-database-\(secretComponent)-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func removeDatabaseFiles(_ url: URL) {
        for path in [url.path, url.path + "-wal", url.path + "-shm", url.appendingPathExtension("wal").path, url.appendingPathExtension("shm").path] {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
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
            "exit=\(exitCode), args=\(Self.sanitizedArguments(arguments)), stdoutLines=\(stdoutLineCount), stderr=\(DatabaseCommandSmokeTests.sanitizedSnippet(from: stderr))"
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
                } else {
                    sanitized.append(argument)
                }
            }
            return sanitized
        }
    }

    private static func sanitizedSnippet(from data: Data, maxLength: Int = 300) -> String {
        let text = String(data: data, encoding: .utf8) ?? "<non-utf8 data>"
        var sanitized = text
            .replacingOccurrences(
                of: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s]+"#,
                with: "<redacted-url>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)(token|secret|password|key)=([^\s&]+)"#,
                with: "$1=<redacted>",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\?.*"#, with: "?<redacted>", options: .regularExpression)
        if sanitized.count > maxLength {
            sanitized = String(sanitized.prefix(maxLength)) + "…"
        }
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func assertDatabaseOutputSanitized(
        _ text: String,
        dbURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for forbidden in [
            dbURL.path,
            dbURL.deletingLastPathComponent().path,
            "synthetic-secret",
            "token=",
            "#frag",
            "user:pass",
            "SQLite error",
            "GRDB",
        ] {
            XCTAssertFalse(
                text.contains(forbidden),
                "Expected diagnostic to redact forbidden literal '\(forbidden)', got: \(text)",
                file: file,
                line: line
            )
        }
    }
}
