import Foundation
import GRDB
import XCTest

@testable import SoundingKit

final class StreamIngestPipelineSongTests: XCTestCase {
    func testAdjacentSameFingerprintChunksMergeAndChangedFingerprintSplitsPlay() async throws {
        let temporary = try TemporarySoundingDatabase()
        let fingerprinter = StubFingerprinter(outputs: [
            0: Self.fingerprintOutput(hash: "same-song", start: 0, end: 2),
            1: Self.fingerprintOutput(hash: "same-song", start: 2, end: 4),
            2: Self.fingerprintOutput(hash: "different-song", start: 4, end: 6),
        ])
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: FakeSongDecoder(chunks: [
                Self.chunk(sequence: 0), Self.chunk(sequence: 1), Self.chunk(sequence: 2),
            ]),
            transcriber: FakeSongTranscriber(),
            diarizer: FakeSongDiarizer(),
            fingerprinter: fingerprinter
        )

        let result = try await pipeline.run(
            source: "https://user:pass@example.test/live.m3u8?token=secret#frag",
            streamType: .hls,
            maxChunks: 3
        )

        XCTAssertEqual(result.processedChunks, 3)
        XCTAssertEqual(result.diagnostics, [])
        let rows = try temporary.database.read { db in
            try (
                fingerprints: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audio_fingerprints"),
                songs: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM songs"),
                plays: Row.fetchAll(
                    db,
                    sql: """
                        SELECT songs.song_key, first_chunk.sequence AS first_sequence,
                               last_chunk.sequence AS last_sequence, song_plays.start_seconds,
                               song_plays.end_seconds
                        FROM song_plays
                        JOIN songs ON songs.id = song_plays.song_id
                        JOIN ingest_chunks AS first_chunk ON first_chunk.id = song_plays.first_chunk_id
                        JOIN ingest_chunks AS last_chunk ON last_chunk.id = song_plays.last_chunk_id
                        ORDER BY song_plays.start_seconds
                        """)
            )
        }
        XCTAssertEqual(rows.fingerprints, 3)
        XCTAssertEqual(rows.songs, 2)
        XCTAssertEqual(rows.plays.count, 2)
        XCTAssertEqual(rows.plays[0]["song_key"] as String, "fingerprint:same-song")
        XCTAssertEqual(rows.plays[0]["first_sequence"] as Int, 0)
        XCTAssertEqual(rows.plays[0]["last_sequence"] as Int, 1)
        XCTAssertEqual(rows.plays[0]["start_seconds"] as Double, 0)
        XCTAssertEqual(rows.plays[0]["end_seconds"] as Double, 4)
        XCTAssertEqual(rows.plays[1]["song_key"] as String, "fingerprint:different-song")
        XCTAssertEqual(rows.plays[1]["first_sequence"] as Int, 2)
        XCTAssertEqual(rows.plays[1]["last_sequence"] as Int, 2)
    }

    func testAcoustIDEnrichmentPersistsKnownSongCacheAndKeepsFingerprintSongKey() async throws {
        let temporary = try TemporarySoundingDatabase()
        let cache = AcoustIDLookupCache(database: temporary.database)
        let lookup = CountingSongLookup(outcome: .matched(Self.lookupMatch))
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: FakeSongDecoder(chunks: [Self.chunk(sequence: 0), Self.chunk(sequence: 1)]),
            transcriber: FakeSongTranscriber(),
            diarizer: FakeSongDiarizer(),
            fingerprinter: StubFingerprinter(outputs: [
                0: Self.fingerprintOutput(hash: "enriched-song", start: 0, end: 2),
                1: Self.fingerprintOutput(hash: "enriched-song", start: 2, end: 4),
            ]),
            fingerprintEnricher: AcoustIDAudioFingerprintEnricher(
                cache: cache,
                lookup: lookup,
                now: { "2026-05-01T12:30:00Z" }
            )
        )

        let result = try await pipeline.run(
            source: "https://example.test/live", streamType: .hls, maxChunks: 2)

        XCTAssertEqual(result.processedChunks, 2)
        XCTAssertEqual(result.diagnostics, [])
        let lookupCount = await lookup.invocationCount
        XCTAssertEqual(
            lookupCount, 1, "Second adjacent chunk should use the persisted lookup cache.")
        let rows = try temporary.database.read { db in
            try (
                songs: Row.fetchAll(
                    db,
                    sql: """
                        SELECT song_key, title, artist, album, isrc, display_name, is_unknown
                        FROM songs
                        """),
                plays: Row.fetchAll(
                    db,
                    sql: """
                        SELECT first_chunk.sequence AS first_sequence, last_chunk.sequence AS last_sequence,
                               song_plays.start_seconds, song_plays.end_seconds, song_plays.source
                        FROM song_plays
                        JOIN ingest_chunks AS first_chunk ON first_chunk.id = song_plays.first_chunk_id
                        JOIN ingest_chunks AS last_chunk ON last_chunk.id = song_plays.last_chunk_id
                        """),
                cacheRows: Row.fetchAll(
                    db,
                    sql:
                        "SELECT fingerprint_hash, title, artist, response_json FROM acoustid_lookup_cache"
                )
            )
        }
        XCTAssertEqual(rows.songs.count, 1)
        XCTAssertEqual(rows.songs[0]["song_key"] as String, "fingerprint:enriched-song")
        XCTAssertEqual(rows.songs[0]["title"] as String, "Pipeline Lookup Title")
        XCTAssertEqual(rows.songs[0]["artist"] as String, "Pipeline Lookup Artist")
        XCTAssertEqual(rows.songs[0]["album"] as String, "Pipeline Lookup Album")
        XCTAssertEqual(rows.songs[0]["isrc"] as String, "US-SND-26-00003")
        XCTAssertEqual(
            rows.songs[0]["display_name"] as String,
            "Pipeline Lookup Title — Pipeline Lookup Artist")
        XCTAssertEqual(rows.songs[0]["is_unknown"] as Bool, false)
        XCTAssertEqual(rows.plays.count, 1)
        XCTAssertEqual(rows.plays[0]["first_sequence"] as Int, 0)
        XCTAssertEqual(rows.plays[0]["last_sequence"] as Int, 1)
        XCTAssertEqual(rows.plays[0]["start_seconds"] as Double, 0)
        XCTAssertEqual(rows.plays[0]["end_seconds"] as Double, 4)
        XCTAssertEqual(rows.plays[0]["source"] as String, "test_fingerprint")
        XCTAssertEqual(rows.cacheRows.count, 1)
        XCTAssertEqual(rows.cacheRows[0]["fingerprint_hash"] as String, "enriched-song")
        XCTAssertEqual(rows.cacheRows[0]["title"] as String, "Pipeline Lookup Title")
    }

    func testAcoustIDLookupFailurePersistsBaseFingerprintSongPlayAndRedactedDiagnostic()
        async throws
    {
        let temporary = try TemporarySoundingDatabase()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: FakeSongDecoder(chunks: [Self.chunk(sequence: 0)]),
            transcriber: FakeSongTranscriber(),
            diarizer: FakeSongDiarizer(),
            fingerprinter: StubFingerprinter(outputs: [
                0: Self.fingerprintOutput(hash: "fallback-song", start: 0, end: 2)
            ]),
            fingerprintEnricher: AcoustIDAudioFingerprintEnricher(
                cache: AcoustIDLookupCache(database: temporary.database),
                lookup: CountingSongLookup(
                    outcome: .transientFailure(
                        reason:
                            "timeout for https://user:pass@example.test/acoustid?api_key=secret path=/tmp/acoustid-token=secret.json"
                    )
                )
            )
        )

        let result = try await pipeline.run(
            source: "https://example.test/live", streamType: .hls, maxChunks: 1)

        XCTAssertEqual(result.processedChunks, 1)
        XCTAssertEqual(result.diagnostics.map(\.phase), [.fingerprint])
        XCTAssertEqual(result.diagnostics.map(\.reason), ["acoustid-transient-failure"])
        let evidence = try temporary.database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT songs.song_key AS song_key, songs.is_unknown AS is_unknown,
                           (SELECT COUNT(*) FROM audio_fingerprints) AS fingerprints,
                           (SELECT COUNT(*) FROM song_plays) AS song_plays,
                           (SELECT COUNT(*) FROM acoustid_lookup_cache) AS cache_rows,
                           ingest_diagnostics.reason AS reason,
                           ingest_diagnostics.context_json AS context
                    FROM songs
                    JOIN ingest_diagnostics ON ingest_diagnostics.reason = 'acoustid-transient-failure'
                    LIMIT 1
                    """)
        }
        XCTAssertEqual(evidence?["song_key"] as String?, "fingerprint:fallback-song")
        XCTAssertEqual(evidence?["is_unknown"] as Bool?, true)
        XCTAssertEqual(evidence?["fingerprints"] as Int?, 1)
        XCTAssertEqual(evidence?["song_plays"] as Int?, 1)
        XCTAssertEqual(evidence?["cache_rows"] as Int?, 0)
        XCTAssertEqual(evidence?["reason"] as String?, "acoustid-transient-failure")
        let context: String = evidence?["context"] ?? ""
        XCTAssertTrue(context.contains("[redacted-path]"), context)
        Self.assertNoForbiddenLiterals(
            in: context,
            forbidden: [
                "user:pass", "api_key=secret", "token=secret", "/tmp/acoustid-token=secret.json",
            ]
        )
    }

    func testFingerprintFailurePersistsRedactedDiagnosticAndDoesNotAbortTranscriptPersistence()
        async throws
    {
        let temporary = try TemporarySoundingDatabase()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: FakeSongDecoder(chunks: [Self.chunk(sequence: 0)]),
            transcriber: FakeSongTranscriber(segmentsBySequence: [
                0: [Self.segment(text: "fingerprint failure still leaves transcript searchable")]
            ]),
            diarizer: FakeSongDiarizer(),
            fingerprinter: StubFingerprinter(errors: [
                0:
                    "fingerprint failed for https://user:pass@example.test/live?token=synthetic-secret path=/tmp/fp-token=synthetic-secret.wav"
            ])
        )

        let result = try await pipeline.run(
            source: "https://user:pass@example.test/live.m3u8?token=synthetic-secret#frag",
            streamType: .hls,
            maxChunks: 1
        )

        XCTAssertEqual(result.processedChunks, 1)
        XCTAssertEqual(result.diagnostics.map(\.phase), [.fingerprint])
        XCTAssertEqual(result.diagnostics.map(\.reason), ["fingerprint-failed"])
        let evidence = try temporary.database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT ingest_runs.status AS status,
                           (SELECT COUNT(*) FROM transcript_segments) AS segments,
                           (SELECT COUNT(*) FROM audio_fingerprints) AS fingerprints,
                           (SELECT COUNT(*) FROM song_plays) AS song_plays,
                           ingest_diagnostics.phase AS phase,
                           ingest_diagnostics.reason AS reason,
                           ingest_diagnostics.context_json AS context
                    FROM ingest_runs
                    JOIN ingest_diagnostics ON ingest_diagnostics.run_id = ingest_runs.id
                    """)
        }
        XCTAssertEqual(evidence?["status"] as String?, "completed")
        XCTAssertEqual(evidence?["segments"] as Int?, 1)
        XCTAssertEqual(evidence?["fingerprints"] as Int?, 0)
        XCTAssertEqual(evidence?["song_plays"] as Int?, 0)
        XCTAssertEqual(evidence?["phase"] as String?, "fingerprint")
        XCTAssertEqual(evidence?["reason"] as String?, "fingerprint-failed")
        let context: String = evidence?["context"] ?? ""
        XCTAssertTrue(context.contains("[redacted-path]"), context)
        Self.assertNoForbiddenLiterals(
            in: context,
            forbidden: [
                "user:pass", "synthetic-secret", "token=synthetic-secret",
                "/tmp/fp-token=synthetic-secret.wav",
            ]
        )

        let search = TranscriptQuery(database: temporary.database)
        XCTAssertEqual(
            try search.count(phrase: "failure still leaves transcript").first?.occurrenceCount, 1)
    }

    func testMalformedFingerprintOutputIsDiagnosedBeforePersistence() async throws {
        let temporary = try TemporarySoundingDatabase()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: FakeSongDecoder(chunks: [Self.chunk(sequence: 0)]),
            transcriber: FakeSongTranscriber(),
            diarizer: FakeSongDiarizer(),
            fingerprinter: StubFingerprinter(outputs: [
                0: AudioFingerprintResult(fingerprints: [
                    AudioFingerprintDraft(
                        algorithm: "",
                        algorithmVersion: "1",
                        fingerprint: "bad",
                        fingerprintHash: "bad",
                        startSeconds: 0,
                        endSeconds: 1
                    )
                ])
            ])
        )

        let result = try await pipeline.run(
            source: "https://example.test/live", streamType: .icecast, maxChunks: 1)

        XCTAssertEqual(result.processedChunks, 1)
        XCTAssertEqual(result.diagnostics.map(\.phase), [.fingerprint])
        XCTAssertEqual(result.diagnostics.map(\.reason), ["malformed-fingerprint-output"])
        let counts = try temporary.database.read { db in
            try [
                "audio_fingerprints": Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM audio_fingerprints"),
                "song_plays": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song_plays"),
                "diagnostics": Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM ingest_diagnostics WHERE phase = 'fingerprint'"),
            ]
        }
        XCTAssertEqual(counts, ["audio_fingerprints": 0, "song_plays": 0, "diagnostics": 1])
    }

    func testEmptyAudioChunkDoesNotInvokeFingerprinterAndKeepsDecodeDiagnostic() async throws {
        let temporary = try TemporarySoundingDatabase()
        let invocations = FingerprintInvocations()
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: FakeSongDecoder(chunks: [Self.chunk(sequence: 0, audio: Data())]),
            transcriber: FakeSongTranscriber(),
            diarizer: FakeSongDiarizer(),
            fingerprinter: RecordingFingerprinter(invocations: invocations)
        )

        let result = try await pipeline.run(
            source: "https://example.test/live", streamType: .icecast, maxChunks: 1)

        XCTAssertEqual(result.processedChunks, 1)
        XCTAssertEqual(result.diagnostics.map(\.phase), [.decode])
        let invocationCount = await invocations.count
        XCTAssertEqual(invocationCount, 0)
        let counts = try temporary.database.read { db in
            try [
                "audio_fingerprints": Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM audio_fingerprints"),
                "diagnostics": Int.fetchOne(
                    db,
                    sql:
                        "SELECT COUNT(*) FROM ingest_diagnostics WHERE phase = 'decode' AND reason = 'empty-audio-chunk'"
                ),
            ]
        }
        XCTAssertEqual(counts, ["audio_fingerprints": 0, "diagnostics": 1])
    }

    func testManagedStreamRunReusesExistingStreamRowAcrossRuns() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let record = try registry.add(
            name: "Managed Main",
            streamType: "hls",
            source: "https://example.test/live.m3u8?token=synthetic-secret"
        )
        let pipeline = StreamIngestPipeline(
            database: temporary.database,
            decoder: FakeSongDecoder(chunks: [Self.chunk(sequence: 0)]),
            transcriber: FakeSongTranscriber(),
            diarizer: FakeSongDiarizer()
        )

        let first = try await pipeline.run(
            streamID: record.id,
            source: record.sourceDescription,
            streamType: .hls,
            maxChunks: 1
        )
        let second = try await pipeline.run(
            streamID: record.id,
            source: record.sourceDescription,
            streamType: .hls,
            maxChunks: 1
        )

        XCTAssertEqual(first.streamID, record.id)
        XCTAssertEqual(second.streamID, record.id)
        let rows = try temporary.database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT (SELECT COUNT(*) FROM streams) AS streams,
                           (SELECT COUNT(*) FROM ingest_runs) AS runs,
                           (SELECT COUNT(DISTINCT stream_id) FROM ingest_runs) AS run_streams,
                           (SELECT COUNT(*) FROM ingest_runs WHERE stream_id = ?) AS linked_runs
                    """,
                arguments: [record.id]
            )
        }
        XCTAssertEqual(rows?["streams"] as Int?, 1)
        XCTAssertEqual(rows?["runs"] as Int?, 2)
        XCTAssertEqual(rows?["run_streams"] as Int?, 1)
        XCTAssertEqual(rows?["linked_runs"] as Int?, 2)
    }

    private static func fingerprintOutput(hash: String, start: Double, end: Double)
        -> AudioFingerprintResult
    {
        AudioFingerprintResult(
            fingerprints: [
                AudioFingerprintDraft(
                    algorithm: "test-deterministic",
                    algorithmVersion: "1",
                    fingerprint: "fp:\(hash)",
                    fingerprintHash: hash,
                    startSeconds: start,
                    endSeconds: end,
                    confidence: 0.99
                )
            ],
            songPlays: [
                SongPlayDraft(
                    song: UnresolvedSongDraft(
                        songKey: "fingerprint:\(hash)",
                        displayName: "Fixture song \(hash)",
                        isUnknown: true
                    ),
                    startSeconds: start,
                    endSeconds: end,
                    confidence: 0.99,
                    source: "test_fingerprint"
                )
            ]
        )
    }

    private static var lookupMatch: AcoustIDMatch {
        AcoustIDMatch(
            acoustID: "acoustid-pipeline",
            recordingID: "recording-pipeline",
            title: "Pipeline Lookup Title",
            artist: "Pipeline Lookup Artist",
            album: "Pipeline Lookup Album",
            isrc: "US-SND-26-00003",
            durationSeconds: 2,
            score: 0.98,
            responseJSON: #"{"status":"ok","source":"pipeline"}"#
        )
    }

    private static func chunk(sequence: Int, audio: Data = Data([0x01, 0x02, 0x03]))
        -> DecodedAudioChunk
    {
        DecodedAudioChunk(
            sequence: sequence,
            segmentURI: "https://user:pass@example.test/segment-\(sequence).ts?token=secret#frag",
            audio: audio,
            startSeconds: Double(sequence) * 2.0,
            endSeconds: Double(sequence + 1) * 2.0,
            startedAt: "2026-05-01T12:00:0\(sequence)Z",
            endedAt: "2026-05-01T12:00:0\(sequence + 1)Z"
        )
    }

    private static func segment(text: String) -> TranscriptSegmentDraft {
        TranscriptSegmentDraft(
            sequence: 0,
            speakerLabel: "song-speaker",
            startSeconds: 0,
            endSeconds: 2,
            text: text,
            confidence: 0.9,
            words: text.split(separator: " ").enumerated().map { index, word in
                TranscriptWordDraft(
                    sequence: index,
                    speakerLabel: "song-speaker",
                    startSeconds: Double(index) * 0.2,
                    endSeconds: Double(index + 1) * 0.2,
                    text: String(word),
                    confidence: 0.9
                )
            }
        )
    }

    private static func assertNoForbiddenLiterals(
        in text: String,
        forbidden literals: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for literal in literals where !literal.isEmpty {
            XCTAssertFalse(
                text.contains(literal),
                "Expected redacted text to omit forbidden literal '\(literal)', got: \(text)",
                file: file,
                line: line
            )
        }
    }
}

private struct FakeSongDecoder: AudioDecoding {
    var chunks: [DecodedAudioChunk]

    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        chunks
    }
}

private struct FakeSongTranscriber: MLTranscription {
    var segmentsBySequence: [Int: [TranscriptSegmentDraft]] = [:]

    func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
        segmentsBySequence[chunk.sequence] ?? []
    }
}

private struct FakeSongDiarizer: SpeakerDiarization {
    func diarize(
        _ chunk: DecodedAudioChunk,
        transcriptSegments: [TranscriptSegmentDraft]
    ) async throws -> [SpeakerTurnDraft] {
        []
    }
}

private struct StubFingerprinter: AudioFingerprinting {
    var outputs: [Int: AudioFingerprintResult] = [:]
    var errors: [Int: String] = [:]

    func fingerprint(
        _ chunk: DecodedAudioChunk,
        request: AudioFingerprintRequest
    ) async throws -> AudioFingerprintResult {
        if let error = errors[chunk.sequence] {
            throw StubFingerprintError(description: error)
        }
        return outputs[chunk.sequence] ?? AudioFingerprintResult()
    }
}

private struct StubFingerprintError: Error, CustomStringConvertible {
    var description: String
}

private struct RecordingFingerprinter: AudioFingerprinting {
    let invocations: FingerprintInvocations

    func fingerprint(
        _ chunk: DecodedAudioChunk,
        request: AudioFingerprintRequest
    ) async throws -> AudioFingerprintResult {
        await invocations.record()
        return AudioFingerprintResult()
    }
}

private struct CountingSongLookup: AcoustIDLookuping {
    let outcome: AcoustIDLookupOutcome
    let invocations = LookupInvocations()

    var invocationCount: Int {
        get async { await invocations.count }
    }

    func lookup(_ request: AcoustIDLookupRequest) async -> AcoustIDLookupOutcome {
        await invocations.record()
        return outcome
    }
}

private actor LookupInvocations {
    private var value = 0

    var count: Int { value }

    func record() {
        value += 1
    }
}

private actor FingerprintInvocations {
    private var value = 0

    var count: Int { value }

    func record() {
        value += 1
    }
}
