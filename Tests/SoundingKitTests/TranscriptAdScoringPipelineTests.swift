import XCTest
@testable import SoundingKit

final class TranscriptAdScoringPipelineTests: XCTestCase {
    func testBelowThresholdParagraphSkipsVerifier() async throws {
        let verifier = RecordingAdVerifier()
        let pipeline = TranscriptAdScoringPipeline(
            verifier: verifier,
            isVerifierEnabled: true,
            now: { "2026-05-01T10:00:00Z" }
        )

        let result = await pipeline.classify(
            paragraph: paragraph(1, "A normal conversation about the weather.", start: 0, end: 8),
            neighbors: []
        )

        let calls = await verifier.recordedCalls()
        XCTAssertFalse(result.isAd)
        XCTAssertNil(result.verification)
        XCTAssertEqual(calls.count, 0)
    }

    func testMidBandParagraphCallsVerifierWithBoundedNeighbors() async throws {
        let verifier = RecordingAdVerifier(response: .ad(brand: "Acme", product: "Acme Plus"))
        let pipeline = TranscriptAdScoringPipeline(
            verifier: verifier,
            isVerifierEnabled: true,
            now: { "2026-05-01T10:00:00Z" }
        )
        let target = paragraph(
            10,
            "Discover what our low carbon solutions can do for your business.",
            start: 100,
            end: 128
        )
        let neighbors = (0..<8).map { index -> StreamAppTranscriptParagraph in
            let id = Int64(index + 1)
            let text = "Neighbor " + String(index)
            let startSeconds = Double(index * 10)
            let endSeconds = Double(index * 10 + 5)
            return paragraph(
                id,
                text,
                start: startSeconds,
                end: endSeconds
            )
        }

        let result = await pipeline.classify(paragraph: target, neighbors: neighbors)
        let calls = await verifier.calls

        XCTAssertTrue(result.isAd)
        XCTAssertEqual(result.verification?.brand, "Acme")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].paragraph.id, 10)
        XCTAssertLessThanOrEqual(calls[0].neighbors.count, 6)
        XCTAssertEqual(calls[0].neighbors.filter { $0.startSeconds < target.startSeconds }.count, 3)
        XCTAssertEqual(calls[0].neighbors.filter { $0.startSeconds > target.startSeconds }.count, 0)
    }

    func testSponsorOnlyAmbiguousBandCallsVerifier() async throws {
        let verifier = RecordingAdVerifier(response: .dialogue())
        let pipeline = TranscriptAdScoringPipeline(
            verifier: verifier,
            isVerifierEnabled: true,
            now: { "2026-05-01T10:00:00Z" }
        )

        let result = await pipeline.classify(
            paragraph: paragraph(
                11,
                "This segment is brought to you by Acme.",
                start: 100,
                end: 112
            ),
            neighbors: []
        )
        let calls = await verifier.recordedCalls()

        XCTAssertEqual(result.heuristic.confidence, 0.35)
        XCTAssertFalse(result.isAd)
        XCTAssertEqual(result.verification?.verdict, .dialogue)
        XCTAssertEqual(calls.count, 1)
    }

    func testHighConfidenceParagraphWithCachedBrandSkipsVerifier() async throws {
        let verifier = RecordingAdVerifier(response: .ad(brand: "Ignored", product: nil))
        let cached = TranscriptAdVerification.ad(
            brand: "Wells Fargo",
            product: "Clear Access Banking",
            confidence: .high
        )
        let pipeline = TranscriptAdScoringPipeline(
            verifier: verifier,
            isVerifierEnabled: true,
            now: { "2026-05-01T10:00:00Z" }
        )

        let result = await pipeline.classify(
            paragraph: paragraph(
                1,
                "Visit wellsfargo.com today. Terms and conditions apply. Member FDIC.",
                start: 0,
                end: 24
            ),
            neighbors: [],
            cachedVerification: cached
        )

        let calls = await verifier.recordedCalls()
        XCTAssertTrue(result.isAd)
        XCTAssertEqual(result.verification?.brand, "Wells Fargo")
        XCTAssertEqual(calls.count, 0)
    }

    func testHighConfidenceParagraphWithoutBrandCallsVerifierForAttribution() async throws {
        let verifier = RecordingAdVerifier(response: .ad(brand: "Shopify", product: "Free Trial"))
        let pipeline = TranscriptAdScoringPipeline(
            verifier: verifier,
            isVerifierEnabled: true,
            now: { "2026-05-01T10:00:00Z" }
        )

        let result = await pipeline.classify(
            paragraph: paragraph(
                1,
                "Start your free trial today at shopify.com/win. Terms and conditions apply.",
                start: 0,
                end: 24
            ),
            neighbors: []
        )

        let calls = await verifier.recordedCalls()
        XCTAssertTrue(result.isAd)
        XCTAssertEqual(result.verification?.brand, "Shopify")
        XCTAssertEqual(calls.count, 1)
    }

    func testVerifierErrorReturnsHeuristicResult() async throws {
        let verifier = RecordingAdVerifier(error: VerificationFailure())
        let pipeline = TranscriptAdScoringPipeline(
            verifier: verifier,
            isVerifierEnabled: true,
            now: { "2026-05-01T10:00:00Z" }
        )

        let result = await pipeline.classify(
            paragraph: paragraph(
                1,
                "Discover what our low carbon solutions can do for your business.",
                start: 0,
                end: 28
            ),
            neighbors: []
        )

        let calls = await verifier.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(result.verification)
        XCTAssertEqual(result.verifierError, "VerificationFailure()")
        XCTAssertEqual(result.isAd, result.heuristic.confidence >= 0.50)
    }

    func testDisabledVerifierNeverCallsVerifier() async throws {
        let verifier = RecordingAdVerifier(response: .ad(brand: "Ignored", product: nil))
        let pipeline = TranscriptAdScoringPipeline(
            verifier: verifier,
            isVerifierEnabled: false,
            now: { "2026-05-01T10:00:00Z" }
        )

        let result = await pipeline.classify(
            paragraph: paragraph(
                1,
                "Start your free trial today at shopify.com/win. Terms and conditions apply.",
                start: 0,
                end: 24
            ),
            neighbors: []
        )

        let calls = await verifier.recordedCalls()
        XCTAssertTrue(result.isAd)
        XCTAssertNil(result.verification)
        XCTAssertEqual(calls.count, 0)
    }

    func testHeuristicClassificationPersistsKnownBrandAttributionWhenVerifierIsDisabled() async throws {
        let result = await TranscriptAdScoringPipeline(
            isVerifierEnabled: false,
            now: { "2026-05-01T10:00:00Z" }
        ).classify(
            paragraph: paragraph(
                1,
                "Terms apply. Visit capitalone.com/bank for details.",
                start: 0,
                end: 8
            ),
            neighbors: [
                paragraph(2, "There's no fees or minimums on Capital One checking.", start: 9, end: 25)
            ]
        )

        let entry = result.cacheEntryForTesting(segmentID: 1, classifiedAt: "2026-05-01T10:00:00Z")

        XCTAssertTrue(result.isAd)
        XCTAssertNil(result.verification)
        XCTAssertEqual(entry.brand, "Capital One")
        XCTAssertEqual(entry.adType, "commercialSpot")
        XCTAssertTrue(entry.signals.contains("heuristic-brand"))
    }

    func testClassificationRefresherPersistsOnlyMissingParagraphs() async throws {
        let temporary = try TemporarySoundingDatabase()
        let firstSegmentID = try makeTranscriptSegment(
            database: temporary.database,
            sequence: 1,
            text: "Already cached.",
            startSeconds: 0,
            endSeconds: 6
        )
        let secondSegmentID = try makeTranscriptSegment(
            database: temporary.database,
            sequence: 2,
            text: "Visit example dot com today. Terms and conditions apply.",
            startSeconds: 8,
            endSeconds: 28
        )
        let cache = TranscriptAdClassificationCache(database: temporary.database)
        try cache.upsert(
            TranscriptAdClassificationCacheEntry(
                identity: TranscriptAdClassificationCacheIdentity(
                    segmentID: firstSegmentID,
                    classifier: TranscriptAdScorer.classifier,
                    classifierVersion: TranscriptAdScorer.classifierVersion
                ),
                isAd: false,
                confidence: 0.11,
                signals: ["cached"],
                classifiedAt: "2026-05-01T09:59:00Z"
            )
        )
        let verifier = RecordingAdVerifier(response: .ad(brand: "Example", product: nil))
        let refresher = TranscriptAdClassificationRefresher(
            database: temporary.database,
            pipeline: TranscriptAdScoringPipeline(
                verifier: verifier,
                isVerifierEnabled: true,
                now: { "2026-05-01T10:00:00Z" }
            ),
            now: { "2026-05-01T10:00:00Z" }
        )

        let result = try await refresher.refresh(
            paragraphs: [
                paragraph(firstSegmentID, "Already cached.", start: 0, end: 6),
                paragraph(
                    secondSegmentID,
                    "Visit example dot com today. Terms and conditions apply.",
                    start: 8,
                    end: 28
                ),
            ]
        )
        let cachedFirst = try XCTUnwrap(
            try cache.fetch(
                identity: TranscriptAdClassificationCacheIdentity(
                    segmentID: firstSegmentID,
                    classifier: TranscriptAdScorer.classifier,
                    classifierVersion: TranscriptAdScorer.classifierVersion
                )
            )
        )
        let cachedSecond = try XCTUnwrap(
            try cache.fetch(
                identity: TranscriptAdClassificationCacheIdentity(
                    segmentID: secondSegmentID,
                    classifier: TranscriptAdScorer.classifier,
                    classifierVersion: TranscriptAdScorer.classifierVersion
                )
            )
        )
        let calls = await verifier.recordedCalls()

        XCTAssertEqual(result.consideredCount, 2)
        XCTAssertEqual(result.skippedCachedCount, 1)
        XCTAssertEqual(result.classifiedCount, 1)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].paragraph.id, secondSegmentID)
        XCTAssertEqual(cachedFirst.signals, ["cached"])
        XCTAssertEqual(cachedFirst.updatedAt, "2026-05-01T09:59:00Z")
        XCTAssertTrue(cachedSecond.isAd)
        XCTAssertEqual(cachedSecond.updatedAt, "2026-05-01T10:00:00Z")
        XCTAssertTrue(cachedSecond.signals.contains("verified:ad"))
        XCTAssertEqual(cachedSecond.verdict, "ad")
        XCTAssertEqual(cachedSecond.adType, "commercialSpot")
        XCTAssertEqual(cachedSecond.brand, "Example")
        XCTAssertEqual(cachedSecond.modelIdentifier, "mock")
    }

    func testClassificationRefresherUpgradesCachedAmbiguousRowsWithVerifierAttribution() async throws {
        let temporary = try TemporarySoundingDatabase()
        let segmentID = try makeTranscriptSegment(
            database: temporary.database,
            sequence: 1,
            text: "No matter what you're listening for, you can always find it on Tune In.",
            startSeconds: 0,
            endSeconds: 12
        )
        let cache = TranscriptAdClassificationCache(database: temporary.database)
        try cache.upsert(
            TranscriptAdClassificationCacheEntry(
                identity: TranscriptAdClassificationCacheIdentity(
                    segmentID: segmentID,
                    classifier: TranscriptAdScorer.classifier,
                    classifierVersion: TranscriptAdScorer.classifierVersion
                ),
                isAd: false,
                confidence: 0.30,
                signals: ["ctax3"],
                classifiedAt: "2026-05-01T09:59:00Z"
            )
        )
        let verifier = RecordingAdVerifier(response: .ad(brand: "TuneIn", product: "TuneIn"))
        let refresher = TranscriptAdClassificationRefresher(
            database: temporary.database,
            pipeline: TranscriptAdScoringPipeline(
                verifier: verifier,
                isVerifierEnabled: true,
                now: { "2026-05-01T10:00:00Z" }
            ),
            now: { "2026-05-01T10:00:00Z" }
        )

        let result = try await refresher.refresh(
            paragraphs: [
                paragraph(
                    segmentID,
                    "No matter what you're listening for, you can always find it on Tune In.",
                    start: 0,
                    end: 12
                )
            ]
        )
        let row = try XCTUnwrap(
            try cache.fetch(
                identity: TranscriptAdClassificationCacheIdentity(
                    segmentID: segmentID,
                    classifier: TranscriptAdScorer.classifier,
                    classifierVersion: TranscriptAdScorer.classifierVersion
                )
            )
        )
        let calls = await verifier.recordedCalls()

        XCTAssertEqual(result.skippedCachedCount, 0)
        XCTAssertEqual(result.classifiedCount, 1)
        XCTAssertEqual(calls.map(\.paragraph.id), [segmentID])
        XCTAssertTrue(row.isAd)
        XCTAssertEqual(row.brand, "TuneIn")
        XCTAssertEqual(row.product, "TuneIn")
        XCTAssertEqual(row.adType, "commercialSpot")
        XCTAssertEqual(row.modelIdentifier, "mock")
        XCTAssertEqual(row.updatedAt, "2026-05-01T10:00:00Z")
    }

    func testClassificationRefresherCachesNegativeHeuristicResult() async throws {
        let temporary = try TemporarySoundingDatabase()
        let segmentID = try makeTranscriptSegment(
            database: temporary.database,
            sequence: 1,
            text: "A normal conversation about the weather.",
            startSeconds: 0,
            endSeconds: 8
        )
        let verifier = RecordingAdVerifier()
        let refresher = TranscriptAdClassificationRefresher(
            database: temporary.database,
            pipeline: TranscriptAdScoringPipeline(
                verifier: verifier,
                isVerifierEnabled: true,
                now: { "2026-05-01T10:00:00Z" }
            ),
            now: { "2026-05-01T10:00:00Z" }
        )

        let result = try await refresher.refresh(
            paragraphs: [
                paragraph(
                    segmentID,
                    "A normal conversation about the weather.",
                    start: 0,
                    end: 8
                )
            ]
        )
        let row = try XCTUnwrap(
            try TranscriptAdClassificationCache(database: temporary.database).fetch(
                identity: TranscriptAdClassificationCacheIdentity(
                    segmentID: segmentID,
                    classifier: TranscriptAdScorer.classifier,
                    classifierVersion: TranscriptAdScorer.classifierVersion
                )
            )
        )
        let calls = await verifier.recordedCalls()

        XCTAssertEqual(result.classifiedCount, 1)
        XCTAssertEqual(calls.count, 0)
        XCTAssertFalse(row.isAd)
        XCTAssertEqual(row.confidence, 0)
        XCTAssertEqual(row.signals, ["heuristic:no-signals"])
    }

    private func paragraph(
        _ id: Int64,
        _ text: String,
        start: Double,
        end: Double
    ) -> StreamAppTranscriptParagraph {
        StreamAppTranscriptParagraph(
            id: id,
            streamID: 1,
            runID: 1,
            chunkID: 1,
            sequence: Int(id),
            speakerDisplay: StreamAppSpeakerDisplay(
                rawLabel: "speaker",
                displayLabel: "speaker",
                colorToken: "blue"
            ),
            startSeconds: start,
            endSeconds: end,
            text: text,
            confidence: nil
        )
    }

    private func makeTranscriptSegment(
        database: SoundingDatabase,
        sequence: Int,
        text: String,
        startSeconds: Double,
        endSeconds: Double
    ) throws -> Int64 {
        let registry = StreamRegistry(database: database)
        let stream = try registry.add(
            name: "Pipeline Test \(sequence)",
            streamType: .hls,
            source: "https://example.test/pipeline-\(sequence).m3u8",
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
            sequence: sequence,
            segmentURI: "pipeline-\(sequence).ts",
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
                        startSeconds: startSeconds,
                        endSeconds: endSeconds,
                        text: text,
                        confidence: 0.9
                    )
                ],
                createdAt: "2026-05-01T10:00:02Z"
            )
        )
        return try database.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT id FROM transcript_segments WHERE sequence = ? LIMIT 1",
                arguments: [sequence]
            )
        }!
    }
}

private actor RecordingAdVerifier: TranscriptAdVerifier {
    struct Call: Equatable {
        var paragraph: StreamAppTranscriptParagraph
        var neighbors: [StreamAppTranscriptParagraph]
    }

    private(set) var calls: [Call] = []
    var response: TranscriptAdVerification
    var error: (any Error)?

    init(
        response: TranscriptAdVerification = .ad(brand: "Acme", product: nil),
        error: (any Error)? = nil
    ) {
        self.response = response
        self.error = error
    }

    func verify(
        paragraph: StreamAppTranscriptParagraph,
        neighbors: [StreamAppTranscriptParagraph]
    ) async throws -> TranscriptAdVerification {
        calls.append(Call(paragraph: paragraph, neighbors: neighbors))
        if let error { throw error }
        return response
    }

    func recordedCalls() -> [Call] {
        calls
    }
}

private struct VerificationFailure: Error {}

private extension TranscriptAdVerification {
    static func ad(
        brand: String?,
        product: String?,
        confidence: TranscriptAdVerification.Confidence = .high
    ) -> TranscriptAdVerification {
        TranscriptAdVerification(
            verdict: .ad,
            adType: .commercialSpot,
            brand: brand,
            product: product,
            confidence: confidence,
            reason: "Fixture ad.",
            modelIdentifier: "mock",
            classifiedAt: "2026-05-01T10:00:00Z"
        )
    }

    static func dialogue(
        confidence: TranscriptAdVerification.Confidence = .medium
    ) -> TranscriptAdVerification {
        TranscriptAdVerification(
            verdict: .dialogue,
            adType: nil,
            brand: nil,
            product: nil,
            confidence: confidence,
            reason: "Fixture dialogue.",
            modelIdentifier: "mock",
            classifiedAt: "2026-05-01T10:00:00Z"
        )
    }
}
