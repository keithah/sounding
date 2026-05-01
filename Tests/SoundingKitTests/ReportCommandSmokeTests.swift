import Foundation
import GRDB
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
        for command in ["plays", "repeats", "ads"] {
            XCTAssertTrue(reportHelp.contains(command), report.diagnosticSummary)
        }

        for command in ["plays", "repeats", "ads"] {
            let help = try runSounding(arguments: ["report", command, "--help"])
            XCTAssertEqual(help.exitCode, 0, help.diagnosticSummary)
            let helpText = String(data: help.stdout, encoding: .utf8) ?? ""
            for flag in ["--db", "--json", "--stream", "--start-seconds", "--end-seconds"] {
                XCTAssertTrue(
                    helpText.contains(flag),
                    "Expected report \(command) help to advertise \(flag). \(help.diagnosticSummary)"
                )
            }
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

        let repeatsJSON = try runSounding(arguments: [
            "report", "repeats",
            "--db", dbURL.path,
            "--json",
        ])
        XCTAssertEqual(repeatsJSON.exitCode, 0, repeatsJSON.diagnosticSummary)
        XCTAssertEqual(repeatsJSON.stderr.count, 0, repeatsJSON.diagnosticSummary)
        let repeatsPayload = try decodeJSON(
            RepeatsPayload.self, from: repeatsJSON.stdout, context: repeatsJSON.diagnosticSummary)
        XCTAssertEqual(repeatsPayload.results.count, 0, repeatsJSON.diagnosticSummary)
        let repeatsText = String(data: repeatsJSON.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(repeatsText.hasSuffix("\n"), repeatsJSON.diagnosticSummary)
        assertSanitized(repeatsText, forbiddenLiteral: fixture.path)
        assertSanitized(repeatsText, forbiddenLiteral: dbURL.path)

        let adsJSON = try runSounding(arguments: [
            "report", "ads",
            "--db", dbURL.path,
            "--json",
        ])
        XCTAssertEqual(adsJSON.exitCode, 0, adsJSON.diagnosticSummary)
        XCTAssertEqual(adsJSON.stderr.count, 0, adsJSON.diagnosticSummary)
        let adsPayload = try decodeJSON(
            AdsPayload.self, from: adsJSON.stdout, context: adsJSON.diagnosticSummary)
        XCTAssertGreaterThanOrEqual(adsPayload.events.count, 1, adsJSON.diagnosticSummary)
        XCTAssertEqual(
            adsPayload.summary.adStart + adsPayload.summary.adEnd + adsPayload.summary.unknown,
            adsPayload.events.count,
            adsJSON.diagnosticSummary)
        let adsText = String(data: adsJSON.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(adsText.hasSuffix("\n"), adsJSON.diagnosticSummary)
        assertSanitized(adsText, forbiddenLiteral: fixture.path)
        assertSanitized(adsText, forbiddenLiteral: dbURL.path)
    }

    func testAcoustIDStubIngestReportsEnrichedSongAndCachesLookup() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "enriched-report-token=synthetic-secret")
        defer { removeDatabaseFiles(dbURL) }
        let fixture =
            packageRootURL
            .appendingPathComponent("Tests/SoundingKitTests/Fixtures/HLS/manifest-scte35.m3u8")
        let syntheticAPIKey = "api_key=synthetic-secret-value"

        let ingest = try runSounding(
            arguments: [
                "ingest",
                fixture.path,
                "--db", dbURL.path,
                "--stream-type", "hls",
                "--max-chunks", "1",
            ],
            environment: [
                "SOUNDING_DETERMINISTIC_ML": "1",
                "SOUNDING_ACOUSTID_STUB": "success",
                "SOUNDING_ACOUSTID_API_KEY": syntheticAPIKey,
            ]
        )
        XCTAssertEqual(ingest.exitCode, 0, ingest.diagnosticSummary)
        let ingestStdout = String(data: ingest.stdout, encoding: .utf8) ?? ""
        let ingestStderr = String(data: ingest.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(ingestStdout.contains("diagnostics=0"), ingest.diagnosticSummary)
        assertSanitized(ingestStdout, forbiddenLiteral: syntheticAPIKey)
        assertSanitized(ingestStderr, forbiddenLiteral: syntheticAPIKey)
        assertSanitized(ingestStdout, forbiddenLiteral: fixture.path)
        assertSanitized(ingestStderr, forbiddenLiteral: fixture.path)
        assertSanitized(ingestStdout, forbiddenLiteral: dbURL.path)
        assertSanitized(ingestStderr, forbiddenLiteral: dbURL.path)

        let json = try runSounding(arguments: [
            "report", "plays",
            "--db", dbURL.path,
            "--json",
        ])
        XCTAssertEqual(json.exitCode, 0, json.diagnosticSummary)
        XCTAssertEqual(json.stderr.count, 0, json.diagnosticSummary)
        let payload = try decodeJSON(
            PlaysPayload.self, from: json.stdout, context: json.diagnosticSummary)
        XCTAssertEqual(payload.results.count, 1, json.diagnosticSummary)
        let play = try XCTUnwrap(payload.results.first, json.diagnosticSummary)
        XCTAssertEqual(play.identity.streamType, "hls", json.diagnosticSummary)
        XCTAssertEqual(play.song.artist, "Sounding Fixtures", json.diagnosticSummary)
        XCTAssertTrue(
            play.song.title?.hasPrefix("Deterministic Song ") == true,
            json.diagnosticSummary)
        XCTAssertTrue(play.song.isrc?.hasPrefix("QSND26") == true, json.diagnosticSummary)
        XCTAssertFalse(play.song.isUnknown, json.diagnosticSummary)
        XCTAssertEqual(
            play.song.displayLabel,
            "Sounding Fixtures — \(play.song.title ?? "")",
            json.diagnosticSummary)
        XCTAssertEqual(play.source, "deterministic_fingerprint", json.diagnosticSummary)

        let jsonText = String(data: json.stdout, encoding: .utf8) ?? ""
        assertSanitized(jsonText, forbiddenLiteral: syntheticAPIKey)
        assertSanitized(jsonText, forbiddenLiteral: fixture.path)
        assertSanitized(jsonText, forbiddenLiteral: dbURL.path)

        let database = try DatabaseQueue(path: dbURL.path)
        let counts = try database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM acoustid_lookup_cache) AS cache_count,
                        (SELECT COUNT(*) FROM ingest_diagnostics WHERE phase = 'fingerprint') AS fingerprint_diagnostics
                    """)
        }
        XCTAssertEqual(counts?["cache_count"] as Int?, 1, json.diagnosticSummary)
        XCTAssertEqual(counts?["fingerprint_diagnostics"] as Int?, 0, json.diagnosticSummary)
    }

    func testSeededDatabaseReportsKnownRepeatsAndAdsThroughCLIWithFilters() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "seeded-reports-token=synthetic-secret")
        defer { removeDatabaseFiles(dbURL) }
        let addStream = try runSounding(arguments: [
            "streams", "add",
            "--db", dbURL.path,
            "Managed Main",
            "https://example.test/repeats.m3u8?token=fixture-secret#frag",
            "--stream-type", "hls",
        ])
        XCTAssertEqual(addStream.exitCode, 0, addStream.diagnosticSummary)
        assertSanitizedReportOutput(
            String(data: addStream.stdout, encoding: .utf8) ?? "", dbURL: dbURL)

        let fixture = try seedReportFixture(at: dbURL)

        let playsByName = try runSounding(arguments: [
            "report", "plays",
            "--db", dbURL.path,
            "--json",
            "--stream", fixture.streamName,
        ])
        XCTAssertEqual(playsByName.exitCode, 0, playsByName.diagnosticSummary)
        XCTAssertEqual(playsByName.stderr.count, 0, playsByName.diagnosticSummary)
        let playsByNamePayload = try decodeJSON(
            PlaysPayload.self, from: playsByName.stdout, context: playsByName.diagnosticSummary)
        XCTAssertEqual(playsByNamePayload.results.count, 2, playsByName.diagnosticSummary)
        XCTAssertEqual(
            Set(playsByNamePayload.results.map { $0.identity.streamID }),
            Set([fixture.hlsStreamID]),
            playsByName.diagnosticSummary)
        assertSanitizedReportOutput(
            String(data: playsByName.stdout, encoding: .utf8) ?? "", dbURL: dbURL)

        let repeatsHuman = try runSounding(arguments: [
            "report", "repeats",
            "--db", dbURL.path,
            "--stream", "hls",
            "--start-seconds", "5",
            "--end-seconds", "26",
        ])
        XCTAssertEqual(repeatsHuman.exitCode, 0, repeatsHuman.diagnosticSummary)
        XCTAssertEqual(repeatsHuman.stderr.count, 0, repeatsHuman.diagnosticSummary)
        let repeatsHumanText = String(data: repeatsHuman.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(repeatsHumanText.contains("Repeat 1:"), repeatsHuman.diagnosticSummary)
        XCTAssertTrue(repeatsHumanText.contains("count=2"), repeatsHuman.diagnosticSummary)
        XCTAssertTrue(
            repeatsHumanText.contains("song=Repeat Artist — Echo Song"),
            repeatsHuman.diagnosticSummary)
        assertSanitizedReportOutput(repeatsHumanText, dbURL: dbURL)

        let repeatsJSON = try runSounding(arguments: [
            "report", "repeats",
            "--db", dbURL.path,
            "--json",
            "--stream", String(fixture.hlsStreamID),
            "--start-seconds", "5",
            "--end-seconds", "26",
        ])
        XCTAssertEqual(repeatsJSON.exitCode, 0, repeatsJSON.diagnosticSummary)
        XCTAssertEqual(repeatsJSON.stderr.count, 0, repeatsJSON.diagnosticSummary)
        let repeatsPayload = try decodeJSON(
            RepeatsPayload.self, from: repeatsJSON.stdout, context: repeatsJSON.diagnosticSummary)
        let repeatGroup = try XCTUnwrap(repeatsPayload.results.first, repeatsJSON.diagnosticSummary)
        XCTAssertEqual(repeatsPayload.results.count, 1, repeatsJSON.diagnosticSummary)
        XCTAssertEqual(
            repeatGroup.groupKey, "artist-title:repeat artist:echo song",
            repeatsJSON.diagnosticSummary)
        XCTAssertEqual(repeatGroup.repeatCount, 2, repeatsJSON.diagnosticSummary)
        XCTAssertEqual(repeatGroup.plays.count, 2, repeatsJSON.diagnosticSummary)
        let repeatsText = String(data: repeatsJSON.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(repeatsText.hasSuffix("\n"), repeatsJSON.diagnosticSummary)
        assertSanitizedReportOutput(repeatsText, dbURL: dbURL)

        let adsHuman = try runSounding(arguments: [
            "report", "ads",
            "--db", dbURL.path,
            "--stream", "hls",
            "--start-seconds", "0",
            "--end-seconds", "20",
        ])
        XCTAssertEqual(adsHuman.exitCode, 0, adsHuman.diagnosticSummary)
        XCTAssertEqual(adsHuman.stderr.count, 0, adsHuman.diagnosticSummary)
        let adsHumanText = String(data: adsHuman.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(
            adsHumanText.contains("Ad summary: total=2 unknown=0 ad_start=1 ad_end=1"),
            adsHuman.diagnosticSummary)
        XCTAssertTrue(adsHumanText.contains("classification=AD_START"), adsHuman.diagnosticSummary)
        XCTAssertTrue(adsHumanText.contains("classification=AD_END"), adsHuman.diagnosticSummary)
        assertSanitizedReportOutput(adsHumanText, dbURL: dbURL)

        let adsJSON = try runSounding(arguments: [
            "report", "ads",
            "--db", dbURL.path,
            "--json",
            "--stream", "hls",
            "--start-seconds", "0",
            "--end-seconds", "20",
        ])
        XCTAssertEqual(adsJSON.exitCode, 0, adsJSON.diagnosticSummary)
        XCTAssertEqual(adsJSON.stderr.count, 0, adsJSON.diagnosticSummary)
        let adsPayload = try decodeJSON(
            AdsPayload.self, from: adsJSON.stdout, context: adsJSON.diagnosticSummary)
        XCTAssertEqual(adsPayload.events.count, 2, adsJSON.diagnosticSummary)
        XCTAssertEqual(adsPayload.summary.unknown, 0, adsJSON.diagnosticSummary)
        XCTAssertEqual(adsPayload.summary.adStart, 1, adsJSON.diagnosticSummary)
        XCTAssertEqual(adsPayload.summary.adEnd, 1, adsJSON.diagnosticSummary)
        let adsText = String(data: adsJSON.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(adsText.hasSuffix("\n"), adsJSON.diagnosticSummary)
        assertSanitizedReportOutput(adsText, dbURL: dbURL)

        let removeStream = try runSounding(arguments: [
            "streams", "remove",
            "--db", dbURL.path,
            String(fixture.hlsStreamID),
        ])
        XCTAssertEqual(removeStream.exitCode, 0, removeStream.diagnosticSummary)

        let removedById = try runSounding(arguments: [
            "report", "plays",
            "--db", dbURL.path,
            "--json",
            "--stream", String(fixture.hlsStreamID),
        ])
        XCTAssertEqual(removedById.exitCode, 0, removedById.diagnosticSummary)
        XCTAssertEqual(removedById.stderr.count, 0, removedById.diagnosticSummary)
        let removedPayload = try decodeJSON(
            PlaysPayload.self, from: removedById.stdout, context: removedById.diagnosticSummary)
        XCTAssertEqual(removedPayload.results.count, 2, removedById.diagnosticSummary)
        XCTAssertEqual(
            Set(removedPayload.results.map { $0.identity.streamID }),
            Set([fixture.hlsStreamID]),
            removedById.diagnosticSummary)
        assertSanitizedReportOutput(
            String(data: removedById.stdout, encoding: .utf8) ?? "", dbURL: dbURL)
    }

    func testAcoustIDFailureStubsRemainNonFatalAndReportFallbacksWithRedactedDiagnostics() throws {
        struct FailureCase {
            var name: String
            var environment: [String: String]
            var expectedReason: String
            var forbidden: [String]
        }

        let credentialURL = "https://user:pass@example.test/lookup?token=synthetic-secret"
        let malformedRaw = "raw={\"api_key\":\"synthetic-secret\""
        let cases = [
            FailureCase(
                name: "missing-key",
                environment: [
                    "SOUNDING_DETERMINISTIC_ML": "1",
                    "SOUNDING_ACOUSTID_API_KEY": "",
                    "SOUNDING_ACOUSTID_STUB": "",
                ],
                expectedReason: "acoustid-lookup-disabled",
                forbidden: ["synthetic-secret"]
            ),
            FailureCase(
                name: "transient",
                environment: [
                    "SOUNDING_DETERMINISTIC_ML": "1",
                    "SOUNDING_ACOUSTID_STUB": "transient",
                    "SOUNDING_ACOUSTID_API_KEY": "api_key=synthetic-secret-value",
                ],
                expectedReason: "acoustid-transient-failure",
                forbidden: ["synthetic-secret", "/tmp/acoustid-token=synthetic-secret.json"]
            ),
            FailureCase(
                name: "rate-limit",
                environment: [
                    "SOUNDING_DETERMINISTIC_ML": "1",
                    "SOUNDING_ACOUSTID_STUB": "rate-limit",
                    "SOUNDING_ACOUSTID_API_KEY": "api_key=synthetic-secret-value",
                ],
                expectedReason: "acoustid-rate-limited",
                forbidden: ["synthetic-secret"]
            ),
            FailureCase(
                name: "malformed",
                environment: [
                    "SOUNDING_DETERMINISTIC_ML": "1",
                    "SOUNDING_ACOUSTID_STUB": "malformed",
                    "SOUNDING_ACOUSTID_API_KEY": "api_key=synthetic-secret-value",
                ],
                expectedReason: "acoustid-malformed-response",
                forbidden: [
                    "synthetic-secret", "user:pass", credentialURL, malformedRaw,
                    "/tmp/acoustid-token=synthetic-secret.json",
                ]
            ),
        ]

        for failureCase in cases {
            let dbURL = temporaryDatabaseURL(
                secretComponent: "acoustid-\(failureCase.name)-token=synthetic-secret")
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
                environment: failureCase.environment
            )
            XCTAssertEqual(ingest.exitCode, 0, "\(failureCase.name): \(ingest.diagnosticSummary)")
            let ingestStdout = String(data: ingest.stdout, encoding: .utf8) ?? ""
            let ingestStderr = String(data: ingest.stderr, encoding: .utf8) ?? ""
            XCTAssertTrue(ingestStdout.contains("diagnostics=1"), ingest.diagnosticSummary)

            let report = try runSounding(arguments: [
                "report", "plays",
                "--db", dbURL.path,
                "--json",
            ])
            XCTAssertEqual(report.exitCode, 0, "\(failureCase.name): \(report.diagnosticSummary)")
            XCTAssertEqual(report.stderr.count, 0, report.diagnosticSummary)
            let payload = try decodeJSON(
                PlaysPayload.self, from: report.stdout, context: report.diagnosticSummary)
            XCTAssertEqual(payload.results.count, 1, report.diagnosticSummary)
            let play = try XCTUnwrap(payload.results.first, report.diagnosticSummary)
            XCTAssertTrue(play.song.songKey.hasPrefix("fingerprint:"), report.diagnosticSummary)
            XCTAssertTrue(play.song.isUnknown, report.diagnosticSummary)
            XCTAssertTrue(play.song.displayLabel.hasPrefix("unknown("), report.diagnosticSummary)
            XCTAssertEqual(play.source, "deterministic_fingerprint", report.diagnosticSummary)

            let database = try DatabaseQueue(path: dbURL.path)
            let row = try database.read { db in
                try Row.fetchOne(
                    db,
                    sql: """
                        SELECT reason, context_json,
                               (SELECT COUNT(*) FROM song_plays) AS play_count,
                               (SELECT COUNT(*) FROM acoustid_lookup_cache) AS cache_count
                        FROM ingest_diagnostics
                        WHERE phase = 'fingerprint'
                        LIMIT 1
                        """)
            }
            XCTAssertEqual(row?["reason"] as String?, failureCase.expectedReason)
            XCTAssertEqual(row?["play_count"] as Int?, 1)
            XCTAssertEqual(row?["cache_count"] as Int?, 0)
            let context = row?["context_json"] as String? ?? ""
            if failureCase.expectedReason == "acoustid-rate-limited" {
                XCTAssertTrue(context.contains("retryAfterSeconds"), context)
            }

            let reportText = String(data: report.stdout, encoding: .utf8) ?? ""
            for forbidden in failureCase.forbidden + [fixture.path, dbURL.path] {
                assertSanitized(ingestStdout, forbiddenLiteral: forbidden)
                assertSanitized(ingestStderr, forbiddenLiteral: forbidden)
                assertSanitized(reportText, forbiddenLiteral: forbidden)
                assertSanitized(context, forbiddenLiteral: forbidden)
            }
        }
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

        let repeatsJSON = try runSounding(arguments: [
            "report", "repeats", "--db", dbURL.path, "--json",
        ])
        XCTAssertEqual(repeatsJSON.exitCode, 0, repeatsJSON.diagnosticSummary)
        XCTAssertEqual(
            String(data: repeatsJSON.stdout, encoding: .utf8),
            "{\"results\":[]}\n"
        )

        let adsJSON = try runSounding(arguments: [
            "report", "ads", "--db", dbURL.path, "--json",
        ])
        XCTAssertEqual(adsJSON.exitCode, 0, adsJSON.diagnosticSummary)
        XCTAssertEqual(
            String(data: adsJSON.stdout, encoding: .utf8),
            "{\"events\":[],\"summary\":{\"adEnd\":0,\"adStart\":0,\"unknown\":0}}\n"
        )
    }

    func testValidationRejectsMalformedInputsBeforeOpeningDatabase() throws {
        for command in ["plays", "repeats", "ads"] {
            let invalidCases: [[String]] = [
                [
                    "report", command,
                    "--db",
                    temporaryDatabaseURL(secretComponent: "blank-stream-token=synthetic-secret")
                        .path,
                    "--stream", "   \t",
                ],
                [
                    "report", command,
                    "--db",
                    temporaryDatabaseURL(secretComponent: "bad-time-token=synthetic-secret").path,
                    "--start-seconds", "30",
                    "--end-seconds", "20",
                ],
                [
                    "report", command,
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
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: dbPath), result.diagnosticSummary)
                let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
                XCTAssertTrue(
                    stderr.contains("Report configuration failed"), result.diagnosticSummary)
                assertSanitized(stderr, forbiddenLiteral: dbPath)
                assertSanitized(stderr, forbiddenLiteral: "synthetic-secret")
            }

            let missingDB = try runSounding(arguments: ["report", command])
            XCTAssertNotEqual(missingDB.exitCode, 0, missingDB.diagnosticSummary)
            XCTAssertEqual(missingDB.stdoutLineCount, 0, missingDB.diagnosticSummary)
            let missingDBStderr = String(data: missingDB.stderr, encoding: .utf8) ?? ""
            XCTAssertTrue(missingDBStderr.contains("--db"), missingDB.diagnosticSummary)
        }
    }

    func testUnopenableDatabasePathIsRedacted() throws {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sounding-report-db-user:pass@example.test?token=synthetic-secret#frag",
                isDirectory: true)
        let dbURL = missingDirectory.appendingPathComponent("report.sqlite")
        defer { try? FileManager.default.removeItem(at: missingDirectory) }

        for command in ["plays", "repeats", "ads"] {
            let result = try runSounding(arguments: [
                "report", command,
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
    }

    private struct PlaysPayload: Decodable {
        var results: [Play]
    }

    private struct RepeatsPayload: Decodable {
        var results: [Repeat]
    }

    private struct Repeat: Decodable {
        var groupKey: String
        var repeatCount: Int
        var plays: [Play]
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

    private struct Play: Decodable {
        var identity: Identity
        var song: Song
        var source: String?
    }

    private struct Identity: Decodable {
        var streamID: Int64
        var streamType: String
    }

    private struct Song: Decodable {
        var songKey: String
        var title: String?
        var artist: String?
        var isrc: String?
        var displayLabel: String
        var isUnknown: Bool
    }

    private struct SeededReportFixture {
        var hlsStreamID: Int64
        var streamName: String
    }

    private func seedReportFixture(at dbURL: URL) throws -> SeededReportFixture {
        let database = try SoundingDatabase(fileURL: dbURL)
        let writer = IngestPersistence(database: database)
        let registry = StreamRegistry(database: database)
        let streamName = "Managed Main"
        let hlsStream =
            try registry.find(name: streamName, includeRemoved: true)
            ?? registry.add(
                name: streamName,
                streamType: "hls",
                source: "https://example.test/repeats.m3u8?token=fixture-secret#frag",
                createdAt: "2026-05-01T12:00:00Z")
        let hlsStreamID = hlsStream.id
        let hlsRunID = try writer.createRun(
            streamID: hlsStreamID,
            startedAt: "2026-05-01T12:00:01Z",
            status: .running
        )
        let firstChunkID = try writer.createChunk(
            runID: hlsRunID,
            sequence: 0,
            segmentURI: "/private/repeat-000.ts?password=fixture-secret",
            startedAt: "2026-05-01T12:00:02Z",
            endedAt: "2026-05-01T12:00:12Z"
        )
        let secondChunkID = try writer.createChunk(
            runID: hlsRunID,
            sequence: 1,
            segmentURI: "/private/repeat-001.ts?password=fixture-secret",
            startedAt: "2026-05-01T12:00:22Z",
            endedAt: "2026-05-01T12:00:32Z"
        )

        let repeatSong = UnresolvedSongDraft(
            songKey: "local:repeat-artist:echo-song",
            title: "Echo Song",
            artist: "Repeat Artist",
            album: "Smoke Tests",
            isrc: "US-S03-26-00001",
            displayName: "Repeat Artist — Echo Song"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: hlsRunID,
                chunkID: firstChunkID,
                adMarkers: [
                    AdMarker(
                        type: "EXT-X-CUE-OUT",
                        classification: .adStart,
                        source: "https://ads.example.test/start?token=fixture-secret",
                        pts: 5,
                        segment: "/private/ad-start.ts?password=fixture-secret",
                        timestamp: "2026-05-01T12:00:05Z")
                ],
                songPlays: [
                    SongPlayDraft(
                        song: repeatSong,
                        startSeconds: 0,
                        endSeconds: 10,
                        confidence: 0.91,
                        source: "https://fingerprints.example.test/match?token=fixture-secret")
                ],
                createdAt: "2026-05-01T12:00:03Z"
            )
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: hlsRunID,
                chunkID: secondChunkID,
                adMarkers: [
                    AdMarker(
                        type: "EXT-X-CUE-IN",
                        classification: .adEnd,
                        source: "https://ads.example.test/end?token=fixture-secret",
                        pts: 20,
                        segment: "/private/ad-end.ts?password=fixture-secret",
                        timestamp: "2026-05-01T12:00:20Z")
                ],
                songPlays: [
                    SongPlayDraft(
                        song: repeatSong,
                        startSeconds: 20,
                        endSeconds: 30,
                        confidence: 0.89,
                        source: "/private/fingerprint-source?password=fixture-secret")
                ],
                createdAt: "2026-05-01T12:00:23Z"
            )
        )

        return SeededReportFixture(hlsStreamID: hlsStreamID, streamName: streamName)
    }

    private func assertSanitizedReportOutput(
        _ text: String,
        dbURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for forbidden in [
            dbURL.path,
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
