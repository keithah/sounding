import GRDB
import XCTest
@testable import SoundingKit

final class TranscriptAdClassificationCacheTests: XCTestCase {
    func testUpsertAndFetchClassificationBySegmentAndClassifier() throws {
        let temporary = try TemporarySoundingDatabase()
        let segmentID = try makeTranscriptSegment(database: temporary.database)
        let cache = TranscriptAdClassificationCache(database: temporary.database)

        try cache.upsert(
            .fixture(
                segmentID: segmentID,
                isAd: true,
                confidence: 0.82,
                signals: ["url:domain", "ctax2"],
                verdict: "ad",
                adType: "commercialSpot",
                brand: "Wells Fargo",
                product: "Clear Access Banking",
                reason: "Banking disclaimer and CTA.",
                modelIdentifier: "mock",
                classifiedAt: "2026-05-01T10:00:00Z"
            )
        )

        let row = try XCTUnwrap(
            try cache.fetch(
                identity: TranscriptAdClassificationCacheIdentity(
                    segmentID: segmentID,
                    classifier: "transcript-ad-heuristic",
                    classifierVersion: "1"
                )
            )
        )

        XCTAssertEqual(row.identity.segmentID, segmentID)
        XCTAssertEqual(row.identity.classifier, "transcript-ad-heuristic")
        XCTAssertEqual(row.identity.classifierVersion, "1")
        XCTAssertEqual(row.isAd, true)
        XCTAssertEqual(row.confidence, 0.82)
        XCTAssertEqual(row.signals, ["url:domain", "ctax2"])
        XCTAssertEqual(row.verdict, "ad")
        XCTAssertEqual(row.adType, "commercialSpot")
        XCTAssertEqual(row.brand, "Wells Fargo")
        XCTAssertEqual(row.product, "Clear Access Banking")
        XCTAssertEqual(row.reason, "Banking disclaimer and CTA.")
        XCTAssertEqual(row.modelIdentifier, "mock")
        XCTAssertEqual(row.createdAt, "2026-05-01T10:00:00Z")
        XCTAssertEqual(row.updatedAt, "2026-05-01T10:00:00Z")
    }

    func testDuplicateWriteUpdatesExistingClassification() throws {
        let temporary = try TemporarySoundingDatabase()
        let segmentID = try makeTranscriptSegment(database: temporary.database)
        let cache = TranscriptAdClassificationCache(database: temporary.database)

        try cache.upsert(.fixture(segmentID: segmentID, isAd: false, confidence: 0.22, classifiedAt: "2026-05-01T10:00:00Z"))
        try cache.upsert(.fixture(segmentID: segmentID, isAd: true, confidence: 0.73, signals: ["disclaimerx2"], classifiedAt: "2026-05-01T10:05:00Z"))

        let rows = try temporary.database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT is_ad, confidence, signals_json, verdict, ad_type, brand, product, created_at, updated_at
                FROM transcript_ad_classification_cache
                """
            )
        }

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["is_ad"] as Bool, true)
        XCTAssertEqual(rows[0]["confidence"] as Double, 0.73)
        XCTAssertEqual(rows[0]["signals_json"] as String, #"["disclaimerx2"]"#)
        XCTAssertNil(rows[0]["verdict"] as String?)
        XCTAssertNil(rows[0]["ad_type"] as String?)
        XCTAssertNil(rows[0]["brand"] as String?)
        XCTAssertNil(rows[0]["product"] as String?)
        XCTAssertEqual(rows[0]["created_at"] as String, "2026-05-01T10:00:00Z")
        XCTAssertEqual(rows[0]["updated_at"] as String, "2026-05-01T10:05:00Z")
    }

    func testDeleteAllRemovesCachedTranscriptAdClassifications() throws {
        let temporary = try TemporarySoundingDatabase()
        let firstSegmentID = try makeTranscriptSegment(database: temporary.database, sequence: 0)
        let secondSegmentID = try makeTranscriptSegment(database: temporary.database, sequence: 1)
        let cache = TranscriptAdClassificationCache(database: temporary.database)

        try cache.upsert(.fixture(segmentID: firstSegmentID, isAd: true))
        try cache.upsert(.fixture(segmentID: secondSegmentID, isAd: false))

        let deletedCount = try cache.deleteAll()

        XCTAssertEqual(deletedCount, 2)
        XCTAssertNil(try cache.fetch(identity: .fixture(segmentID: firstSegmentID)))
        XCTAssertNil(try cache.fetch(identity: .fixture(segmentID: secondSegmentID)))
    }

    func testRejectsInvalidIdentityConfidenceAndSignals() throws {
        let temporary = try TemporarySoundingDatabase()
        let cache = TranscriptAdClassificationCache(database: temporary.database)

        XCTAssertThrowsError(
            try cache.upsert(.fixture(segmentID: 0))
        ) { error in
            XCTAssertEqual(error as? TranscriptAdClassificationCacheError, .invalidIdentity)
        }
        XCTAssertThrowsError(
            try cache.upsert(.fixture(confidence: .nan))
        ) { error in
            XCTAssertEqual(error as? TranscriptAdClassificationCacheError, .invalidConfidence)
        }
        XCTAssertThrowsError(
            try cache.upsert(.fixture(signals: [" "]))
        ) { error in
            XCTAssertEqual(error as? TranscriptAdClassificationCacheError, .invalidSignals)
        }
    }

    private func makeTranscriptSegment(database: SoundingDatabase, sequence: Int = 0) throws -> Int64 {
        let registry = StreamRegistry(database: database)
        let stream = try registry.add(
            name: "Cache Test \(sequence)",
            streamType: .hls,
            source: "https://example.test/cache-\(sequence).m3u8",
            createdAt: "2026-05-01T09:59:00Z"
        )
        let writer = IngestPersistence(database: database)
        let runID = try writer.createRun(
            streamID: stream.id,
            startedAt: "2026-05-01T10:00:00Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 0,
            segmentURI: "cache-\(sequence).ts",
            startedAt: "2026-05-01T10:00:01Z",
            endedAt: "2026-05-01T10:00:11Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                segments: [
                    TranscriptSegmentDraft(
                        sequence: sequence,
                        speakerLabel: "announcer",
                        startSeconds: 0,
                        endSeconds: 10,
                        text: "Visit example dot com today.",
                        confidence: 0.9
                    )
                ],
                createdAt: "2026-05-01T10:00:02Z"
            )
        )
        return try database.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT id FROM transcript_segments WHERE chunk_id = ? LIMIT 1",
                arguments: [chunkID]
            )
        }!
    }
}

private extension TranscriptAdClassificationCacheIdentity {
    static func fixture(segmentID: Int64) -> TranscriptAdClassificationCacheIdentity {
        TranscriptAdClassificationCacheIdentity(
            segmentID: segmentID,
            classifier: "transcript-ad-heuristic",
            classifierVersion: "1"
        )
    }

    static var fixture: TranscriptAdClassificationCacheIdentity {
        TranscriptAdClassificationCacheIdentity(
            segmentID: 1,
            classifier: "transcript-ad-heuristic",
            classifierVersion: "1"
        )
    }
}

private extension TranscriptAdClassificationCacheEntry {
    static func fixture(
        segmentID: Int64 = 1,
        classifier: String = "transcript-ad-heuristic",
        classifierVersion: String = "1",
        isAd: Bool = true,
        confidence: Double = 0.82,
        signals: [String] = ["url:domain"],
        verdict: String? = nil,
        adType: String? = nil,
        brand: String? = nil,
        product: String? = nil,
        reason: String? = nil,
        modelIdentifier: String? = nil,
        classifiedAt: String = "2026-05-01T10:00:00Z"
    ) -> TranscriptAdClassificationCacheEntry {
        TranscriptAdClassificationCacheEntry(
            identity: TranscriptAdClassificationCacheIdentity(
                segmentID: segmentID,
                classifier: classifier,
                classifierVersion: classifierVersion
            ),
            isAd: isAd,
            confidence: confidence,
            signals: signals,
            verdict: verdict,
            adType: adType,
            brand: brand,
            product: product,
            reason: reason,
            modelIdentifier: modelIdentifier,
            classifiedAt: classifiedAt
        )
    }
}
