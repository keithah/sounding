import Foundation
import GRDB
import XCTest

final class StreamsCommandSmokeTests: XCTestCase {
    func testHelpAdvertisesStreamsCommandsAndOptions() throws {
        let root = try runSounding(arguments: ["--help"])
        XCTAssertEqual(root.exitCode, 0, root.diagnosticSummary)
        let rootHelp = String(data: root.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(rootHelp.contains("streams"), root.diagnosticSummary)

        let streams = try runSounding(arguments: ["streams", "--help"])
        XCTAssertEqual(streams.exitCode, 0, streams.diagnosticSummary)
        let streamsHelp = String(data: streams.stdout, encoding: .utf8) ?? ""
        for command in ["add", "list", "pause", "resume", "remove"] {
            XCTAssertTrue(streamsHelp.contains(command), streams.diagnosticSummary)
        }

        let add = try runSounding(arguments: ["streams", "add", "--help"])
        XCTAssertEqual(add.exitCode, 0, add.diagnosticSummary)
        let addHelp = String(data: add.stdout, encoding: .utf8) ?? ""
        for text in ["--db", "--stream-type"] {
            XCTAssertTrue(addHelp.contains(text), add.diagnosticSummary)
        }

        let list = try runSounding(arguments: ["streams", "list", "--help"])
        XCTAssertEqual(list.exitCode, 0, list.diagnosticSummary)
        let listHelp = String(data: list.stdout, encoding: .utf8) ?? ""
        for text in ["--db", "--json", "--include-removed"] {
            XCTAssertTrue(listHelp.contains(text), list.diagnosticSummary)
        }

        for command in ["pause", "resume", "remove"] {
            let help = try runSounding(arguments: ["streams", command, "--help"])
            XCTAssertEqual(help.exitCode, 0, help.diagnosticSummary)
            let helpText = String(data: help.stdout, encoding: .utf8) ?? ""
            XCTAssertTrue(helpText.contains("--db"), help.diagnosticSummary)
        }
    }

    func testLifecycleHumanAndJSONOutputsAreRedactedAndDeterministic() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "lifecycle-token=synthetic-secret")
        defer { removeDatabaseFiles(dbURL) }
        let source = "https://user:pass@example.test/private/live.m3u8?token=synthetic-secret#frag"

        let add = try runSounding(arguments: [
            "streams", "add",
            "--db", dbURL.path,
            "Main",
            source,
            "--stream-type", "hls",
        ])
        XCTAssertEqual(add.exitCode, 0, add.diagnosticSummary)
        let addText = String(data: add.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(addText.contains("stream added:"), add.diagnosticSummary)
        XCTAssertTrue(addText.contains("name=Main"), add.diagnosticSummary)
        assertStreamOutputSanitized(addText, dbURL: dbURL)

        let stored = try DatabaseQueue(path: dbURL.path).read { db in
            try Row.fetchOne(db, sql: "SELECT source, source_url FROM streams WHERE id = 1")
        }
        XCTAssertEqual(stored?["source"] as String?, "https://example.test/private/live.m3u8")
        XCTAssertEqual(stored?["source_url"] as String?, source)

        let human = try runSounding(arguments: [
            "streams", "list",
            "--db", dbURL.path,
        ])
        XCTAssertEqual(human.exitCode, 0, human.diagnosticSummary)
        XCTAssertEqual(human.stderr.count, 0, human.diagnosticSummary)
        let humanText = String(data: human.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(
            humanText.contains("id=1 name=Main type=hls status=active"), human.diagnosticSummary)
        XCTAssertTrue(
            humanText.contains("source=https://example.test/private/live.m3u8"),
            human.diagnosticSummary)
        assertStreamOutputSanitized(humanText, dbURL: dbURL)

        let json = try runSounding(arguments: [
            "streams", "list",
            "--db", dbURL.path,
            "--json",
        ])
        XCTAssertEqual(json.exitCode, 0, json.diagnosticSummary)
        XCTAssertEqual(json.stderr.count, 0, json.diagnosticSummary)
        XCTAssertTrue(String(data: json.stdout, encoding: .utf8)?.hasSuffix("\n") == true)
        let payload = try decodeJSON(
            StreamsPayload.self, from: json.stdout, context: json.diagnosticSummary)
        XCTAssertEqual(payload.streams.count, 1, json.diagnosticSummary)
        let stream = try XCTUnwrap(payload.streams.first, json.diagnosticSummary)
        XCTAssertEqual(stream.id, 1, json.diagnosticSummary)
        XCTAssertEqual(stream.name, "Main", json.diagnosticSummary)
        XCTAssertEqual(stream.streamType, "hls", json.diagnosticSummary)
        XCTAssertEqual(stream.status, "active", json.diagnosticSummary)
        XCTAssertEqual(
            stream.source, "https://example.test/private/live.m3u8", json.diagnosticSummary)
        XCTAssertNil(stream.pausedAt, json.diagnosticSummary)
        XCTAssertNil(stream.resumedAt, json.diagnosticSummary)
        XCTAssertNil(stream.removedAt, json.diagnosticSummary)
        assertStreamOutputSanitized(String(data: json.stdout, encoding: .utf8) ?? "", dbURL: dbURL)
    }

    func testPauseResumeRemoveIdempotenceAndIncludeRemovedBehavior() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "idempotent-token=synthetic-secret")
        defer { removeDatabaseFiles(dbURL) }

        let first = try addStream(dbURL: dbURL, name: "Alpha")
        let second = try addStream(dbURL: dbURL, name: "Beta")
        XCTAssertEqual(first.exitCode, 0, first.diagnosticSummary)
        XCTAssertEqual(second.exitCode, 0, second.diagnosticSummary)

        let pause = try runSounding(arguments: ["streams", "pause", "--db", dbURL.path, "1"])
        XCTAssertEqual(pause.exitCode, 0, pause.diagnosticSummary)
        XCTAssertTrue(
            String(data: pause.stdout, encoding: .utf8)?.contains("result=changed") == true)

        let pauseAgain = try runSounding(arguments: ["streams", "pause", "--db", dbURL.path, "1"])
        XCTAssertEqual(pauseAgain.exitCode, 0, pauseAgain.diagnosticSummary)
        XCTAssertTrue(
            String(data: pauseAgain.stdout, encoding: .utf8)?.contains("result=unchanged") == true)

        let resume = try runSounding(arguments: ["streams", "resume", "--db", dbURL.path, "1"])
        XCTAssertEqual(resume.exitCode, 0, resume.diagnosticSummary)
        XCTAssertTrue(
            String(data: resume.stdout, encoding: .utf8)?.contains("result=changed") == true)

        let resumeAgain = try runSounding(arguments: ["streams", "resume", "--db", dbURL.path, "1"])
        XCTAssertEqual(resumeAgain.exitCode, 0, resumeAgain.diagnosticSummary)
        XCTAssertTrue(
            String(data: resumeAgain.stdout, encoding: .utf8)?.contains("result=unchanged") == true)

        let remove = try runSounding(arguments: ["streams", "remove", "--db", dbURL.path, "1"])
        XCTAssertEqual(remove.exitCode, 0, remove.diagnosticSummary)
        XCTAssertTrue(
            String(data: remove.stdout, encoding: .utf8)?.contains("result=changed") == true)

        let removeAgain = try runSounding(arguments: ["streams", "remove", "--db", dbURL.path, "1"])
        XCTAssertEqual(removeAgain.exitCode, 0, removeAgain.diagnosticSummary)
        XCTAssertTrue(
            String(data: removeAgain.stdout, encoding: .utf8)?.contains("result=unchanged") == true)

        let activeOnly = try runSounding(arguments: [
            "streams", "list", "--db", dbURL.path, "--json",
        ])
        XCTAssertEqual(activeOnly.exitCode, 0, activeOnly.diagnosticSummary)
        let activePayload = try decodeJSON(
            StreamsPayload.self, from: activeOnly.stdout, context: activeOnly.diagnosticSummary)
        XCTAssertEqual(activePayload.streams.map(\.name), ["Beta"], activeOnly.diagnosticSummary)

        let includeRemoved = try runSounding(arguments: [
            "streams", "list", "--db", dbURL.path, "--json", "--include-removed",
        ])
        XCTAssertEqual(includeRemoved.exitCode, 0, includeRemoved.diagnosticSummary)
        let includePayload = try decodeJSON(
            StreamsPayload.self, from: includeRemoved.stdout,
            context: includeRemoved.diagnosticSummary)
        XCTAssertEqual(
            includePayload.streams.map(\.name), ["Alpha", "Beta"], includeRemoved.diagnosticSummary)
        XCTAssertEqual(
            includePayload.streams.first?.status, "removed", includeRemoved.diagnosticSummary)
        XCTAssertNotNil(includePayload.streams.first?.removedAt, includeRemoved.diagnosticSummary)
    }

    func testDuplicateMissingRemovedAndInvalidInputsReturnRedactedActionableErrors() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "errors-token=synthetic-secret")
        defer { removeDatabaseFiles(dbURL) }
        let source = "https://user:pass@example.test/live.m3u8?token=synthetic-secret#frag"

        let add = try runSounding(arguments: [
            "streams", "add", "--db", dbURL.path, "Main", source,
        ])
        XCTAssertEqual(add.exitCode, 0, add.diagnosticSummary)

        let duplicate = try runSounding(arguments: [
            "streams", "add", "--db", dbURL.path, "Main", source,
        ])
        XCTAssertNotEqual(duplicate.exitCode, 0, duplicate.diagnosticSummary)
        XCTAssertEqual(duplicate.stdoutLineCount, 0, duplicate.diagnosticSummary)
        let duplicateStderr = String(data: duplicate.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(
            duplicateStderr.contains("duplicate active stream name"), duplicate.diagnosticSummary)
        assertStreamOutputSanitized(duplicateStderr, dbURL: dbURL)

        let missing = try runSounding(arguments: ["streams", "pause", "--db", dbURL.path, "99"])
        XCTAssertNotEqual(missing.exitCode, 0, missing.diagnosticSummary)
        let missingStderr = String(data: missing.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(
            missingStderr.contains("stream reference was not found"), missing.diagnosticSummary)
        assertStreamOutputSanitized(missingStderr, dbURL: dbURL)

        let removed = try runSounding(arguments: ["streams", "remove", "--db", dbURL.path, "1"])
        XCTAssertEqual(removed.exitCode, 0, removed.diagnosticSummary)
        let resumeRemoved = try runSounding(arguments: [
            "streams", "resume", "--db", dbURL.path, "1",
        ])
        XCTAssertNotEqual(resumeRemoved.exitCode, 0, resumeRemoved.diagnosticSummary)
        let resumeRemovedStderr = String(data: resumeRemoved.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(
            resumeRemovedStderr.contains("removed streams cannot be resumed or paused"),
            resumeRemoved.diagnosticSummary)
        assertStreamOutputSanitized(resumeRemovedStderr, dbURL: dbURL)

        let emptyName = try runSounding(arguments: [
            "streams", "add", "--db", dbURL.path, " ", source,
        ])
        XCTAssertNotEqual(emptyName.exitCode, 0, emptyName.diagnosticSummary)
        let emptyNameStderr = String(data: emptyName.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(
            emptyNameStderr.contains("name must not be empty"), emptyName.diagnosticSummary)
        assertStreamOutputSanitized(emptyNameStderr, dbURL: dbURL)

        let badID = try runSounding(arguments: ["streams", "pause", "--db", dbURL.path, "0"])
        XCTAssertNotEqual(badID.exitCode, 0, badID.diagnosticSummary)
        let badIDStderr = String(data: badID.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(
            badIDStderr.contains("stream id must be greater than zero"), badID.diagnosticSummary)
        assertStreamOutputSanitized(badIDStderr, dbURL: dbURL)
    }

    func testUnopenableSecretBearingDatabasePathIsRedacted() throws {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sounding-streams-db-user:pass@example.test?token=synthetic-secret#frag",
                isDirectory: true)
        let dbURL = missingDirectory.appendingPathComponent("streams.sqlite")
        defer { try? FileManager.default.removeItem(at: missingDirectory) }

        let result = try runSounding(arguments: [
            "streams", "list",
            "--db", dbURL.path,
            "--json",
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("Streams database failed"), result.diagnosticSummary)
        XCTAssertTrue(stderr.contains("redacted database path"), result.diagnosticSummary)
        assertStreamOutputSanitized(stderr, dbURL: dbURL)
    }

    private struct StreamsPayload: Decodable {
        var streams: [Stream]
    }

    private struct Stream: Decodable {
        var id: Int64
        var name: String
        var streamType: String
        var status: String
        var source: String
        var pausedAt: String?
        var resumedAt: String?
        var removedAt: String?
    }

    @discardableResult
    private func addStream(dbURL: URL, name: String) throws -> CLIResult {
        try runSounding(arguments: [
            "streams", "add",
            "--db", dbURL.path,
            name,
            "https://example.test/\(name).m3u8?token=synthetic-secret",
            "--stream-type", "hls",
        ])
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
                "Missing compiled sounding executable at \(executable.path). Run `swift build --product sounding` before `swift test --filter StreamsCommandSmokeTests`.",
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
            .appendingPathComponent("sounding-streams-\(secretComponent)-\(UUID().uuidString)")
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
            "exit=\(exitCode), args=\(Self.sanitizedArguments(arguments)), stdoutLines=\(stdoutLineCount), stderr=\(StreamsCommandSmokeTests.sanitizedSnippet(from: stderr))"
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

    private func assertStreamOutputSanitized(
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
        ] {
            assertSanitized(text, forbiddenLiteral: forbidden, file: file, line: line)
        }
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
