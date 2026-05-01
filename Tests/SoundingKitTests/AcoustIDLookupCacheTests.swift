import GRDB
import XCTest
@testable import SoundingKit

final class AcoustIDLookupCacheTests: XCTestCase {
    func testUpsertAndFetchSuccessfulLookupByFingerprintIdentity() throws {
        let temporary = try TemporarySoundingDatabase()
        let cache = AcoustIDLookupCache(database: temporary.database)

        try cache.upsert(
            .fixture(
                acoustID: "acoustid-001",
                recordingID: "recording-001",
                title: "Fixture Song",
                artist: "Sounding Fixtures",
                album: "Integration Proofs",
                isrc: "US-S01-26-00001",
                durationSeconds: 12.5,
                score: 0.98,
                responseJSON: #"{"status":"ok","results":[{"id":"acoustid-001"}]}"#,
                fetchedAt: "2026-05-01T10:00:00Z"
            )
        )

        let row = try cache.fetch(
            identity: AcoustIDLookupCacheIdentity(
                algorithm: "chromaprint",
                algorithmVersion: "1.5.1",
                fingerprintHash: "fp-hash-001"
            )
        )

        XCTAssertEqual(row?.identity.algorithm, "chromaprint")
        XCTAssertEqual(row?.identity.algorithmVersion, "1.5.1")
        XCTAssertEqual(row?.identity.fingerprintHash, "fp-hash-001")
        XCTAssertEqual(row?.acoustID, "acoustid-001")
        XCTAssertEqual(row?.recordingID, "recording-001")
        XCTAssertEqual(row?.title, "Fixture Song")
        XCTAssertEqual(row?.artist, "Sounding Fixtures")
        XCTAssertEqual(row?.album, "Integration Proofs")
        XCTAssertEqual(row?.isrc, "US-S01-26-00001")
        XCTAssertEqual(row?.durationSeconds, 12.5)
        XCTAssertEqual(row?.score, 0.98)
        XCTAssertEqual(row?.responseJSON, #"{"status":"ok","results":[{"id":"acoustid-001"}]}"#)
        XCTAssertEqual(row?.createdAt, "2026-05-01T10:00:00Z")
        XCTAssertEqual(row?.updatedAt, "2026-05-01T10:00:00Z")
    }

    func testDuplicateSuccessfulWriteUpdatesExistingRow() throws {
        let temporary = try TemporarySoundingDatabase()
        let cache = AcoustIDLookupCache(database: temporary.database)

        try cache.upsert(.fixture(title: "First Title", artist: "First Artist", fetchedAt: "2026-05-01T10:00:00Z"))
        try cache.upsert(.fixture(title: "Updated Title", artist: "Updated Artist", score: 0.76, fetchedAt: "2026-05-01T10:05:00Z"))

        let rows = try temporary.database.read { db in
            try Row.fetchAll(db, sql: "SELECT title, artist, score, created_at, updated_at FROM acoustid_lookup_cache")
        }

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["title"] as String, "Updated Title")
        XCTAssertEqual(rows[0]["artist"] as String, "Updated Artist")
        XCTAssertEqual(rows[0]["score"] as Double, 0.76)
        XCTAssertEqual(rows[0]["created_at"] as String, "2026-05-01T10:00:00Z")
        XCTAssertEqual(rows[0]["updated_at"] as String, "2026-05-01T10:05:00Z")
    }

    func testRejectsEmptyCacheIdentityBeforeDatabaseWrite() throws {
        let temporary = try TemporarySoundingDatabase()
        let cache = AcoustIDLookupCache(database: temporary.database)

        XCTAssertThrowsError(
            try cache.upsert(
                .fixture(
                    identity: AcoustIDLookupCacheIdentity(
                        algorithm: " ",
                        algorithmVersion: "1.5.1",
                        fingerprintHash: "fp-hash-001"
                    )
                )
            )
        ) { error in
            XCTAssertEqual(error as? AcoustIDLookupCacheError, .invalidIdentity)
        }
        XCTAssertThrowsError(
            try cache.fetch(
                identity: AcoustIDLookupCacheIdentity(
                    algorithm: "chromaprint",
                    algorithmVersion: "",
                    fingerprintHash: "fp-hash-001"
                )
            )
        ) { error in
            XCTAssertEqual(error as? AcoustIDLookupCacheError, .invalidIdentity)
        }

        let count = try temporary.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM acoustid_lookup_cache")
        }
        XCTAssertEqual(count, 0)
    }

    func testRejectsInvalidAndOversizedResponseJSON() throws {
        let temporary = try TemporarySoundingDatabase()
        let cache = AcoustIDLookupCache(database: temporary.database)

        XCTAssertThrowsError(
            try cache.upsert(.fixture(responseJSON: "not-json"))
        ) { error in
            XCTAssertEqual(error as? AcoustIDLookupCacheError, .invalidResponseJSON)
        }
        let oversizedJSON = "{\"payload\":\"" + String(repeating: "x", count: 8_193) + "\"}"
        XCTAssertThrowsError(
            try cache.upsert(.fixture(responseJSON: oversizedJSON))
        ) { error in
            XCTAssertEqual(error as? AcoustIDLookupCacheError, .responseJSONTooLarge(maxBytes: 8_192))
        }

        let count = try temporary.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM acoustid_lookup_cache")
        }
        XCTAssertEqual(count, 0)
    }

    func testNullableMetadataAndScoresRemainOptional() throws {
        let temporary = try TemporarySoundingDatabase()
        let cache = AcoustIDLookupCache(database: temporary.database)

        try cache.upsert(
            .fixture(
                acoustID: nil,
                recordingID: nil,
                title: nil,
                artist: nil,
                album: nil,
                isrc: nil,
                durationSeconds: nil,
                score: nil,
                responseJSON: nil
            )
        )

        let row = try XCTUnwrap(try cache.fetch(identity: .fixture))
        XCTAssertNil(row.acoustID)
        XCTAssertNil(row.recordingID)
        XCTAssertNil(row.title)
        XCTAssertNil(row.artist)
        XCTAssertNil(row.album)
        XCTAssertNil(row.isrc)
        XCTAssertNil(row.durationSeconds)
        XCTAssertNil(row.score)
        XCTAssertNil(row.responseJSON)
    }
}

private extension AcoustIDLookupCacheIdentity {
    static var fixture: AcoustIDLookupCacheIdentity {
        AcoustIDLookupCacheIdentity(
            algorithm: "chromaprint",
            algorithmVersion: "1.5.1",
            fingerprintHash: "fp-hash-001"
        )
    }
}

private extension AcoustIDLookupCacheEntry {
    static func fixture(
        identity: AcoustIDLookupCacheIdentity = .fixture,
        acoustID: String? = "acoustid-001",
        recordingID: String? = "recording-001",
        title: String? = "Fixture Song",
        artist: String? = "Sounding Fixtures",
        album: String? = nil,
        isrc: String? = nil,
        durationSeconds: Double? = nil,
        score: Double? = nil,
        responseJSON: String? = #"{"status":"ok"}"#,
        fetchedAt: String = "2026-05-01T10:00:00Z"
    ) -> AcoustIDLookupCacheEntry {
        AcoustIDLookupCacheEntry(
            identity: identity,
            acoustID: acoustID,
            recordingID: recordingID,
            title: title,
            artist: artist,
            album: album,
            isrc: isrc,
            durationSeconds: durationSeconds,
            score: score,
            responseJSON: responseJSON,
            fetchedAt: fetchedAt
        )
    }
}
