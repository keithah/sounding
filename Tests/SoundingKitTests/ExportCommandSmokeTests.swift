import Foundation
import XCTest

@testable import SoundingKit

final class ExportCommandSmokeTests: XCTestCase {
    func testHelpAdvertisesExportCommandsAndOptions() throws {
        let root = try runSounding(arguments: ["--help"])
        XCTAssertEqual(root.exitCode, 0, root.diagnosticSummary)
        let rootHelp = String(data: root.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(rootHelp.contains("export"), root.diagnosticSummary)

        let export = try runSounding(arguments: ["export", "--help"])
        XCTAssertEqual(export.exitCode, 0, export.diagnosticSummary)
        let exportHelp = String(data: export.stdout, encoding: .utf8) ?? ""
        for command in ["transcripts", "markers", "report"] {
            XCTAssertTrue(exportHelp.contains(command), export.diagnosticSummary)
        }

        for command in ["transcripts", "markers", "report"] {
            let help = try runSounding(arguments: ["export", command, "--help"])
            XCTAssertEqual(help.exitCode, 0, help.diagnosticSummary)
            let helpText = String(data: help.stdout, encoding: .utf8) ?? ""
            for flag in ["--db", "--format", "--output", "--stream", "--start-seconds", "--end-seconds"] {
                XCTAssertTrue(
                    helpText.contains(flag),
                    "Expected export \(command) help to advertise \(flag). \(help.diagnosticSummary)"
                )
            }
        }

        let reportHelp = try runSounding(arguments: ["export", "report", "--help"])
        XCTAssertEqual(reportHelp.exitCode, 0, reportHelp.diagnosticSummary)
        XCTAssertTrue(
            (String(data: reportHelp.stdout, encoding: .utf8) ?? "").contains("--kind"),
            reportHelp.diagnosticSummary)
    }

    func testTranscriptMarkerAndReportExportsSupportTextJSONAndOutputFiles() throws {
        let fixture = try makeFixture()

        let transcriptText = try runSounding(arguments: [
            "export", "transcripts",
            "--db", fixture.databaseURL.path,
            "--format", "text",
            "--stream", fixture.streamName,
            "--start-seconds", "0",
            "--end-seconds", "30",
        ])
        XCTAssertEqual(transcriptText.exitCode, 0, transcriptText.diagnosticSummary)
        let transcriptHuman = String(data: transcriptText.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(transcriptHuman.contains("Segment 1:"), transcriptText.diagnosticSummary)
        XCTAssertTrue(transcriptHuman.contains("text: Opening alpha words"), transcriptText.diagnosticSummary)
        XCTAssertTrue(transcriptHuman.contains("words:"), transcriptText.diagnosticSummary)
        assertExportSanitized(transcriptHuman, fixture: fixture)

        let transcriptJSON = try runSounding(arguments: [
            "export", "transcripts",
            "--db", fixture.databaseURL.path,
            "--format", "json",
            "--stream", String(fixture.streamID),
        ])
        XCTAssertEqual(transcriptJSON.exitCode, 0, transcriptJSON.diagnosticSummary)
        let transcriptPayload = try decodeJSON(
            TranscriptPayload.self, from: transcriptJSON.stdout, context: transcriptJSON.diagnosticSummary)
        XCTAssertEqual(transcriptPayload.segments.count, 2, transcriptJSON.diagnosticSummary)
        XCTAssertEqual(transcriptPayload.segments.first?.words.map(\.text), ["Opening", "alpha", "words"])
        let transcriptJSONString = String(data: transcriptJSON.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(transcriptJSONString.hasPrefix("{\"segments\":"), transcriptJSON.diagnosticSummary)
        assertExportSanitized(transcriptJSONString, fixture: fixture)

        let markerJSON = try runSounding(arguments: [
            "export", "markers",
            "--db", fixture.databaseURL.path,
            "--format", "json",
            "--stream", "hls",
        ])
        XCTAssertEqual(markerJSON.exitCode, 0, markerJSON.diagnosticSummary)
        let markerPayload = try decodeJSON(
            AdsPayload.self, from: markerJSON.stdout, context: markerJSON.diagnosticSummary)
        XCTAssertEqual(markerPayload.events.count, 2, markerJSON.diagnosticSummary)
        XCTAssertEqual(markerPayload.summary.adStart, 1, markerJSON.diagnosticSummary)
        XCTAssertEqual(markerPayload.summary.adEnd, 1, markerJSON.diagnosticSummary)
        assertExportSanitized(String(data: markerJSON.stdout, encoding: .utf8) ?? "", fixture: fixture)

        let markersOutputURL = temporaryOutputURL(secretComponent: "markers-token=synthetic-secret")
        defer { try? FileManager.default.removeItem(at: markersOutputURL) }
        let markerStdout = try runSounding(arguments: [
            "export", "markers",
            "--db", fixture.databaseURL.path,
            "--format", "text",
        ])
        XCTAssertEqual(markerStdout.exitCode, 0, markerStdout.diagnosticSummary)
        let markerFile = try runSounding(arguments: [
            "export", "markers",
            "--db", fixture.databaseURL.path,
            "--format", "text",
            "--output", markersOutputURL.path,
        ])
        XCTAssertEqual(markerFile.exitCode, 0, markerFile.diagnosticSummary)
        XCTAssertEqual(markerFile.stdout.count, 0, markerFile.diagnosticSummary)
        XCTAssertEqual(try Data(contentsOf: markersOutputURL), markerStdout.stdout)
        assertExportSanitized(String(data: markerStdout.stdout, encoding: .utf8) ?? "", fixture: fixture)

        let reportExport = try runSounding(arguments: [
            "export", "report",
            "--db", fixture.databaseURL.path,
            "--kind", "plays",
            "--format", "json",
        ])
        let reportCommand = try runSounding(arguments: [
            "report", "plays",
            "--db", fixture.databaseURL.path,
            "--json",
        ])
        XCTAssertEqual(reportExport.exitCode, 0, reportExport.diagnosticSummary)
        XCTAssertEqual(reportCommand.exitCode, 0, reportCommand.diagnosticSummary)
        XCTAssertEqual(reportExport.stdout, reportCommand.stdout)
        let playsPayload = try decodeJSON(
            PlaysPayload.self, from: reportExport.stdout, context: reportExport.diagnosticSummary)
        XCTAssertEqual(playsPayload.results.count, 1, reportExport.diagnosticSummary)
        XCTAssertEqual(playsPayload.results.first?.song.displayLabel, "Export Artist — Export Song")
        assertExportSanitized(String(data: reportExport.stdout, encoding: .utf8) ?? "", fixture: fixture)

        let repeats = try runSounding(arguments: [
            "export", "report",
            "--db", fixture.databaseURL.path,
            "--kind", "repeats",
            "--format", "json",
        ])
        XCTAssertEqual(repeats.exitCode, 0, repeats.diagnosticSummary)
        let repeatsPayload = try decodeJSON(
            RepeatsPayload.self, from: repeats.stdout, context: repeats.diagnosticSummary)
        XCTAssertEqual(repeatsPayload.results.count, 0, repeats.diagnosticSummary)

        let adsReport = try runSounding(arguments: [
            "export", "report",
            "--db", fixture.databaseURL.path,
            "--kind", "ads",
            "--format", "json",
        ])
        XCTAssertEqual(adsReport.exitCode, 0, adsReport.diagnosticSummary)
        let adsReportPayload = try decodeJSON(
            AdsPayload.self, from: adsReport.stdout, context: adsReport.diagnosticSummary)
        XCTAssertEqual(adsReportPayload.events.count, 2, adsReport.diagnosticSummary)
    }

    func testValidationRejectsMalformedInputsBeforeOpeningDatabase() throws {
        for command in ["transcripts", "markers", "report"] {
            let invalidCases: [[String]] = [
                [
                    "export", command,
                    "--db", temporaryDatabaseURL(secretComponent: "bad-format-token=synthetic-secret").path,
                    "--format", "yaml",
                ],
                [
                    "export", command,
                    "--db", temporaryDatabaseURL(secretComponent: "blank-stream-token=synthetic-secret").path,
                    "--stream", "   \t",
                ],
                [
                    "export", command,
                    "--db", temporaryDatabaseURL(secretComponent: "bad-time-token=synthetic-secret").path,
                    "--start-seconds", "30",
                    "--end-seconds", "20",
                ],
                [
                    "export", command,
                    "--db", temporaryDatabaseURL(secretComponent: "nan-time-token=synthetic-secret").path,
                    "--start-seconds", "nan",
                ],
            ]

            for arguments in invalidCases {
                let dbIndex = try XCTUnwrap(arguments.firstIndex(of: "--db")) + 1
                let dbPath = arguments[dbIndex]
                defer { removeDatabaseFiles(URL(fileURLWithPath: dbPath)) }

                let result = try runSounding(arguments: arguments)
                XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
                XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
                XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath), result.diagnosticSummary)
                let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
                XCTAssertTrue(stderr.contains("Export configuration failed"), result.diagnosticSummary)
                assertSanitized(stderr, forbiddenLiteral: dbPath)
                assertSanitized(stderr, forbiddenLiteral: "synthetic-secret")
            }
        }

        let badKindDB = temporaryDatabaseURL(secretComponent: "bad-kind-token=synthetic-secret")
        defer { removeDatabaseFiles(badKindDB) }
        let badKind = try runSounding(arguments: [
            "export", "report",
            "--db", badKindDB.path,
            "--kind", "songs",
        ])
        XCTAssertNotEqual(badKind.exitCode, 0, badKind.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: badKindDB.path), badKind.diagnosticSummary)
        let badKindStderr = String(data: badKind.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(badKindStderr.contains("Export configuration failed"), badKind.diagnosticSummary)
        assertSanitized(badKindStderr, forbiddenLiteral: badKindDB.path)
    }

    func testDatabaseQueryAndOutputFailuresAreRedacted() throws {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sounding-export-db-user:pass@example.test?token=synthetic-secret#frag",
                isDirectory: true)
        let dbURL = missingDirectory.appendingPathComponent("export.sqlite")
        defer { try? FileManager.default.removeItem(at: missingDirectory) }

        let unopened = try runSounding(arguments: [
            "export", "transcripts",
            "--db", dbURL.path,
            "--stream", "https://user:pass@example.test/live.m3u8?token=synthetic-secret#frag",
        ])
        XCTAssertNotEqual(unopened.exitCode, 0, unopened.diagnosticSummary)
        XCTAssertEqual(unopened.stdoutLineCount, 0, unopened.diagnosticSummary)
        let unopenedStderr = String(data: unopened.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(unopenedStderr.contains("Export database failed"), unopened.diagnosticSummary)
        XCTAssertTrue(unopenedStderr.contains("redacted database path"), unopened.diagnosticSummary)
        assertSanitized(unopenedStderr, forbiddenLiteral: dbURL.path)
        assertSanitized(unopenedStderr, forbiddenLiteral: missingDirectory.path)
        assertSanitized(unopenedStderr, forbiddenLiteral: "synthetic-secret")
        assertSanitized(unopenedStderr, forbiddenLiteral: "user:pass")

        let fixture = try makeFixture()
        try corruptTranscriptTable(in: fixture.temporary.database)
        let queryFailure = try runSounding(arguments: [
            "export", "transcripts",
            "--db", fixture.databaseURL.path,
            "--format", "json",
        ])
        XCTAssertNotEqual(queryFailure.exitCode, 0, queryFailure.diagnosticSummary)
        XCTAssertEqual(queryFailure.stdoutLineCount, 0, queryFailure.diagnosticSummary)
        let queryStderr = String(data: queryFailure.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(queryStderr.contains("Export query failed"), queryFailure.diagnosticSummary)
        assertSanitized(queryStderr, forbiddenLiteral: fixture.databaseURL.path)
        assertSanitized(queryStderr, forbiddenLiteral: "fixture-secret")
        assertSanitized(queryStderr, forbiddenLiteral: "synthetic-secret")

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sounding-export-output-user:pass@example.test?token=synthetic-secret#frag",
                isDirectory: true)
            .appendingPathComponent("out.json")
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        let outputFailure = try runSounding(arguments: [
            "export", "markers",
            "--db", fixture.databaseURL.path,
            "--format", "json",
            "--output", outputURL.path,
        ])
        XCTAssertNotEqual(outputFailure.exitCode, 0, outputFailure.diagnosticSummary)
        XCTAssertEqual(outputFailure.stdoutLineCount, 0, outputFailure.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path), outputFailure.diagnosticSummary)
        let outputStderr = String(data: outputFailure.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(outputStderr.contains("Export output failed"), outputFailure.diagnosticSummary)
        XCTAssertTrue(outputStderr.contains("[redacted-output-error]"), outputFailure.diagnosticSummary)
        assertSanitized(outputStderr, forbiddenLiteral: outputURL.path)
        assertSanitized(outputStderr, forbiddenLiteral: outputURL.deletingLastPathComponent().path)
        assertSanitized(outputStderr, forbiddenLiteral: "synthetic-secret")
        assertSanitized(outputStderr, forbiddenLiteral: "user:pass")
    }

    private struct TranscriptPayload: Decodable {
        var segments: [TranscriptSegment]
    }

    private struct TranscriptSegment: Decodable {
        var text: String
        var words: [TranscriptWord]
    }

    private struct TranscriptWord: Decodable {
        var text: String
    }

    private struct AdsPayload: Decodable {
        var events: [AdEvent]
        var summary: AdSummary
    }

    private struct AdEvent: Decodable {
        var classification: String
    }

    private struct AdSummary: Decodable {
        var unknown: Int
        var adStart: Int
        var adEnd: Int
    }

    private struct PlaysPayload: Decodable {
        var results: [Play]
    }

    private struct RepeatsPayload: Decodable {
        var results: [Repeat]
    }

    private struct Repeat: Decodable {
        var repeatCount: Int
    }

    private struct Play: Decodable {
        var song: Song
    }

    private struct Song: Decodable {
        var displayLabel: String
    }

    private struct Fixture {
        var temporary: TemporarySoundingDatabase
        var databaseURL: URL
        var streamID: Int64
        var streamName: String
    }

    private func makeFixture() throws -> Fixture {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let streamName = "Managed Export"
        let stream = try registry.add(
            name: streamName,
            streamType: "hls",
            source: "https://example.test/export.m3u8?token=fixture-secret#frag",
            createdAt: "2026-05-01T17:00:00Z"
        )

        let writer = IngestPersistence(database: temporary.database)
        let runID = try writer.createRun(
            streamID: stream.id,
            startedAt: "2026-05-01T17:00:01Z",
            status: .running
        )
        let firstChunkID = try writer.createChunk(
            runID: runID,
            sequence: 0,
            segmentURI: "/private/export-000.ts?password=fixture-secret",
            startedAt: "2026-05-01T17:00:02Z",
            endedAt: "2026-05-01T17:00:12Z"
        )
        let secondChunkID = try writer.createChunk(
            runID: runID,
            sequence: 1,
            segmentURI: "/private/export-001.ts?password=fixture-secret",
            startedAt: "2026-05-01T17:00:12Z",
            endedAt: "2026-05-01T17:00:22Z"
        )

        let song = UnresolvedSongDraft(
            songKey: "local:export-artist:export-song",
            title: "Export Song",
            artist: "Export Artist",
            album: "Smoke Tests",
            isrc: "US-S05-26-00001",
            displayName: "Export Artist — Export Song"
        )

        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: firstChunkID,
                segments: [segment(0, "host", 0, 10, "Opening alpha words")],
                adMarkers: [
                    AdMarker(
                        type: "EXT-X-CUE-OUT",
                        classification: .adStart,
                        source: "https://ads.example.test/start?token=fixture-secret",
                        pts: 5,
                        segment: "/private/ad-start.ts?password=fixture-secret",
                        timestamp: "2026-05-01T17:00:05Z")
                ],
                songPlays: [
                    SongPlayDraft(
                        song: song,
                        startSeconds: 0,
                        endSeconds: 20,
                        confidence: 0.95,
                        source: "https://fingerprints.example.test/match?token=fixture-secret")
                ],
                createdAt: "2026-05-01T17:00:03Z"
            )
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: secondChunkID,
                segments: [segment(1, "guest", 10, 20, "Closing beta words")],
                adMarkers: [
                    AdMarker(
                        type: "EXT-X-CUE-IN",
                        classification: .adEnd,
                        source: "https://ads.example.test/end?token=fixture-secret",
                        pts: 15,
                        segment: "/private/ad-end.ts?password=fixture-secret",
                        timestamp: "2026-05-01T17:00:15Z")
                ],
                createdAt: "2026-05-01T17:00:13Z"
            )
        )

        return Fixture(
            temporary: temporary,
            databaseURL: temporary.fileURL,
            streamID: stream.id,
            streamName: streamName
        )
    }

    private func segment(
        _ sequence: Int,
        _ speakerLabel: String,
        _ startSeconds: Double,
        _ endSeconds: Double,
        _ text: String
    ) -> TranscriptSegmentDraft {
        let words = text.split(separator: " ").map(String.init)
        let duration = max((endSeconds - startSeconds) / Double(max(words.count, 1)), 0.1)
        return TranscriptSegmentDraft(
            sequence: sequence,
            speakerLabel: speakerLabel,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            text: text,
            confidence: 0.9,
            words: words.enumerated().map { index, word in
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

    private func corruptTranscriptTable(in database: SoundingDatabase) throws {
        try database.write { db in
            try db.execute(sql: "DROP TABLE transcript_segments")
        }
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
                "Missing compiled sounding executable at \(executable.path). Run `swift build --product sounding` before `swift test --filter ExportCommandSmokeTests`.",
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
            .appendingPathComponent("sounding-export-\(secretComponent)-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func temporaryOutputURL(secretComponent: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-export-output-\(secretComponent)-\(UUID().uuidString)")
            .appendingPathExtension("txt")
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
            "exit=\(exitCode), args=\(Self.sanitizedArguments(arguments)), stdoutLines=\(stdoutLineCount), stderr=\(ExportCommandSmokeTests.sanitizedSnippet(from: stderr))"
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
                if argument == "--db" || argument == "--output" {
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
        let text = String(data: data, encoding: .utf8) ?? "<non-utf8>"
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

    private func assertExportSanitized(
        _ text: String,
        fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for forbidden in [
            fixture.databaseURL.path,
            "fixture-secret",
            "synthetic-secret",
            "token=",
            "password=",
            "#frag",
            "/private/",
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
            "Expected output to redact forbidden literal '\(forbiddenLiteral)', got: \(text)",
            file: file,
            line: line
        )
    }
}
