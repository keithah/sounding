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

    func testRejectsTooManySourcesBeforeCreatingDatabase() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "too-many-token=synthetic-secret")
        defer { removeDatabaseFiles(dbURL) }

        let result = try runSounding(arguments: [
            "ingest",
            "https://user:pass@example.test/one.m3u8?token=synthetic-secret",
            "https://user:pass@example.test/two.m3u8?token=synthetic-secret",
            "https://user:pass@example.test/three.m3u8?token=synthetic-secret",
            "--db", dbURL.path,
            "--max-chunks", "1",
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.diagnosticSummary)
        XCTAssertEqual(result.stdoutLineCount, 0, result.diagnosticSummary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path), result.diagnosticSummary)
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("Ingest configuration failed"), result.diagnosticSummary)
        XCTAssertTrue(stderr.contains("at most 2 sources"), result.diagnosticSummary)
        assertSanitized(stderr, forbiddenLiteral: "user:pass")
        assertSanitized(stderr, forbiddenLiteral: "synthetic-secret")
        assertSanitized(stderr, forbiddenLiteral: dbURL.path)
    }

    func testTwoSourceIngestPersistsDistinctRunsAndSearchCountJSONDistinguishStreams() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "two-source")
        defer { removeDatabaseFiles(dbURL) }
        let fixture =
            packageRootURL
            .appendingPathComponent("Tests/SoundingKitTests/Fixtures/HLS/manifest-scte35.m3u8")

        let ingest = try runSounding(
            arguments: [
                "ingest",
                fixture.path,
                fixture.path,
                "--db", dbURL.path,
                "--stream-type", "hls",
                "--max-chunks", "1",
            ],
            environment: [
                "SOUNDING_DETERMINISTIC_ML": "1",
                "SOUNDING_ACOUSTID_STUB": "success",
            ]
        )

        XCTAssertEqual(ingest.exitCode, 0, ingest.diagnosticSummary)
        let stdout = String(data: ingest.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(stdout.contains("index=0"), ingest.diagnosticSummary)
        XCTAssertTrue(stdout.contains("index=1"), ingest.diagnosticSummary)
        XCTAssertTrue(stdout.contains("status=completed"), ingest.diagnosticSummary)
        XCTAssertTrue(stdout.contains("chunks=1"), ingest.diagnosticSummary)
        assertSanitized(stdout, forbiddenLiteral: fixture.path)
        assertSanitized(stdout, forbiddenLiteral: dbURL.path)

        let database = try DatabaseQueue(path: dbURL.path)
        let counts = try database.read { db in
            try [
                "streams": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM streams"),
                "completed_runs": Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM ingest_runs WHERE status = 'completed'"),
                "chunks": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_chunks"),
                "segments": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments"),
                "words": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_words"),
                "turns": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_turns"),
                "ads": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ad_events"),
                "audio_fingerprints": Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM audio_fingerprints"),
                "songs": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM songs"),
                "song_plays": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song_plays"),
                "acoustid_lookup_cache": Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM acoustid_lookup_cache"),
            ]
        }
        XCTAssertEqual(counts["streams"] as? Int, 2)
        XCTAssertEqual(counts["completed_runs"] as? Int, 2)
        XCTAssertEqual(counts["chunks"] as? Int, 2)
        XCTAssertEqual(counts["segments"] as? Int, 2)
        XCTAssertEqual(counts["words"] as? Int, 10)
        XCTAssertEqual(counts["turns"] as? Int, 2)
        XCTAssertEqual(counts["ads"] as? Int, 2)
        XCTAssertEqual(counts["audio_fingerprints"] as? Int, 2)
        XCTAssertEqual(counts["songs"] as? Int, 1)
        XCTAssertEqual(counts["song_plays"] as? Int, 2)
        XCTAssertEqual(counts["acoustid_lookup_cache"] as? Int, 1)

        let enrichedSong = try database.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT title, artist FROM songs WHERE song_key LIKE 'fingerprint:%' LIMIT 1")
        }
        XCTAssertTrue(
            (enrichedSong?["title"] as String? ?? "").hasPrefix("Deterministic Song "),
            ingest.diagnosticSummary)
        XCTAssertEqual(enrichedSong?["artist"] as String?, "Sounding Fixtures")

        let search = try runSounding(arguments: [
            "search", "cli shared phrase",
            "--db", dbURL.path,
            "--limit", "10",
            "--json",
        ])
        XCTAssertEqual(search.exitCode, 0, search.diagnosticSummary)
        let searchObject = try jsonObject(from: search.stdout)
        let searchResults = try XCTUnwrap(searchObject["results"] as? [[String: Any]])
        XCTAssertEqual(searchResults.count, 2, search.diagnosticSummary)
        let streamIDs = Set(
            searchResults.compactMap { result -> Int64? in
                guard let identity = result["identity"] as? [String: Any],
                    let value = identity["streamID"] as? Int
                else { return nil }
                return Int64(value)
            })
        XCTAssertEqual(streamIDs.count, 2, search.diagnosticSummary)

        let count = try runSounding(arguments: [
            "count", "cli shared phrase",
            "--db", dbURL.path,
            "--json",
        ])
        XCTAssertEqual(count.exitCode, 0, count.diagnosticSummary)
        let countObject = try jsonObject(from: count.stdout)
        let countResults = try XCTUnwrap(countObject["results"] as? [[String: Any]])
        XCTAssertEqual(countResults.count, 2, count.diagnosticSummary)
        let countStreamIDs = Set(
            countResults.compactMap { result -> Int64? in
                guard let value = result["streamID"] as? Int else { return nil }
                return Int64(value)
            })
        XCTAssertEqual(countStreamIDs, streamIDs, count.diagnosticSummary)
    }

    func testAcoustIDNoKeyModeCompletesAndPersistsRedactedDisabledDiagnostic() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "acoustid-no-key-token=synthetic-secret")
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
            environment: [
                "SOUNDING_DETERMINISTIC_ML": "1",
                "SOUNDING_ACOUSTID_API_KEY": "",
                "SOUNDING_ACOUSTID_STUB": "",
            ]
        )

        XCTAssertEqual(ingest.exitCode, 0, ingest.diagnosticSummary)
        let stdout = String(data: ingest.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(stdout.contains("diagnostics=1"), ingest.diagnosticSummary)
        let stderr = String(data: ingest.stderr, encoding: .utf8) ?? ""
        assertSanitized(stderr, forbiddenLiteral: fixture.path)
        assertSanitized(stderr, forbiddenLiteral: dbURL.path)

        let database = try DatabaseQueue(path: dbURL.path)
        let diagnostic = try database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT reason, context_json
                    FROM ingest_diagnostics
                    WHERE phase = 'fingerprint'
                    LIMIT 1
                    """)
        }
        XCTAssertEqual(diagnostic?["reason"] as String?, "acoustid-lookup-disabled")
        let context = diagnostic?["context_json"] as String? ?? ""
        XCTAssertTrue(context.contains("acoustid api key missing"), context)
        assertSanitized(context, forbiddenLiteral: dbURL.path)
        assertSanitized(context, forbiddenLiteral: fixture.path)
    }

    func testAcoustIDStubModeEnrichesSongAndCachesLookupWithoutSecretLeak() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "acoustid-stub-token=synthetic-secret")
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
        let stdout = String(data: ingest.stdout, encoding: .utf8) ?? ""
        let stderr = String(data: ingest.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(stdout.contains("diagnostics=0"), ingest.diagnosticSummary)
        assertSanitized(stdout, forbiddenLiteral: syntheticAPIKey)
        assertSanitized(stderr, forbiddenLiteral: syntheticAPIKey)
        assertSanitized(stdout, forbiddenLiteral: dbURL.path)
        assertSanitized(stderr, forbiddenLiteral: dbURL.path)

        let database = try DatabaseQueue(path: dbURL.path)
        let row = try database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT songs.title AS title,
                           songs.artist AS artist,
                           acoustid_lookup_cache.title AS cached_title,
                           acoustid_lookup_cache.artist AS cached_artist,
                           (SELECT COUNT(*) FROM acoustid_lookup_cache) AS cache_count,
                           (SELECT COUNT(*) FROM ingest_diagnostics WHERE phase = 'fingerprint') AS fingerprint_diagnostics
                    FROM songs
                    JOIN acoustid_lookup_cache ON acoustid_lookup_cache.title = songs.title
                    WHERE songs.song_key LIKE 'fingerprint:%'
                    LIMIT 1
                    """)
        }
        XCTAssertTrue((row?["title"] as String? ?? "").hasPrefix("Deterministic Song "))
        XCTAssertEqual(row?["artist"] as String?, "Sounding Fixtures")
        XCTAssertEqual(row?["cached_artist"] as String?, "Sounding Fixtures")
        XCTAssertEqual(row?["cache_count"] as Int?, 1)
        XCTAssertEqual(row?["fingerprint_diagnostics"] as Int?, 0)
    }

    func testAcoustIDUnknownStubModeCompletesWithRedactedConfigurationDiagnostic() throws {
        let dbURL = temporaryDatabaseURL(
            secretComponent: "acoustid-unknown-stub-token=synthetic-secret")
        defer { removeDatabaseFiles(dbURL) }
        let fixture =
            packageRootURL
            .appendingPathComponent("Tests/SoundingKitTests/Fixtures/HLS/manifest-scte35.m3u8")
        let secretStubMode = "secret-stub-mode-token=synthetic-secret"

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
                "SOUNDING_ACOUSTID_STUB": secretStubMode,
            ]
        )

        XCTAssertEqual(ingest.exitCode, 0, ingest.diagnosticSummary)
        let stdout = String(data: ingest.stdout, encoding: .utf8) ?? ""
        let stderr = String(data: ingest.stderr, encoding: .utf8) ?? ""
        assertSanitized(stdout, forbiddenLiteral: secretStubMode)
        assertSanitized(stderr, forbiddenLiteral: secretStubMode)

        let database = try DatabaseQueue(path: dbURL.path)
        let context =
            try database.read { db in
                try String.fetchOne(
                    db,
                    sql: """
                        SELECT context_json
                        FROM ingest_diagnostics
                        WHERE reason = 'acoustid-lookup-disabled'
                        LIMIT 1
                        """)
            } ?? ""
        XCTAssertTrue(context.contains("unknown SOUNDING_ACOUSTID_STUB value"), context)
        assertSanitized(context, forbiddenLiteral: secretStubMode)
        assertSanitized(context, forbiddenLiteral: "synthetic-secret")
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

    func testManagedStreamValidationFailuresHappenBeforeRunsOrSourceSetup() throws {
        let noDB = try runSounding(arguments: [
            "ingest",
            "--stream", "Main",
            "--max-chunks", "1",
        ])
        XCTAssertNotEqual(noDB.exitCode, 0, noDB.diagnosticSummary)
        XCTAssertEqual(noDB.stdoutLineCount, 0, noDB.diagnosticSummary)
        XCTAssertTrue(
            (String(data: noDB.stderr, encoding: .utf8) ?? "").contains("provide --db"),
            noDB.diagnosticSummary)

        let ambiguityDB = temporaryDatabaseURL(
            secretComponent: "managed-ambiguous-token=synthetic-secret")
        defer { removeDatabaseFiles(ambiguityDB) }
        let ambiguous = try runSounding(arguments: [
            "ingest",
            "https://user:pass@example.test/live.m3u8?token=synthetic-secret",
            "--stream", "Main",
            "--db", ambiguityDB.path,
            "--max-chunks", "1",
        ])
        XCTAssertNotEqual(ambiguous.exitCode, 0, ambiguous.diagnosticSummary)
        XCTAssertEqual(ambiguous.stdoutLineCount, 0, ambiguous.diagnosticSummary)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ambiguityDB.path), ambiguous.diagnosticSummary)
        let ambiguousStderr = String(data: ambiguous.stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(
            ambiguousStderr.contains("either --stream or positional source"),
            ambiguous.diagnosticSummary)
        assertSanitized(ambiguousStderr, forbiddenLiteral: "user:pass")
        assertSanitized(ambiguousStderr, forbiddenLiteral: "synthetic-secret")
        assertSanitized(ambiguousStderr, forbiddenLiteral: ambiguityDB.path)

        let stateDB = temporaryDatabaseURL(secretComponent: "managed-state-token=synthetic-secret")
        defer { removeDatabaseFiles(stateDB) }
        let add = try addManagedStream(dbURL: stateDB, name: "Managed")
        XCTAssertEqual(add.exitCode, 0, add.diagnosticSummary)

        let unknown = try runSounding(arguments: [
            "ingest", "--stream", "Missing", "--db", stateDB.path, "--max-chunks", "1",
        ])
        XCTAssertNotEqual(unknown.exitCode, 0, unknown.diagnosticSummary)
        XCTAssertTrue(
            (String(data: unknown.stderr, encoding: .utf8) ?? "").contains(
                "stream reference was not found"),
            unknown.diagnosticSummary)

        let pause = try runSounding(arguments: ["streams", "pause", "--db", stateDB.path, "1"])
        XCTAssertEqual(pause.exitCode, 0, pause.diagnosticSummary)
        let paused = try runSounding(arguments: [
            "ingest", "--stream", "Managed", "--db", stateDB.path, "--max-chunks", "1",
        ])
        XCTAssertNotEqual(paused.exitCode, 0, paused.diagnosticSummary)
        XCTAssertTrue(
            (String(data: paused.stderr, encoding: .utf8) ?? "").contains("status=paused"),
            paused.diagnosticSummary)

        let resume = try runSounding(arguments: ["streams", "resume", "--db", stateDB.path, "1"])
        XCTAssertEqual(resume.exitCode, 0, resume.diagnosticSummary)
        let remove = try runSounding(arguments: ["streams", "remove", "--db", stateDB.path, "1"])
        XCTAssertEqual(remove.exitCode, 0, remove.diagnosticSummary)
        let removed = try runSounding(arguments: [
            "ingest", "--stream", "1", "--db", stateDB.path, "--max-chunks", "1",
        ])
        XCTAssertNotEqual(removed.exitCode, 0, removed.diagnosticSummary)
        XCTAssertTrue(
            (String(data: removed.stderr, encoding: .utf8) ?? "").contains("status=removed"),
            removed.diagnosticSummary)

        let database = try DatabaseQueue(path: stateDB.path)
        let runCount = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_runs")
        }
        XCTAssertEqual(runCount, 0)
    }

    func testManagedActiveStreamIngestReusesStreamRowAcrossRepeatedRuns() throws {
        let dbURL = temporaryDatabaseURL(secretComponent: "managed-active")
        defer { removeDatabaseFiles(dbURL) }
        let fixture =
            packageRootURL
            .appendingPathComponent("Tests/SoundingKitTests/Fixtures/HLS/manifest-scte35.m3u8")
        let add = try addManagedStream(dbURL: dbURL, name: "Managed", source: fixture.path)
        XCTAssertEqual(add.exitCode, 0, add.diagnosticSummary)

        for reference in ["Managed", "1"] {
            let ingest = try runSounding(
                arguments: [
                    "ingest",
                    "--stream", reference,
                    "--db", dbURL.path,
                    "--max-chunks", "1",
                ],
                environment: [
                    "SOUNDING_DETERMINISTIC_ML": "1",
                    "SOUNDING_ACOUSTID_STUB": "success",
                ]
            )
            XCTAssertEqual(ingest.exitCode, 0, ingest.diagnosticSummary)
            let stdout = String(data: ingest.stdout, encoding: .utf8) ?? ""
            XCTAssertTrue(stdout.contains("stream=1"), ingest.diagnosticSummary)
            XCTAssertTrue(stdout.contains("chunks=1"), ingest.diagnosticSummary)
            assertSanitized(stdout, forbiddenLiteral: fixture.path)
            assertSanitized(stdout, forbiddenLiteral: dbURL.path)
        }

        let database = try DatabaseQueue(path: dbURL.path)
        let row = try database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT (SELECT COUNT(*) FROM streams) AS streams,
                           (SELECT COUNT(*) FROM ingest_runs) AS runs,
                           (SELECT COUNT(*) FROM ingest_runs WHERE stream_id = 1 AND status = 'completed') AS linked_runs,
                           (SELECT COUNT(*) FROM ingest_chunks) AS chunks
                    """
            )
        }
        XCTAssertEqual(row?["streams"] as Int?, 1)
        XCTAssertEqual(row?["runs"] as Int?, 2)
        XCTAssertEqual(row?["linked_runs"] as Int?, 2)
        XCTAssertEqual(row?["chunks"] as Int?, 2)
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
        assertSanitized(
            stderr, forbiddenLiteral: "/tmp/sounding-missing-audio-token=synthetic-secret.wav")
        assertSanitized(stderr, forbiddenLiteral: dbURL.path)
    }

    private func addManagedStream(
        dbURL: URL,
        name: String,
        source: String = "https://example.test/live.m3u8?token=synthetic-secret",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CLIResult {
        let add = try runSounding(
            arguments: [
                "streams", "add", "--db", dbURL.path, name,
                "https://example.test/live.m3u8?token=synthetic-secret", "--stream-type", "hls",
            ], file: file, line: line)
        guard add.exitCode == 0 else { return add }
        if source != "https://example.test/live.m3u8?token=synthetic-secret" {
            let database = try DatabaseQueue(path: dbURL.path)
            try database.write { db in
                try db.execute(
                    sql: "UPDATE streams SET source = ?, stream_type = 'hls' WHERE name = ?",
                    arguments: [source, name]
                )
            }
        }
        return add
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

    private func jsonObject(
        from data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            XCTFail("Expected top-level JSON object", file: file, line: line)
            throw CLIError.invalidJSON
        }
        return dictionary
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
