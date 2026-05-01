import GRDB
import XCTest
@testable import SoundingKit

final class AcoustIDEnrichmentTests: XCTestCase {
    func testCacheMissLookupMatchEnrichesSongAndPersistsSuccessfulCacheRow() async throws {
        let temporary = try TemporarySoundingDatabase()
        let cache = AcoustIDLookupCache(database: temporary.database)
        let lookup = SpyAcoustIDLookup(outcome: .matched(.matchedFixture))
        let enricher = AcoustIDAudioFingerprintEnricher(
            cache: cache,
            lookup: lookup,
            now: { "2026-05-01T10:15:00Z" }
        )

        let result = await enricher.enrich(
            Self.baseResult(hash: "abc123"),
            chunk: Self.chunk(sequence: 0),
            request: Self.request
        )

        XCTAssertEqual(result.diagnostics, [])
        let lookupCount = await lookup.invocationCount
        XCTAssertEqual(lookupCount, 1)
        let song = try XCTUnwrap(result.fingerprintResult.songPlays.first?.song)
        XCTAssertEqual(song.songKey, "fingerprint:abc123")
        XCTAssertEqual(song.title, "Lookup Title")
        XCTAssertEqual(song.artist, "Lookup Artist")
        XCTAssertEqual(song.album, "Lookup Album")
        XCTAssertEqual(song.isrc, "US-SND-26-00001")
        XCTAssertEqual(song.displayName, "Lookup Title — Lookup Artist")
        XCTAssertFalse(song.isUnknown)

        let cacheRow = try XCTUnwrap(
            try cache.fetch(
                identity: AcoustIDLookupCacheIdentity(
                    algorithm: "test-deterministic",
                    algorithmVersion: "1",
                    fingerprintHash: "abc123"
                )
            )
        )
        XCTAssertEqual(cacheRow.title, "Lookup Title")
        XCTAssertEqual(cacheRow.artist, "Lookup Artist")
        XCTAssertEqual(cacheRow.responseJSON, #"{"status":"ok"}"#)
        XCTAssertEqual(cacheRow.createdAt, "2026-05-01T10:15:00Z")
    }

    func testCacheHitEnrichesSongWithoutInvokingLookupClient() async throws {
        let temporary = try TemporarySoundingDatabase()
        let cache = AcoustIDLookupCache(database: temporary.database)
        try cache.upsert(
            AcoustIDLookupCacheEntry(
                identity: AcoustIDLookupCacheIdentity(
                    algorithm: "test-deterministic",
                    algorithmVersion: "1",
                    fingerprintHash: "cached123"
                ),
                title: "Cached Title",
                artist: "Cached Artist",
                isrc: "US-SND-26-00002",
                responseJSON: #"{"status":"ok","source":"cache"}"#,
                fetchedAt: "2026-05-01T10:00:00Z"
            )
        )
        let lookup = SpyAcoustIDLookup(outcome: .transientFailure(reason: "network should not be called"))
        let enricher = AcoustIDAudioFingerprintEnricher(cache: cache, lookup: lookup)

        let result = await enricher.enrich(
            Self.baseResult(hash: "cached123"),
            chunk: Self.chunk(sequence: 1),
            request: Self.request
        )

        let lookupCount = await lookup.invocationCount
        XCTAssertEqual(lookupCount, 0)
        XCTAssertEqual(result.diagnostics, [])
        let song = try XCTUnwrap(result.fingerprintResult.songPlays.first?.song)
        XCTAssertEqual(song.songKey, "fingerprint:cached123")
        XCTAssertEqual(song.title, "Cached Title")
        XCTAssertEqual(song.artist, "Cached Artist")
        XCTAssertEqual(song.isrc, "US-SND-26-00002")
        XCTAssertFalse(song.isUnknown)
    }

    func testLookupFailureOutcomesRemainNonFatalAndRedacted() async throws {
        let cases: [(AcoustIDLookupOutcome, String)] = [
            (.disabled(reason: "missing api_key=super-secret"), "acoustid-lookup-disabled"),
            (.notFound(reason: "no results for https://user:pass@example.test/lookup?token=secret"), "acoustid-not-found"),
            (.transientFailure(reason: "timeout at /tmp/acoustid-token=secret.json"), "acoustid-transient-failure"),
            (.rateLimited(retryAfterSeconds: 30), "acoustid-rate-limited"),
            (.malformedResponse(reason: "body from /tmp/acoustid-token=secret.json"), "acoustid-malformed-response"),
        ]

        for (outcome, expectedReason) in cases {
            let temporary = try TemporarySoundingDatabase()
            let enricher = AcoustIDAudioFingerprintEnricher(
                cache: AcoustIDLookupCache(database: temporary.database),
                lookup: SpyAcoustIDLookup(outcome: outcome)
            )

            let result = await enricher.enrich(
                Self.baseResult(hash: "failure-\(expectedReason)"),
                chunk: Self.chunk(sequence: 2),
                request: Self.request
            )

            XCTAssertEqual(result.fingerprintResult, Self.baseResult(hash: "failure-\(expectedReason)"))
            XCTAssertEqual(result.diagnostics.map(\.reason), [expectedReason])
            let context = String(describing: result.diagnostics.first?.context ?? [:])
            XCTAssertFalse(context.contains("super-secret"), context)
            XCTAssertFalse(context.contains("user:pass"), context)
            XCTAssertFalse(context.contains("token=secret"), context)
            XCTAssertFalse(context.contains("/tmp/acoustid-token=secret.json"), context)
        }
    }

    func testMalformedMatchedResponseDoesNotEnrichOrWriteCache() async throws {
        let temporary = try TemporarySoundingDatabase()
        let cache = AcoustIDLookupCache(database: temporary.database)
        let enricher = AcoustIDAudioFingerprintEnricher(
            cache: cache,
            lookup: SpyAcoustIDLookup(outcome: .matched(AcoustIDMatch()))
        )

        let result = await enricher.enrich(
            Self.baseResult(hash: "empty-match"),
            chunk: Self.chunk(sequence: 3),
            request: Self.request
        )

        XCTAssertEqual(result.fingerprintResult, Self.baseResult(hash: "empty-match"))
        XCTAssertEqual(result.diagnostics.map(\.reason), ["acoustid-malformed-response"])
        let cacheCount = try temporary.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM acoustid_lookup_cache")
        }
        XCTAssertEqual(cacheCount, 0)
    }

    func testCacheWriteFailureStillReturnsEnrichedSongWithDiagnostic() async throws {
        let cache = FailingAcoustIDCache(writeError: "write failed path=/tmp/acoustid-token=secret.json")
        let enricher = AcoustIDAudioFingerprintEnricher(
            cache: cache,
            lookup: SpyAcoustIDLookup(outcome: .matched(.matchedFixture))
        )

        let result = await enricher.enrich(
            Self.baseResult(hash: "write-failure"),
            chunk: Self.chunk(sequence: 4),
            request: Self.request
        )

        let song = try XCTUnwrap(result.fingerprintResult.songPlays.first?.song)
        XCTAssertEqual(song.title, "Lookup Title")
        XCTAssertFalse(song.isUnknown)
        XCTAssertEqual(result.diagnostics.map(\.reason), ["acoustid-cache-write-failed"])
        let context = String(describing: result.diagnostics.first?.context ?? [:])
        XCTAssertTrue(context.contains("[redacted-path]"), context)
        XCTAssertFalse(context.contains("token=secret"), context)
    }

    func testEmptyResultDoesNotInvokeCacheOrLookup() async {
        let cache = RecordingAcoustIDCache()
        let lookup = SpyAcoustIDLookup(outcome: .matched(.matchedFixture))
        let enricher = AcoustIDAudioFingerprintEnricher(cache: cache, lookup: lookup)

        let result = await enricher.enrich(AudioFingerprintResult(), chunk: Self.chunk(sequence: 5), request: Self.request)

        XCTAssertEqual(result.fingerprintResult, AudioFingerprintResult())
        XCTAssertEqual(result.diagnostics, [])
        XCTAssertEqual(cache.fetchCount, 0)
        let lookupCount = await lookup.invocationCount
        XCTAssertEqual(lookupCount, 0)
    }

    private static var request: AudioFingerprintRequest {
        AudioFingerprintRequest(source: "https://example.test/live", streamType: .hls, streamID: 1, runID: 1)
    }

    private static func baseResult(hash: String) -> AudioFingerprintResult {
        AudioFingerprintResult(
            fingerprints: [
                AudioFingerprintDraft(
                    algorithm: "test-deterministic",
                    algorithmVersion: "1",
                    fingerprint: "fp:\(hash)",
                    fingerprintHash: hash,
                    startSeconds: 0,
                    endSeconds: 2,
                    confidence: 0.9
                )
            ],
            songPlays: [
                SongPlayDraft(
                    song: UnresolvedSongDraft(
                        songKey: "fingerprint:\(hash)",
                        displayName: "Unknown fixture \(hash)",
                        isUnknown: true
                    ),
                    startSeconds: 0,
                    endSeconds: 2,
                    confidence: 0.9,
                    source: "test_fingerprint"
                )
            ]
        )
    }

    private static func chunk(sequence: Int) -> DecodedAudioChunk {
        DecodedAudioChunk(
            sequence: sequence,
            segmentURI: "https://user:pass@example.test/segment-\(sequence).ts?token=secret#frag",
            audio: Data([0x01, 0x02, 0x03]),
            startSeconds: 0,
            endSeconds: 2,
            startedAt: "2026-05-01T12:00:00Z",
            endedAt: "2026-05-01T12:00:02Z"
        )
    }
}

private extension AcoustIDMatch {
    static var matchedFixture: AcoustIDMatch {
        AcoustIDMatch(
            acoustID: "acoustid-fixture",
            recordingID: "recording-fixture",
            title: "Lookup Title",
            artist: "Lookup Artist",
            album: "Lookup Album",
            isrc: "US-SND-26-00001",
            durationSeconds: 2,
            score: 0.97,
            responseJSON: #"{"status":"ok"}"#
        )
    }
}

private actor LookupInvocationCounter {
    private var value = 0
    var count: Int { value }
    func record() { value += 1 }
}

private struct SpyAcoustIDLookup: AcoustIDLookuping {
    let outcome: AcoustIDLookupOutcome
    let counter = LookupInvocationCounter()

    var invocationCount: Int {
        get async { await counter.count }
    }

    func lookup(_ request: AcoustIDLookupRequest) async -> AcoustIDLookupOutcome {
        await counter.record()
        return outcome
    }
}

private final class RecordingAcoustIDCache: AcoustIDLookupCaching, @unchecked Sendable {
    private(set) var fetchCount = 0
    private(set) var upsertCount = 0

    func fetch(identity: AcoustIDLookupCacheIdentity) throws -> AcoustIDLookupCacheRow? {
        fetchCount += 1
        return nil
    }

    func upsert(_ entry: AcoustIDLookupCacheEntry) throws {
        upsertCount += 1
    }
}

private final class FailingAcoustIDCache: AcoustIDLookupCaching, @unchecked Sendable {
    var writeError: String

    init(writeError: String) {
        self.writeError = writeError
    }

    func fetch(identity: AcoustIDLookupCacheIdentity) throws -> AcoustIDLookupCacheRow? {
        nil
    }

    func upsert(_ entry: AcoustIDLookupCacheEntry) throws {
        throw FailingCacheError(description: writeError)
    }
}

private struct FailingCacheError: Error, CustomStringConvertible {
    var description: String
}
