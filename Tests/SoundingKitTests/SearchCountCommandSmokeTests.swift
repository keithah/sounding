import Foundation
import XCTest

@testable import SoundingKit

final class SearchCountCommandSmokeTests: XCTestCase {
    func testHelpAdvertisesSearchAndCountOptions() throws {
        let search = try runSounding(arguments: ["search", "--help"])
        XCTAssertEqual(search.exitCode, 0, search.diagnosticSummary)
        let searchHelp = String(data: search.stdout, encoding: .utf8) ?? ""
        for flag in ["--db", "--json", "--limit", "--context"] {
            XCTAssertTrue(
                searchHelp.contains(flag),
                "Expected search help to advertise \(flag). \(search.diagnosticSummary)")
        }

        let count = try runSounding(arguments: ["count", "--help"])
        XCTAssertEqual(count.exitCode, 0, count.diagnosticSummary)
        let countHelp = String(data: count.stdout, encoding: .utf8) ?? ""
        for flag in ["--db", "--json"] {
            XCTAssertTrue(
                countHelp.contains(flag),
                "Expected count help to advertise \(flag). \(count.diagnosticSummary)")
        }
    }

    func testSearchHumanOutputIncludesIdentitySpeakerTimeTextAndContext() throws {
        let fixture = try makeFixture()

        let result = try runSounding(arguments: [
            "search", "alpha beta",
            "--db", fixture.databaseURL.path,
            "--limit", "10",
            "--context", "1",
        ])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(
            stdout.contains(
                "stream=\(fixture.hlsStreamID)(hls source=https://example.test/live.m3u8)"),
            result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("run=\(fixture.hlsRunID)"), result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("chunk=\(fixture.hlsChunkID)"), result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("segment="), result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("time=00:01.000-00:02.000"), result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("speaker=host"), result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("text: Alpha beta alpha beta."), result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("context:"), result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("[before]"), result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("[match]"), result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("[after]"), result.diagnosticSummary)
    }

    func testSearchContextZeroOmitsContextBlock() throws {
        let fixture = try makeFixture()

        let result = try runSounding(arguments: [
            "search", "alpha beta",
            "--db", fixture.databaseURL.path,
            "--limit", "1",
            "--context", "0",
        ])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(stdout.contains("Match 1:"), result.diagnosticSummary)
        XCTAssertFalse(stdout.contains("context:"), result.diagnosticSummary)
    }

    func testCountHumanOutputIncludesStreamRunSpeakerAggregates() throws {
        let fixture = try makeFixture()

        let result = try runSounding(arguments: [
            "count", "alpha beta",
            "--db", fixture.databaseURL.path,
        ])

        XCTAssertEqual(result.exitCode, 0, result.diagnosticSummary)
        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(
            stdout.contains(
                "stream=\(fixture.hlsStreamID)(hls source=https://example.test/live.m3u8)"),
            result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("run=\(fixture.hlsRunID)"), result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("speaker=host"), result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("occurrences=2"), result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("matching_segments=1"), result.diagnosticSummary)
        XCTAssertTrue(
            stdout.contains("stream=\(fixture.icyStreamID)(icy source=https://example.test/radio)"),
            result.diagnosticSummary)
        XCTAssertTrue(stdout.contains("speaker=caller"), result.diagnosticSummary)
    }

    func testSearchAndCountJSONEmitDecodableStablePayloadsWithoutHumanPrefixes() throws {
        let fixture = try makeFixture()

        let search = try runSounding(arguments: [
            "search", "alpha beta",
            "--db", fixture.databaseURL.path,
            "--limit", "2",
            "--context", "1",
            "--json",
        ])
        XCTAssertEqual(search.exitCode, 0, search.diagnosticSummary)
        let searchObject = try parseJSONObject(search.stdout, context: search.diagnosticSummary)
        let searchResults = try XCTUnwrap(
            searchObject["results"] as? [[String: Any]], search.diagnosticSummary)
        XCTAssertEqual(searchResults.count, 2, search.diagnosticSummary)
        let firstIdentity = try XCTUnwrap(
            searchResults.first?["identity"] as? [String: Any], search.diagnosticSummary)
        XCTAssertNotNil(firstIdentity["streamID"], search.diagnosticSummary)
        XCTAssertNotNil(firstIdentity["runID"], search.diagnosticSummary)
        XCTAssertNotNil(firstIdentity["chunkID"], search.diagnosticSummary)
        XCTAssertNotNil(firstIdentity["segmentID"], search.diagnosticSummary)
        XCTAssertNotNil(firstIdentity["speakerLabel"], search.diagnosticSummary)
        XCTAssertNotNil(searchResults.first?["context"], search.diagnosticSummary)
        let searchText = String(data: search.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(
            searchText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
            search.diagnosticSummary)
        XCTAssertFalse(searchText.contains("Match 1:"), search.diagnosticSummary)

        let count = try runSounding(arguments: [
            "count", "alpha beta",
            "--db", fixture.databaseURL.path,
            "--json",
        ])
        XCTAssertEqual(count.exitCode, 0, count.diagnosticSummary)
        let countObject = try parseJSONObject(count.stdout, context: count.diagnosticSummary)
        let countResults = try XCTUnwrap(
            countObject["results"] as? [[String: Any]], count.diagnosticSummary)
        XCTAssertEqual(countResults.count, 2, count.diagnosticSummary)
        XCTAssertNotNil(countResults.first?["streamID"], count.diagnosticSummary)
        XCTAssertNotNil(countResults.first?["runID"], count.diagnosticSummary)
        XCTAssertNotNil(countResults.first?["speakerLabel"], count.diagnosticSummary)
        XCTAssertNotNil(countResults.first?["occurrenceCount"], count.diagnosticSummary)
        XCTAssertNotNil(countResults.first?["matchingSegmentCount"], count.diagnosticSummary)
        let countText = String(data: count.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(
            countText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
            count.diagnosticSummary)
        XCTAssertFalse(countText.contains("occurrences="), count.diagnosticSummary)
    }

    func testValidationRejectsMalformedInputsBeforeOpeningDatabase() throws {
        for arguments in [
            [
                "search", "   \t", "--db",
                temporaryDatabaseURL(secretComponent: "empty-phrase-token=synthetic-secret").path,
            ],
            [
                "search", "alpha", "--db",
                temporaryDatabaseURL(secretComponent: "bad-limit-token=synthetic-secret").path,
                "--limit", "0",
            ],
            [
                "search", "alpha", "--db",
                temporaryDatabaseURL(secretComponent: "bad-context-token=synthetic-secret").path,
                "--context", "-1",
            ],
            [
                "count", "   \t", "--db",
                temporaryDatabaseURL(secretComponent: "count-empty-token=synthetic-secret").path,
            ],
        ] {
            let dbIndex =
                try XCTUnwrap(arguments.firstIndex(of: "--db"), "Expected --db argument") + 1
            let dbPath = arguments[dbIndex]
            defer { removeDatabaseFiles(URL(fileURLWithPath: dbPath)) }

            let result = try runSounding(arguments: arguments)
            XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
            XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath), result.diagnosticSummary)
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            XCTAssertTrue(stderr.contains("configuration failed"), result.diagnosticSummary)
            assertSanitized(stderr, forbiddenLiteral: dbPath)
            assertSanitized(stderr, forbiddenLiteral: "synthetic-secret")
        }
    }

    func testUnopenableDatabasePathIsRedacted() throws {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sounding-search-db-user:pass@example.test?token=synthetic-secret#frag",
                isDirectory: true)
        let dbURL = missingDirectory.appendingPathComponent("search.sqlite")
        defer { try? FileManager.default.removeItem(at: missingDirectory) }

        let result = try runSounding(arguments: [
            "search", "alpha beta",
            "--db", dbURL.path,
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("Search database failed"), result.diagnosticSummary)
        XCTAssertTrue(stderr.contains("redacted database path"), result.diagnosticSummary)
        assertSanitized(stderr, forbiddenLiteral: dbURL.path)
        assertSanitized(stderr, forbiddenLiteral: missingDirectory.path)
        assertSanitized(stderr, forbiddenLiteral: "synthetic-secret")
        assertSanitized(stderr, forbiddenLiteral: "user:pass")
    }

    private struct Fixture {
        var temporary: TemporarySoundingDatabase
        var databaseURL: URL
        var hlsStreamID: Int64
        var hlsRunID: Int64
        var hlsChunkID: Int64
        var icyStreamID: Int64
        var icyRunID: Int64
    }

    private func makeFixture() throws -> Fixture {
        let temporary = try TemporarySoundingDatabase()
        let writer = IngestPersistence(database: temporary.database)

        let hlsStreamID = try writer.createStream(
            streamType: "hls",
            source: "https://example.test/live.m3u8",
            createdAt: "2026-04-30T12:00:00Z"
        )
        let hlsRunID = try writer.createRun(
            streamID: hlsStreamID,
            startedAt: "2026-04-30T12:00:01Z",
            status: .running
        )
        let hlsChunkID = try writer.createChunk(
            runID: hlsRunID,
            sequence: 0,
            segmentURI: "segment-000.ts",
            startedAt: "2026-04-30T12:00:02Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: hlsRunID,
                chunkID: hlsChunkID,
                segments: [
                    segment(0, "host", 0.0, 1.0, "cold open starts now"),
                    segment(
                        1, "host", 1.0, 2.0, "Alpha beta alpha beta.",
                        words: ["Alpha", "beta", "alpha", "beta"]),
                    segment(2, "guest", 2.0, 3.0, "middle context only"),
                ],
                speakerTurns: [
                    SpeakerTurnDraft(
                        speakerLabel: "host", startSeconds: 0, endSeconds: 2, confidence: 0.91),
                    SpeakerTurnDraft(
                        speakerLabel: "guest", startSeconds: 2, endSeconds: 3, confidence: 0.84),
                ],
                createdAt: "2026-04-30T12:00:03Z"
            )
        )

        let icyStreamID = try writer.createStream(
            streamType: "icy",
            source: "https://example.test/radio",
            createdAt: "2026-04-30T13:00:00Z"
        )
        let icyRunID = try writer.createRun(
            streamID: icyStreamID,
            startedAt: "2026-04-30T13:00:01Z",
            status: .running
        )
        let icyChunkID = try writer.createChunk(
            runID: icyRunID,
            sequence: 0,
            segmentURI: "icy-000",
            startedAt: "2026-04-30T13:00:02Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: icyRunID,
                chunkID: icyChunkID,
                segments: [
                    segment(0, "dj", 0.0, 1.0, "station context"),
                    segment(
                        1, "caller", 1.0, 2.0, "callers say ALPHA BETA",
                        words: ["callers", "say", "ALPHA", "BETA"]),
                ],
                speakerTurns: [
                    SpeakerTurnDraft(
                        speakerLabel: "dj", startSeconds: 0, endSeconds: 1, confidence: 0.75),
                    SpeakerTurnDraft(
                        speakerLabel: "caller", startSeconds: 1, endSeconds: 2, confidence: 0.87),
                ],
                createdAt: "2026-04-30T13:00:03Z"
            )
        )

        return Fixture(
            temporary: temporary,
            databaseURL: temporary.fileURL,
            hlsStreamID: hlsStreamID,
            hlsRunID: hlsRunID,
            hlsChunkID: hlsChunkID,
            icyStreamID: icyStreamID,
            icyRunID: icyRunID
        )
    }

    private func segment(
        _ sequence: Int,
        _ speakerLabel: String,
        _ startSeconds: Double,
        _ endSeconds: Double,
        _ text: String,
        words: [String]? = nil
    ) -> TranscriptSegmentDraft {
        let wordTexts = words ?? text.split(separator: " ").map(String.init)
        let duration = max((endSeconds - startSeconds) / Double(max(wordTexts.count, 1)), 0.1)
        return TranscriptSegmentDraft(
            sequence: sequence,
            speakerLabel: speakerLabel,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            text: text,
            confidence: 0.9,
            words: wordTexts.enumerated().map { index, word in
                TranscriptWordDraft(
                    sequence: index,
                    speakerLabel: speakerLabel,
                    startSeconds: startSeconds + (Double(index) * duration),
                    endSeconds: startSeconds + (Double(index + 1) * duration),
                    text: word,
                    confidence: 0.88
                )
            }
        )
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
                "Missing compiled sounding executable at \(executable.path). Run `swift build --product sounding` before `swift test --filter SearchCountCommandSmokeTests`.",
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

    private func parseJSONObject(
        _ data: Data, context: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any] else {
                XCTFail("Expected top-level JSON object. \(context)", file: file, line: line)
                throw CLIError.invalidJSON
            }
            return dictionary
        } catch {
            XCTFail("Failed to parse CLI JSON: \(error). \(context)", file: file, line: line)
            throw error
        }
    }

    private func temporaryDatabaseURL(secretComponent: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-search-count-\(secretComponent)-\(UUID().uuidString)")
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
            "exit=\(exitCode), args=\(Self.sanitizedArguments(arguments)), stdoutLines=\(stdoutLineCount), stderr=\(SearchCountCommandSmokeTests.sanitizedSnippet(from: stderr))"
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
