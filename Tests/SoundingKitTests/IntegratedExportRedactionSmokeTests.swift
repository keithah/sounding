import Foundation
import XCTest

@testable import SoundingKit

final class IntegratedExportRedactionSmokeTests: XCTestCase {
    func testExecutableExportReportStreamAndRedactionFlow() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "integrated-token=synthetic-secret")
        defer { removeDatabaseFiles(dbURL) }

        let streamName = "Integrated Managed"
        let secretSource = "https://user:pass@example.test/private/integrated.m3u8?token=fixture-secret#frag"
        let add = try runSounding(arguments: [
            "streams", "add",
            "--db", dbURL.path,
            streamName,
            secretSource,
            "--stream-type", "hls",
        ])
        XCTAssertEqual(add.exitCode, 0, add.diagnosticSummary)
        XCTAssertEqual(add.stderr.count, 0, add.diagnosticSummary)
        assertRedacted(String(data: add.stdout, encoding: .utf8) ?? "", context: .success(dbURL: dbURL))

        let fixture = try seedTimelineFixture(at: dbURL, streamName: streamName)

        let activeStreams = try runSounding(arguments: [
            "streams", "list",
            "--db", dbURL.path,
            "--json",
        ])
        XCTAssertEqual(activeStreams.exitCode, 0, activeStreams.diagnosticSummary)
        XCTAssertEqual(activeStreams.stderr.count, 0, activeStreams.diagnosticSummary)
        let streamsPayload = try decodeJSON(
            StreamsPayload.self, from: activeStreams.stdout, context: activeStreams.diagnosticSummary)
        XCTAssertEqual(streamsPayload.streams.count, 1, activeStreams.diagnosticSummary)
        XCTAssertEqual(streamsPayload.streams.first?.id, fixture.streamID, activeStreams.diagnosticSummary)
        XCTAssertEqual(streamsPayload.streams.first?.status, "active", activeStreams.diagnosticSummary)
        XCTAssertEqual(
            streamsPayload.streams.first?.source,
            "https://example.test/private/integrated.m3u8",
            activeStreams.diagnosticSummary)
        assertRedacted(String(data: activeStreams.stdout, encoding: .utf8) ?? "", context: .success(dbURL: dbURL))

        let transcriptJSON = try runSounding(arguments: [
            "export", "transcripts",
            "--db", dbURL.path,
            "--format", "json",
            "--stream", String(fixture.streamID),
            "--start-seconds", "0",
            "--end-seconds", "30",
        ])
        XCTAssertEqual(transcriptJSON.exitCode, 0, transcriptJSON.diagnosticSummary)
        XCTAssertEqual(transcriptJSON.stderr.count, 0, transcriptJSON.diagnosticSummary)
        let transcriptPayload = try decodeJSON(
            TranscriptPayload.self, from: transcriptJSON.stdout, context: transcriptJSON.diagnosticSummary)
        XCTAssertEqual(transcriptPayload.segments.count, 2, transcriptJSON.diagnosticSummary)
        XCTAssertEqual(transcriptPayload.segments.first?.words.map(\.text), ["Integrated", "alpha", "words"])
        assertRedacted(String(data: transcriptJSON.stdout, encoding: .utf8) ?? "", context: .success(dbURL: dbURL))

        let transcriptText = try runSounding(arguments: [
            "export", "transcripts",
            "--db", dbURL.path,
            "--format", "text",
            "--stream", streamName,
        ])
        XCTAssertEqual(transcriptText.exitCode, 0, transcriptText.diagnosticSummary)
        let transcriptTextOutput = String(data: transcriptText.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(transcriptTextOutput.contains("Segment 1:"), transcriptText.diagnosticSummary)
        XCTAssertTrue(transcriptTextOutput.contains("Integrated alpha words"), transcriptText.diagnosticSummary)
        assertRedacted(transcriptTextOutput, context: .success(dbURL: dbURL))

        let markerOutputURL = temporaryOutputURL(secretComponent: "markers-output-token=synthetic-secret")
        defer { try? FileManager.default.removeItem(at: markerOutputURL) }
        let markerJSONFile = try runSounding(arguments: [
            "export", "markers",
            "--db", dbURL.path,
            "--format", "json",
            "--stream", "hls",
            "--output", markerOutputURL.path,
        ])
        XCTAssertEqual(markerJSONFile.exitCode, 0, markerJSONFile.diagnosticSummary)
        XCTAssertEqual(markerJSONFile.stdout.count, 0, markerJSONFile.diagnosticSummary)
        XCTAssertEqual(markerJSONFile.stderr.count, 0, markerJSONFile.diagnosticSummary)
        let markerFileData = try Data(contentsOf: markerOutputURL)
        let markerPayload = try decodeJSON(
            AdsPayload.self, from: markerFileData, context: markerJSONFile.diagnosticSummary)
        XCTAssertEqual(markerPayload.events.count, 2, markerJSONFile.diagnosticSummary)
        XCTAssertEqual(markerPayload.summary.adStart, 1, markerJSONFile.diagnosticSummary)
        XCTAssertEqual(markerPayload.summary.adEnd, 1, markerJSONFile.diagnosticSummary)
        assertRedacted(
            String(data: markerFileData, encoding: .utf8) ?? "",
            context: .success(dbURL: dbURL, outputURL: markerOutputURL))

        let playsReport = try runSounding(arguments: [
            "report", "plays",
            "--db", dbURL.path,
            "--json",
            "--stream", String(fixture.streamID),
        ])
        XCTAssertEqual(playsReport.exitCode, 0, playsReport.diagnosticSummary)
        XCTAssertEqual(playsReport.stderr.count, 0, playsReport.diagnosticSummary)
        let playsPayload = try decodeJSON(
            PlaysPayload.self, from: playsReport.stdout, context: playsReport.diagnosticSummary)
        XCTAssertEqual(playsPayload.results.count, 2, playsReport.diagnosticSummary)
        XCTAssertEqual(
            Set(playsPayload.results.map { $0.song.displayLabel }),
            Set(["Integrated Artist — Repeatable", "Integrated Artist — Fresh"]),
            playsReport.diagnosticSummary)
        assertRedacted(String(data: playsReport.stdout, encoding: .utf8) ?? "", context: .success(dbURL: dbURL))

        let repeatsExport = try runSounding(arguments: [
            "export", "report",
            "--db", dbURL.path,
            "--kind", "repeats",
            "--format", "json",
            "--stream", String(fixture.streamID),
        ])
        XCTAssertEqual(repeatsExport.exitCode, 0, repeatsExport.diagnosticSummary)
        XCTAssertEqual(repeatsExport.stderr.count, 0, repeatsExport.diagnosticSummary)
        let repeatsPayload = try decodeJSON(
            RepeatsPayload.self, from: repeatsExport.stdout, context: repeatsExport.diagnosticSummary)
        XCTAssertEqual(repeatsPayload.results.count, 1, repeatsExport.diagnosticSummary)
        XCTAssertEqual(repeatsPayload.results.first?.repeatCount, 2, repeatsExport.diagnosticSummary)
        assertRedacted(String(data: repeatsExport.stdout, encoding: .utf8) ?? "", context: .success(dbURL: dbURL))

        let adsReport = try runSounding(arguments: [
            "export", "report",
            "--db", dbURL.path,
            "--kind", "ads",
            "--format", "json",
            "--stream", String(fixture.streamID),
        ])
        XCTAssertEqual(adsReport.exitCode, 0, adsReport.diagnosticSummary)
        let adsReportPayload = try decodeJSON(
            AdsPayload.self, from: adsReport.stdout, context: adsReport.diagnosticSummary)
        XCTAssertEqual(adsReportPayload.events.count, 2, adsReport.diagnosticSummary)
        assertRedacted(String(data: adsReport.stdout, encoding: .utf8) ?? "", context: .success(dbURL: dbURL))

        let remove = try runSounding(arguments: [
            "streams", "remove",
            "--db", dbURL.path,
            String(fixture.streamID),
        ])
        XCTAssertEqual(remove.exitCode, 0, remove.diagnosticSummary)
        XCTAssertEqual(remove.stderr.count, 0, remove.diagnosticSummary)

        let includeRemoved = try runSounding(arguments: [
            "streams", "list",
            "--db", dbURL.path,
            "--json",
            "--include-removed",
        ])
        XCTAssertEqual(includeRemoved.exitCode, 0, includeRemoved.diagnosticSummary)
        let removedStreamsPayload = try decodeJSON(
            StreamsPayload.self, from: includeRemoved.stdout, context: includeRemoved.diagnosticSummary)
        XCTAssertEqual(removedStreamsPayload.streams.first?.status, "removed", includeRemoved.diagnosticSummary)
        assertRedacted(String(data: includeRemoved.stdout, encoding: .utf8) ?? "", context: .success(dbURL: dbURL))

        let removedTranscript = try runSounding(arguments: [
            "export", "transcripts",
            "--db", dbURL.path,
            "--format", "json",
            "--stream", String(fixture.streamID),
        ])
        XCTAssertEqual(removedTranscript.exitCode, 0, removedTranscript.diagnosticSummary)
        let removedTranscriptPayload = try decodeJSON(
            TranscriptPayload.self, from: removedTranscript.stdout, context: removedTranscript.diagnosticSummary)
        XCTAssertEqual(removedTranscriptPayload.segments.count, 2, removedTranscript.diagnosticSummary)
        assertRedacted(String(data: removedTranscript.stdout, encoding: .utf8) ?? "", context: .success(dbURL: dbURL))

        let removedReport = try runSounding(arguments: [
            "report", "plays",
            "--db", dbURL.path,
            "--json",
            "--stream", String(fixture.streamID),
        ])
        XCTAssertEqual(removedReport.exitCode, 0, removedReport.diagnosticSummary)
        let removedReportPayload = try decodeJSON(
            PlaysPayload.self, from: removedReport.stdout, context: removedReport.diagnosticSummary)
        XCTAssertEqual(removedReportPayload.results.count, 2, removedReport.diagnosticSummary)
        assertRedacted(String(data: removedReport.stdout, encoding: .utf8) ?? "", context: .success(dbURL: dbURL))
    }

    func testIntegratedFailureDiagnosticsAreCategorizedAndRedacted() throws {
        for arguments in invalidFilterArguments() {
            let dbPath = try XCTUnwrap(argumentValue(after: "--db", in: arguments))
            defer { removeDatabaseFiles(URL(fileURLWithPath: dbPath)) }

            let result = try runSounding(arguments: arguments)
            XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
            XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath), result.diagnosticSummary)
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            XCTAssertTrue(stderr.contains("configuration failed"), result.diagnosticSummary)
            assertRedacted(stderr, context: .failure(dbPath: dbPath))
        }

        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sounding-integrated-db-user:pass@example.test?token=synthetic-secret#frag",
                isDirectory: true)
        let unopenableDB = missingDirectory.appendingPathComponent("integrated.sqlite")
        defer { try? FileManager.default.removeItem(at: missingDirectory) }
        let unopened = try runSounding(arguments: [
            "export", "markers",
            "--db", unopenableDB.path,
            "--stream", "https://user:pass@example.test/live.m3u8?token=synthetic-secret#frag",
        ])
        XCTAssertNotEqual(unopened.exitCode, 0, unopened.diagnosticSummary)
        XCTAssertEqual(unopened.stdoutLineCount, 0, unopened.diagnosticSummary)
        let unopenedStderr = String(data: unopened.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(unopenedStderr.contains("Export database failed"), unopened.diagnosticSummary)
        XCTAssertTrue(unopenedStderr.contains("redacted database path"), unopened.diagnosticSummary)
        assertRedacted(unopenedStderr, context: .failure(dbPath: unopenableDB.path, directoryPath: missingDirectory.path))

        let dbURL = temporaryDatabaseURL(secretComponent: "integrated-output-token=synthetic-secret")
        defer { removeDatabaseFiles(dbURL) }
        let streamName = "Output Failure"
        let add = try runSounding(arguments: [
            "streams", "add",
            "--db", dbURL.path,
            streamName,
            "https://user:pass@example.test/output.m3u8?token=fixture-secret#frag",
            "--stream-type", "hls",
        ])
        XCTAssertEqual(add.exitCode, 0, add.diagnosticSummary)
        _ = try seedTimelineFixture(at: dbURL, streamName: streamName)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sounding-integrated-output-user:pass@example.test?token=synthetic-secret#frag",
                isDirectory: true)
            .appendingPathComponent("out.json")
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        let outputFailure = try runSounding(arguments: [
            "export", "transcripts",
            "--db", dbURL.path,
            "--format", "json",
            "--output", outputURL.path,
        ])
        XCTAssertNotEqual(outputFailure.exitCode, 0, outputFailure.diagnosticSummary)
        XCTAssertEqual(outputFailure.stdoutLineCount, 0, outputFailure.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path), outputFailure.diagnosticSummary)
        let outputStderr = String(data: outputFailure.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(outputStderr.contains("Export output failed"), outputFailure.diagnosticSummary)
        XCTAssertTrue(outputStderr.contains("[redacted-output-error]"), outputFailure.diagnosticSummary)
        assertRedacted(
            outputStderr,
            context: .failure(
                dbPath: dbURL.path,
                outputPath: outputURL.path,
                directoryPath: outputURL.deletingLastPathComponent().path))
    }

    private struct StreamsPayload: Decodable {
        var streams: [Stream]
    }

    private struct Stream: Decodable {
        var id: Int64
        var status: String
        var source: String
    }

    private struct TranscriptPayload: Decodable {
        var segments: [TranscriptSegment]
    }

    private struct TranscriptSegment: Decodable {
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

    private struct TimelineFixture {
        var streamID: Int64
    }

    private func seedTimelineFixture(at dbURL: URL, streamName: String) throws -> TimelineFixture {
        let database = try SoundingDatabase(fileURL: dbURL)
        let registry = StreamRegistry(database: database)
        let stream = try XCTUnwrap(registry.find(name: streamName, includeRemoved: true))
        let writer = IngestPersistence(database: database)
        let runID = try writer.createRun(
            streamID: stream.id,
            startedAt: "2026-05-01T18:00:01Z",
            status: .running
        )
        let firstChunkID = try writer.createChunk(
            runID: runID,
            sequence: 0,
            segmentURI: "/private/integrated-000.ts?password=fixture-secret",
            startedAt: "2026-05-01T18:00:02Z",
            endedAt: "2026-05-01T18:00:12Z"
        )
        let secondChunkID = try writer.createChunk(
            runID: runID,
            sequence: 1,
            segmentURI: "/private/integrated-001.ts?password=fixture-secret",
            startedAt: "2026-05-01T18:00:22Z",
            endedAt: "2026-05-01T18:00:32Z"
        )

        let repeatSong = UnresolvedSongDraft(
            songKey: "local:integrated-artist:repeatable",
            title: "Repeatable",
            artist: "Integrated Artist",
            album: "Smoke Tests",
            isrc: "US-S05-26-01001",
            displayName: "Integrated Artist — Repeatable"
        )
        let freshSong = UnresolvedSongDraft(
            songKey: "local:integrated-artist:fresh",
            title: "Fresh",
            artist: "Integrated Artist",
            album: "Smoke Tests",
            isrc: "US-S05-26-01002",
            displayName: "Integrated Artist — Fresh"
        )

        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: firstChunkID,
                segments: [segment(0, "host", 0, 10, "Integrated alpha words")],
                adMarkers: [
                    AdMarker(
                        type: "EXT-X-CUE-OUT",
                        classification: .adStart,
                        source: "https://ads.example.test/start?token=fixture-secret",
                        pts: 5,
                        segment: "/private/ad-start.ts?password=fixture-secret",
                        timestamp: "2026-05-01T18:00:05Z")
                ],
                songPlays: [
                    SongPlayDraft(
                        song: repeatSong,
                        startSeconds: 0,
                        endSeconds: 10,
                        confidence: 0.95,
                        source: "https://fingerprints.example.test/repeat?token=fixture-secret"),
                    SongPlayDraft(
                        song: freshSong,
                        startSeconds: 12,
                        endSeconds: 18,
                        confidence: 0.91,
                        source: "/private/fresh-source?password=fixture-secret"),
                ],
                createdAt: "2026-05-01T18:00:03Z"
            )
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: secondChunkID,
                segments: [segment(1, "guest", 20, 30, "Integrated beta words")],
                adMarkers: [
                    AdMarker(
                        type: "EXT-X-CUE-IN",
                        classification: .adEnd,
                        source: "https://ads.example.test/end?token=fixture-secret",
                        pts: 25,
                        segment: "/private/ad-end.ts?password=fixture-secret",
                        timestamp: "2026-05-01T18:00:25Z")
                ],
                songPlays: [
                    SongPlayDraft(
                        song: repeatSong,
                        startSeconds: 22,
                        endSeconds: 30,
                        confidence: 0.93,
                        source: "https://fingerprints.example.test/repeat-again?token=fixture-secret")
                ],
                createdAt: "2026-05-01T18:00:23Z"
            )
        )

        return TimelineFixture(streamID: stream.id)
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

    private func invalidFilterArguments() -> [[String]] {
        [
            [
                "export", "transcripts",
                "--db", temporaryDatabaseURL(secretComponent: "bad-time-token=synthetic-secret").path,
                "--start-seconds", "30",
                "--end-seconds", "20",
            ],
            [
                "export", "markers",
                "--db", temporaryDatabaseURL(secretComponent: "blank-stream-token=synthetic-secret").path,
                "--stream", "   \t",
            ],
            [
                "report", "plays",
                "--db", temporaryDatabaseURL(secretComponent: "nan-time-token=synthetic-secret").path,
                "--start-seconds", "nan",
            ],
        ]
    }

    private func argumentValue(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
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
                "Missing compiled sounding executable. Run `swift build --product sounding` before `swift test --filter IntegratedExportRedactionSmokeTests`.",
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
            .appendingPathComponent("sounding-integrated-\(secretComponent)-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func temporaryOutputURL(secretComponent: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-integrated-output-\(secretComponent)-\(UUID().uuidString)")
            .appendingPathExtension("json")
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
            "exit=\(exitCode), args=\(Self.sanitizedArguments(arguments)), stdoutLines=\(stdoutLineCount), stderr=\(IntegratedExportRedactionSmokeTests.sanitizedSnippet(from: stderr))"
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

    private enum RedactionContext {
        case success(dbURL: URL, outputURL: URL? = nil)
        case failure(dbPath: String, outputPath: String? = nil, directoryPath: String? = nil)

        var forbidden: [(label: String, literal: String)] {
            let common = [
                ("fixture secret", "fixture-secret"),
                ("synthetic secret", "synthetic-secret"),
                ("token query", "token="),
                ("password query", "password="),
                ("url fragment", "#frag"),
                ("url credential", "user:pass"),
                ("private segment", "/private/"),
            ]
            switch self {
            case .success(let dbURL, let outputURL):
                var values = common + [
                    ("database path", dbURL.path),
                    ("database directory", dbURL.deletingLastPathComponent().path),
                    ("package fixture path", packageRootURLStatic.path),
                ]
                if let outputURL {
                    values += [
                        ("output path", outputURL.path),
                        ("output directory", outputURL.deletingLastPathComponent().path),
                    ]
                }
                return values
            case .failure(let dbPath, let outputPath, let directoryPath):
                var values = common + [("database path", dbPath)]
                if let outputPath {
                    values.append(("output path", outputPath))
                }
                if let directoryPath {
                    values.append(("directory path", directoryPath))
                }
                return values
            }
        }
    }

    private func assertRedacted(
        _ text: String,
        context: RedactionContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for forbidden in context.forbidden where !forbidden.literal.isEmpty {
            XCTAssertFalse(
                text.contains(forbidden.literal),
                "Expected output to redact \(forbidden.label); output=\(Self.sanitizedSnippet(from: Data(text.utf8)))",
                file: file,
                line: line
            )
        }
    }

    private static let packageRootURLStatic = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

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
}
