import GRDB
import XCTest
@testable import SoundingKit

final class StreamAppTimelineStoreTests: XCTestCase {
    func testSnapshotIsBoundedToSelectedStreamAndDoesNotExposeReconnectSource() throws {
        let fixture = try makeFixture()
        let store = StreamAppTimelineStore(database: fixture.temporary.database)

        let snapshot = try store.snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 22,
                    liveEdgeSeconds: 30,
                    bufferedStartSeconds: 10,
                    bufferedEndSeconds: 30
                ),
                paragraphLimit: 2,
                wordLimitPerParagraph: 2,
                metadataLimit: 2,
                timelineLimit: 6,
                lookbackSeconds: 30,
                refreshedAt: "2026-05-01T16:00:00Z"
            )
        )

        XCTAssertEqual(snapshot.streamID, fixture.mainStreamID)
        XCTAssertEqual(snapshot.transcriptParagraphs.map(\.text), ["Middle beta words", "Closing gamma words"])
        XCTAssertEqual(snapshot.transcriptParagraphs.flatMap { $0.words.map(\.text) }, ["Middle", "beta", "Closing", "gamma"])
        XCTAssertTrue(snapshot.transcriptParagraphs.allSatisfy { $0.streamID == fixture.mainStreamID })
        XCTAssertFalse(String(describing: snapshot).contains("token=fixture-secret"))
        XCTAssertFalse(String(describing: snapshot).contains("other-radio"))
        XCTAssertEqual(snapshot.diagnostics.latestSegmentEndSeconds, 30)
        XCTAssertEqual(snapshot.diagnostics.playerPositionSeconds, 22)
        XCTAssertEqual(snapshot.diagnostics.playerLiveEdgeSeconds, 30)
        XCTAssertEqual(snapshot.diagnostics.lagSeconds, 8)
        XCTAssertEqual(snapshot.diagnostics.refreshedAt, "2026-05-01T16:00:00Z")
    }

    func testTimelineMergesTranscriptSongAndAdItemsDeterministicallyWithSeekability() throws {
        let fixture = try makeFixture()
        let store = StreamAppTimelineStore(database: fixture.temporary.database)

        let snapshot = try store.snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 15,
                    liveEdgeSeconds: 35,
                    bufferedStartSeconds: 10,
                    bufferedEndSeconds: 30,
                    unavailableRangeMessage: "Requested 40s is unavailable (available range 10-30s)."
                ),
                paragraphLimit: 5,
                wordLimitPerParagraph: 5,
                metadataLimit: 3,
                timelineLimit: 10,
                lookbackSeconds: 40,
                refreshedAt: "2026-05-01T16:00:01Z"
            )
        )

        XCTAssertEqual(
            snapshot.timelineItems.map {
                "\($0.kind.rawValue):\($0.startSeconds):\($0.title):\($0.speakerDisplay?.displayLabel ?? "-"):\($0.isSeekable)"
            },
            [
                "transcript:0.0:Fixture Artist:Fixture Artist:false",
                "song:5.0:Fixture Song:Fixture Artist:false",
                "event:9.0:Ad break start:-:false",
                "event:21.0:Ad break end:-:true"
            ]
        )
        XCTAssertEqual(snapshot.currentMetadata?.title, "Fixture Song")
        XCTAssertEqual(snapshot.currentMetadata?.artist, "Fixture Artist")
        XCTAssertEqual(snapshot.recentMetadata.map(\.title), ["Fixture Song"])
        XCTAssertEqual(snapshot.timelineRail.visibleStartSeconds, 0)
        XCTAssertEqual(snapshot.timelineRail.visibleEndSeconds, 35)
        XCTAssertEqual(snapshot.timelineRail.spans.map(\.title), ["Fixture Song", "AD"])
        XCTAssertEqual(snapshot.timelineRail.markers.map(\.title), ["AD", "AD"])
        XCTAssertEqual(snapshot.diagnostics.bufferedSeekUnavailableMessage, "Requested 40s is unavailable (available range 10-30s).")
    }

    func testTimelineRailIncludesTranscriptInferredAdSpansFromSnapshotParagraphs() throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)
        let runID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T15:50:00Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 50,
            segmentURI: "main-050.ts",
            startedAt: "2026-05-01T15:50:01Z",
            endedAt: "2026-05-01T15:50:26Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                segments: [
                    segment(
                        50,
                        "announcer",
                        45,
                        70,
                        "Visit example.com today. Terms and conditions apply."
                    ),
                ],
                createdAt: "2026-05-01T15:50:02Z"
            )
        )

        let snapshot = try StreamAppTimelineStore(database: fixture.temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 70,
                    liveEdgeSeconds: 80
                ),
                paragraphLimit: 10,
                metadataLimit: 10,
                timelineLimit: 10,
                lookbackSeconds: 80,
                refreshedAt: "2026-05-01T16:00:02Z"
            )
        )

        let inferredSpan = try XCTUnwrap(snapshot.timelineRail.spans.first { $0.source == .transcript })
        XCTAssertEqual(inferredSpan.title, "AD")
        XCTAssertEqual(inferredSpan.colorToken, "ad-inferred")
        XCTAssertEqual(inferredSpan.isAd, true)
        XCTAssertGreaterThanOrEqual(inferredSpan.confidence ?? 0, 0.50)
        XCTAssertTrue(inferredSpan.signals.contains { $0.contains("url") })
    }

    func testHeuristicTranscriptAdClassificationCarriesBrandToTimelineItems() throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)
        let runID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T15:50:00Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 51,
            segmentURI: "main-051.ts",
            startedAt: "2026-05-01T15:50:01Z",
            endedAt: "2026-05-01T15:50:26Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                segments: [
                    segment(
                        51,
                        "announcer",
                        45,
                        70,
                        "Mobile carriers message and data rates may apply. Wells Fargo Bank is a member FDIC."
                    ),
                ],
                createdAt: "2026-05-01T15:50:02Z"
            )
        )
        let segmentID = try fixture.temporary.database.read { db in
            try XCTUnwrap(
                Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM transcript_segments WHERE run_id = ? AND sequence = ?",
                    arguments: [runID, 51]
                )
            )
        }

        let snapshot = try StreamAppTimelineStore(database: fixture.temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 70,
                    liveEdgeSeconds: 80
                ),
                paragraphLimit: 10,
                metadataLimit: 10,
                timelineLimit: 10,
                lookbackSeconds: 80,
                refreshedAt: "2026-05-01T16:00:02Z"
            )
        )

        let inferredSpan = try XCTUnwrap(snapshot.timelineRail.spans.first { $0.source == .transcript })
        XCTAssertEqual(inferredSpan.title, "Wells Fargo")
        XCTAssertEqual(inferredSpan.brand, "Wells Fargo")
        let item = try XCTUnwrap(snapshot.timelineItems.first { $0.id == "transcript:\(segmentID)" })
        XCTAssertTrue(item.isAd)
        XCTAssertEqual(item.brand, "Wells Fargo")
        XCTAssertTrue(item.signals.contains("brand:Wells Fargo"))
    }

    func testTimelineRailUsesCachedTranscriptAdClassification() throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)
        let runID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T15:55:00Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 55,
            segmentURI: "main-055.ts",
            startedAt: "2026-05-01T15:55:01Z",
            endedAt: "2026-05-01T15:55:11Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                segments: [
                    segment(55, "announcer", 55, 65, "Visit example.com."),
                ],
                createdAt: "2026-05-01T15:55:02Z"
            )
        )
        let segmentID = try fixture.temporary.database.read { db in
            try XCTUnwrap(
                Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM transcript_segments WHERE run_id = ? AND sequence = ?",
                    arguments: [runID, 55]
                )
            )
        }
        try TranscriptAdClassificationCache(database: fixture.temporary.database).upsert(
            TranscriptAdClassificationCacheEntry(
                identity: TranscriptAdClassificationCacheIdentity(
                    segmentID: segmentID,
                    classifier: TranscriptAdScorer.classifier,
                    classifierVersion: TranscriptAdScorer.classifierVersion
                ),
                isAd: true,
                confidence: 0.91,
                signals: ["verifier:cached"],
                verdict: "ad",
                adType: "commercialSpot",
                brand: "Example",
                product: "Example Plus",
                reason: "Fixture verifier result.",
                modelIdentifier: "mock",
                classifiedAt: "2026-05-01T15:55:03Z"
            )
        )

        let snapshot = try StreamAppTimelineStore(database: fixture.temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 65,
                    liveEdgeSeconds: 80
                ),
                paragraphLimit: 10,
                metadataLimit: 10,
                timelineLimit: 10,
                lookbackSeconds: 80,
                refreshedAt: "2026-05-01T16:00:02Z"
            )
        )

        let cachedSpan = try XCTUnwrap(snapshot.timelineRail.spans.first { $0.source == .transcript })
        XCTAssertEqual(cachedSpan.startSeconds, 55)
        XCTAssertEqual(cachedSpan.endSeconds, 65)
        XCTAssertEqual(cachedSpan.confidence, 0.91)
        XCTAssertEqual(cachedSpan.signals, ["verifier:cached"])
        XCTAssertEqual(cachedSpan.title, "Example")
        XCTAssertEqual(cachedSpan.brand, "Example")
        XCTAssertEqual(cachedSpan.product, "Example Plus")
        XCTAssertEqual(cachedSpan.adType, "commercialSpot")
        let cachedItem = try XCTUnwrap(snapshot.timelineItems.first { $0.id == "transcript:\(segmentID)" })
        XCTAssertTrue(cachedItem.isAd)
        XCTAssertEqual(cachedItem.colorToken, "ad-inferred")
        XCTAssertEqual(cachedItem.confidence, 0.91)
        XCTAssertEqual(cachedItem.signals, ["verifier:cached"])
        XCTAssertEqual(cachedItem.brand, "Example")
        XCTAssertEqual(cachedItem.product, "Example Plus")
        XCTAssertEqual(cachedItem.adType, "commercialSpot")
    }

    func testAsyncSnapshotRefreshesMissingClassificationsWithVerifier() async throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)
        let runID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T15:55:00Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 57,
            segmentURI: "main-057.ts",
            startedAt: "2026-05-01T15:55:01Z",
            endedAt: "2026-05-01T15:55:11Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                segments: [
                    segment(57, "announcer", 57, 69, "This segment is brought to you by Acme."),
                ],
                createdAt: "2026-05-01T15:55:02Z"
            )
        )
        let segmentID = try fixture.temporary.database.read { db in
            try XCTUnwrap(
                Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM transcript_segments WHERE run_id = ? AND sequence = ?",
                    arguments: [runID, 57]
                )
            )
        }
        let verifier = StoreRecordingAdVerifier(
            response: TranscriptAdVerification(
                verdict: .ad,
                adType: .sponsorBillboard,
                brand: "Acme",
                product: nil,
                confidence: .high,
                reason: "Sponsor language.",
                modelIdentifier: "mock",
                classifiedAt: "2026-05-01T15:55:04Z"
            )
        )
        let store = StreamAppTimelineStore(
            database: fixture.temporary.database,
            adClassificationRefresher: TranscriptAdClassificationRefresher(
                database: fixture.temporary.database,
                pipeline: TranscriptAdScoringPipeline(
                    verifier: verifier,
                    isVerifierEnabled: true,
                    now: { "2026-05-01T15:55:04Z" }
                ),
                now: { "2026-05-01T15:55:04Z" }
            )
        )

        let snapshot = try await store.snapshotRefreshingAdClassifications(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 69,
                    liveEdgeSeconds: 80
                ),
                paragraphLimit: 10,
                metadataLimit: 10,
                timelineLimit: 10,
                lookbackSeconds: 80,
                refreshedAt: "2026-05-01T16:00:02Z"
            )
        )
        let calls = await verifier.recordedCalls()
        let row = try XCTUnwrap(
            try TranscriptAdClassificationCache(database: fixture.temporary.database).fetch(
                identity: TranscriptAdClassificationCacheIdentity(
                    segmentID: segmentID,
                    classifier: TranscriptAdScorer.classifier,
                    classifierVersion: TranscriptAdScorer.classifierVersion
                )
            )
        )

        XCTAssertEqual(calls.map(\.paragraph.id), [segmentID])
        XCTAssertTrue(row.isAd)
        XCTAssertTrue(row.signals.contains("verified:ad"))
        let span = try XCTUnwrap(snapshot.timelineRail.spans.first { $0.source == .transcript })
        XCTAssertEqual(span.startSeconds, 57)
        XCTAssertEqual(span.endSeconds, 69)
        XCTAssertEqual(span.colorToken, "ad-inferred")
        XCTAssertTrue(span.signals.contains("verified:ad"))
    }

    func testSnapshotPropagatesCachedAdClassificationToRepeatedAdCopy() throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)
        let runID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T15:55:00Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 58,
            segmentURI: "main-058.ts",
            startedAt: "2026-05-01T15:55:01Z",
            endedAt: "2026-05-01T15:55:11Z"
        )
        let repeatedCopy = "This is the sound of Jack bus cutting his way to a small fortune."
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                segments: [
                    segment(58, "announcer", 58, 70, repeatedCopy),
                    segment(59, "dj", 92, 104, "Now back to the music after this message."),
                    segment(60, "announcer", 118, 130, repeatedCopy),
                ],
                createdAt: "2026-05-01T15:55:02Z"
            )
        )
        let segmentIDs = try fixture.temporary.database.read { db in
            try Int64.fetchAll(
                db,
                sql: "SELECT id FROM transcript_segments WHERE run_id = ? ORDER BY sequence",
                arguments: [runID]
            )
        }
        XCTAssertEqual(segmentIDs.count, 3)
        try TranscriptAdClassificationCache(database: fixture.temporary.database).upsert(
            TranscriptAdClassificationCacheEntry(
                identity: TranscriptAdClassificationCacheIdentity(
                    segmentID: segmentIDs[0],
                    classifier: TranscriptAdScorer.classifier,
                    classifierVersion: TranscriptAdScorer.classifierVersion
                ),
                isAd: true,
                confidence: 0.90,
                signals: ["verified:ad"],
                classifiedAt: "2026-05-01T15:55:03Z"
            )
        )
        try TranscriptAdClassificationCache(database: fixture.temporary.database).upsert(
            TranscriptAdClassificationCacheEntry(
                identity: TranscriptAdClassificationCacheIdentity(
                    segmentID: segmentIDs[2],
                    classifier: TranscriptAdScorer.classifier,
                    classifierVersion: TranscriptAdScorer.classifierVersion
                ),
                isAd: false,
                confidence: 0.15,
                signals: ["heuristic:no-ad"],
                classifiedAt: "2026-05-01T15:55:04Z"
            )
        )

        let snapshot = try StreamAppTimelineStore(database: fixture.temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 130,
                    liveEdgeSeconds: 140
                ),
                paragraphLimit: 10,
                metadataLimit: 10,
                timelineLimit: 10,
                lookbackSeconds: 140,
                refreshedAt: "2026-05-01T16:00:02Z"
            )
        )
        let repeatedRow = try XCTUnwrap(
            try TranscriptAdClassificationCache(database: fixture.temporary.database).fetch(
                identity: TranscriptAdClassificationCacheIdentity(
                    segmentID: segmentIDs[2],
                    classifier: TranscriptAdScorer.classifier,
                    classifierVersion: TranscriptAdScorer.classifierVersion
                )
            )
        )

        XCTAssertTrue(repeatedRow.isAd)
        XCTAssertTrue(repeatedRow.signals.contains("duplicate-ad-copy"))
        let repeatedSpan = try XCTUnwrap(
            snapshot.timelineRail.spans.first {
                $0.source == .transcript && $0.startSeconds == 118 && $0.endSeconds == 130
            }
        )
        XCTAssertTrue(repeatedSpan.isAd)
        XCTAssertTrue(repeatedSpan.signals.contains("duplicate-ad-copy"))
        XCTAssertTrue(
            snapshot.timelineItems.contains {
                $0.kind == .transcript
                    && ($0.subtitle?.contains(repeatedCopy) == true)
                    && $0.isAd
            }
        )
    }

    func testSnapshotCachesMissingTranscriptAdClassification() throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)
        let runID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T15:56:00Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 56,
            segmentURI: "main-056.ts",
            startedAt: "2026-05-01T15:56:01Z",
            endedAt: "2026-05-01T15:56:21Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                segments: [
                    segment(56, "announcer", 56, 76, "Visit example.com today. Terms and conditions apply."),
                ],
                createdAt: "2026-05-01T15:56:02Z"
            )
        )
        let segmentID = try fixture.temporary.database.read { db in
            try XCTUnwrap(
                Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM transcript_segments WHERE run_id = ? AND sequence = ?",
                    arguments: [runID, 56]
                )
            )
        }

        let snapshot = try StreamAppTimelineStore(database: fixture.temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 76,
                    liveEdgeSeconds: 90
                ),
                paragraphLimit: 10,
                metadataLimit: 10,
                timelineLimit: 10,
                lookbackSeconds: 90,
                refreshedAt: "2026-05-01T16:00:03Z"
            )
        )
        let row = try XCTUnwrap(
            try TranscriptAdClassificationCache(database: fixture.temporary.database).fetch(
                identity: TranscriptAdClassificationCacheIdentity(
                    segmentID: segmentID,
                    classifier: TranscriptAdScorer.classifier,
                    classifierVersion: TranscriptAdScorer.classifierVersion
                )
            )
        )

        XCTAssertTrue(row.isAd)
        XCTAssertGreaterThanOrEqual(row.confidence, 0.50)
        XCTAssertEqual(row.updatedAt, "2026-05-01T16:00:03Z")
        XCTAssertTrue(row.signals.contains { $0.contains("url") })
        XCTAssertTrue(snapshot.timelineRail.spans.contains { $0.source == .transcript && $0.confidence == row.confidence })
    }

    func testTranscriptionPolicyControlsDisplayedTranscriptRows() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Policy",
            streamType: .hls,
            source: "https://example.test/policy.m3u8",
            createdAt: "2026-05-01T15:00:00Z"
        )
        let writer = IngestPersistence(database: temporary.database)
        let runID = try writer.createRun(
            streamID: stream.id,
            startedAt: "2026-05-01T15:00:01Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 0,
            segmentURI: "policy-000.ts",
            startedAt: "2026-05-01T15:00:02Z",
            endedAt: "2026-05-01T15:00:32Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                segments: [
                    segment(0, "speaker", 0, 10, "song lyric line"),
                    segment(1, "speaker", 20, 30, "promo copy line"),
                ],
                songPlays: [
                    SongPlayDraft(
                        song: song(title: "The Great Divide", artist: "Noah Kahan"),
                        startSeconds: 0,
                        endSeconds: 15,
                        confidence: 1,
                        source: "ID3"
                    ),
                    SongPlayDraft(
                        song: song(title: "PADULTH21", artist: "Stingray"),
                        startSeconds: 20,
                        endSeconds: 30,
                        confidence: 1,
                        source: "ID3"
                    ),
                ],
                createdAt: "2026-05-01T15:00:03Z"
            )
        )
        let store = StreamAppTimelineStore(database: temporary.database)

        let always = try store.snapshot(
            request: StreamAppTimelineRequest(
                streamID: stream.id,
                timelineLimit: 20,
                lookbackSeconds: nil,
                transcriptionPolicy: .always
            )
        )
        let nonSongs = try store.snapshot(
            request: StreamAppTimelineRequest(
                streamID: stream.id,
                timelineLimit: 20,
                lookbackSeconds: nil,
                transcriptionPolicy: .nonSongs
            )
        )
        let hidden = try store.snapshot(
            request: StreamAppTimelineRequest(
                streamID: stream.id,
                timelineLimit: 20,
                lookbackSeconds: nil,
                transcriptionPolicy: .hidden
            )
        )

        XCTAssertEqual(always.timelineItems.filter { $0.kind == .transcript }.map(\.subtitle), [
            "song lyric line",
            "promo copy line",
        ])
        XCTAssertEqual(nonSongs.timelineItems.filter { $0.kind == .transcript }.map(\.subtitle), [
            "promo copy line"
        ])
        XCTAssertEqual(hidden.timelineItems.filter { $0.kind == .transcript }, [])
        XCTAssertEqual(nonSongs.timelineItems.filter { $0.kind == .song }.map(\.title), [
            "The Great Divide",
            "PADULTH21",
        ])
    }

    func testSnapshotWithoutPlayerStillUsesNewestMetadataWhenBounded() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Muted metadata",
            streamType: .icy,
            source: "https://example.test/live.mp3",
            createdAt: "2026-05-01T15:00:00Z"
        )
        let writer = IngestPersistence(database: temporary.database)
        let runID = try writer.createRun(
            streamID: stream.id,
            startedAt: "2026-05-01T15:00:01Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 0,
            segmentURI: "icy-live",
            startedAt: "2026-05-01T15:00:02Z",
            endedAt: "2026-05-01T15:02:02Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                segments: [],
                songPlays: (0..<5).map { index in
                    SongPlayDraft(
                        song: song(title: "Song \(index)", artist: "Artist \(index)"),
                        startSeconds: Double(index * 30),
                        endSeconds: Double(index * 30 + 30),
                        confidence: 1,
                        source: "ICY"
                    )
                },
                createdAt: "2026-05-01T15:00:03Z"
            )
        )

        let snapshot = try StreamAppTimelineStore(database: temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: stream.id,
                player: nil,
                metadataLimit: 2,
                timelineLimit: 2,
                refreshedAt: "2026-05-01T15:03:00Z"
            )
        )

        XCTAssertEqual(snapshot.currentMetadata?.title, "Song 4")
        XCTAssertEqual(snapshot.recentMetadata.map(\.title), ["Song 4", "Song 3"])
    }

    func testSnapshotShowsICYSongMetadataInTimelineAndRailWhenFingerprintsAreUnknown() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Tailgate",
            streamType: .icy,
            source: "https://example.test/live.mp3",
            createdAt: "2026-05-01T15:00:00Z"
        )
        let writer = IngestPersistence(database: temporary.database)
        let runID = try writer.createRun(
            streamID: stream.id,
            startedAt: "2026-05-01T15:00:01Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 0,
            segmentURI: "icy-live",
            startedAt: "2026-05-01T15:00:02Z",
            endedAt: "2026-05-01T15:01:02Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                segments: [
                    segment(0, "song-speaker", 10, 20, "Misheard lyrics should not be the song row")
                ],
                songPlays: [
                    SongPlayDraft(
                        song: unknownSong(songKey: "fingerprint:missed-song"),
                        startSeconds: 0,
                        endSeconds: 30,
                        confidence: 0.5,
                        source: "chromaprint"
                    ),
                    SongPlayDraft(
                        song: song(title: "HAND IN MY POCKET", artist: "ALANIS MORRISETTE"),
                        startSeconds: 30,
                        endSeconds: 90,
                        confidence: 1,
                        source: "icy"
                    ),
                ],
                createdAt: "2026-05-01T15:00:03Z"
            )
        )

        let snapshot = try StreamAppTimelineStore(database: temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: stream.id,
                player: AppPlayerTimelineSnapshot(
                    streamID: stream.id,
                    positionSeconds: 60,
                    liveEdgeSeconds: 90,
                    bufferedStartSeconds: 0,
                    bufferedEndSeconds: 90
                ),
                metadataLimit: 10,
                timelineLimit: 10,
                hideDeterministicUnknownSongs: true,
                refreshedAt: "2026-05-01T15:01:30Z"
            )
        )

        XCTAssertEqual(snapshot.currentMetadata?.title, "HAND IN MY POCKET")
        XCTAssertEqual(snapshot.currentMetadata?.artist, "ALANIS MORRISETTE")
        XCTAssertEqual(snapshot.recentMetadata.map(\.title), ["HAND IN MY POCKET"])
        XCTAssertTrue(
            snapshot.timelineItems.contains {
                $0.kind == .song
                    && $0.title == "HAND IN MY POCKET"
                    && $0.speakerDisplay?.displayLabel == "ALANIS MORRISETTE"
            }
        )
        XCTAssertEqual(snapshot.timelineRail.spans.map(\.title), ["HAND IN MY POCKET"])
    }

    func testDefaultTimelineRequestKeepsOlderMarkersOutsidePlaybackLookback() throws {
        let fixture = try makeFixture()
        let store = StreamAppTimelineStore(database: fixture.temporary.database)

        let snapshot = try store.snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 600,
                    liveEdgeSeconds: 610,
                    bufferedStartSeconds: 580,
                    bufferedEndSeconds: 610
                ),
                refreshedAt: "2026-05-01T16:00:01Z"
            )
        )

        XCTAssertEqual(snapshot.timelineRail.visibleStartSeconds, 5)
        XCTAssertEqual(snapshot.timelineRail.visibleEndSeconds, 610)
        XCTAssertEqual(snapshot.timelineRail.spans.map(\.title), ["Fixture Song", "AD"])
        XCTAssertEqual(snapshot.timelineRail.markers.map(\.title), ["AD", "AD"])
        XCTAssertTrue(snapshot.timelineItems.contains { $0.subtitle?.contains("Opening alpha words") == true })
    }

    func testTimelineFallsBackToSpeakerTurnsWhenTranscriptRowsHaveNoSpeakerLabel() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Diarized Stream",
            streamType: "hls",
            source: "https://example.test/live.m3u8",
            createdAt: "2026-05-01T15:00:00Z"
        )
        let writer = IngestPersistence(database: temporary.database)
        let runID = try writer.createRun(
            streamID: stream.id,
            startedAt: "2026-05-01T15:00:01Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 0,
            startedAt: "2026-05-01T15:00:02Z",
            endedAt: "2026-05-01T15:00:12Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                segments: [
                    TranscriptSegmentDraft(sequence: 0, speakerLabel: nil, startSeconds: 0, endSeconds: 2, text: "first speaker text"),
                    TranscriptSegmentDraft(sequence: 1, speakerLabel: nil, startSeconds: 2, endSeconds: 4, text: "second speaker text"),
                    TranscriptSegmentDraft(sequence: 2, speakerLabel: nil, startSeconds: 4, endSeconds: 6, text: "first speaker returns"),
                ],
                speakerTurns: [
                    SpeakerTurnDraft(speakerLabel: "speaker-S1", startSeconds: 0, endSeconds: 2, confidence: 0.9),
                    SpeakerTurnDraft(speakerLabel: "speaker-S2", startSeconds: 2, endSeconds: 4, confidence: 0.9),
                    SpeakerTurnDraft(speakerLabel: "speaker-S1", startSeconds: 4, endSeconds: 6, confidence: 0.9),
                ],
                createdAt: "2026-05-01T15:00:03Z"
            )
        )
        let store = StreamAppTimelineStore(database: temporary.database)

        let snapshot = try store.snapshot(
            request: StreamAppTimelineRequest(
                streamID: stream.id,
                paragraphLimit: 10,
                timelineLimit: 10,
                lookbackSeconds: nil,
                refreshedAt: "2026-05-01T16:00:00Z"
            )
        )

        XCTAssertEqual(
            snapshot.timelineItems.filter { $0.kind == .transcript }.map { "\($0.title):\($0.subtitle ?? "")" },
            [
                "speaker-S1:first speaker text",
                "speaker-S2:second speaker text",
                "speaker-S1:first speaker returns",
            ]
        )
    }

    func testClearTimelineDeletesSelectedStreamTranscriptAndMetadataRowsOnly() throws {
        let fixture = try makeFixture()
        let store = StreamAppTimelineStore(database: fixture.temporary.database)

        let deletedCount = try store.clearTimeline(streamID: fixture.mainStreamID)

        XCTAssertGreaterThan(deletedCount, 3)
        let counts = try fixture.temporary.database.read { db in
            try (
                mainSegments: Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM transcript_segments
                        JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
                        WHERE ingest_runs.stream_id = ?
                        """,
                    arguments: [fixture.mainStreamID]
                ),
                mainWords: Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM transcript_words
                        JOIN ingest_chunks ON ingest_chunks.id = transcript_words.chunk_id
                        JOIN ingest_runs ON ingest_runs.id = ingest_chunks.run_id
                        WHERE ingest_runs.stream_id = ?
                        """,
                    arguments: [fixture.mainStreamID]
                ),
                mainFts: Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM transcript_segments_fts
                        JOIN transcript_segments ON transcript_segments.id = transcript_segments_fts.rowid
                        JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
                        WHERE ingest_runs.stream_id = ?
                    """,
                    arguments: [fixture.mainStreamID]
                ),
                mainEvents: Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM ad_events
                        JOIN ingest_runs ON ingest_runs.id = ad_events.run_id
                        WHERE ingest_runs.stream_id = ?
                        """,
                    arguments: [fixture.mainStreamID]
                ),
                mainSongPlays: Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM song_plays WHERE stream_id = ?",
                    arguments: [fixture.mainStreamID]
                ),
                mainSpeakerTurns: Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM speaker_turns
                        JOIN ingest_runs ON ingest_runs.id = speaker_turns.run_id
                        WHERE ingest_runs.stream_id = ?
                    """,
                    arguments: [fixture.mainStreamID]
                ),
                mainHLSSegments: Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM hls_ingest_segments WHERE stream_id = ?",
                    arguments: [fixture.mainStreamID]
                ),
                otherSegments: Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM transcript_segments
                        JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
                        WHERE ingest_runs.stream_id = ?
                        """,
                    arguments: [fixture.otherStreamID]
                ),
                otherHLSSegments: Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM hls_ingest_segments WHERE stream_id = ?",
                    arguments: [fixture.otherStreamID]
                )
            )
        }

        XCTAssertEqual(counts.mainSegments, 0)
        XCTAssertEqual(counts.mainWords, 0)
        XCTAssertEqual(counts.mainFts, 0)
        XCTAssertEqual(counts.mainEvents, 0)
        XCTAssertEqual(counts.mainSongPlays, 0)
        XCTAssertEqual(counts.mainSpeakerTurns, 0)
        XCTAssertEqual(counts.mainHLSSegments, 2)
        XCTAssertEqual(counts.otherSegments, 2)
        XCTAssertEqual(counts.otherHLSSegments, 1)
        let snapshot = try store.snapshot(request: StreamAppTimelineRequest(streamID: fixture.mainStreamID))
        XCTAssertEqual(snapshot.transcriptParagraphs, [])
        XCTAssertEqual(snapshot.timelineItems, [])
        XCTAssertEqual(snapshot.recentMetadata, [])
    }

    func testTimelineDoesNotSurfaceFingerprintUnknownSongsAsMetadata() throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)
        let runID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T15:10:00Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 7,
            segmentURI: "main-007.ts",
            startedAt: "2026-05-01T15:10:01Z",
            endedAt: "2026-05-01T15:10:07Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                songPlays: [
                    SongPlayDraft(
                        song: UnresolvedSongDraft(
                            songKey: "fingerprint:abc123",
                            title: nil,
                            artist: nil,
                            displayName: "Unknown song (abc123)",
                            isUnknown: true
                        ),
                        startSeconds: 31,
                        endSeconds: 37,
                        source: "deterministic_fingerprint"
                    ),
                    SongPlayDraft(
                        song: UnresolvedSongDraft(
                            songKey: "fingerprint:def456",
                            title: nil,
                            artist: nil,
                            displayName: "Unknown song (def456)",
                            isUnknown: true
                        ),
                        startSeconds: 37,
                        endSeconds: 43,
                        source: "chromaprint"
                    )
                ],
                createdAt: "2026-05-01T15:10:02Z"
            )
        )

        let snapshot = try StreamAppTimelineStore(database: fixture.temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 35,
                    liveEdgeSeconds: 40
                ),
                paragraphLimit: 5,
                wordLimitPerParagraph: 5,
                metadataLimit: 5,
                timelineLimit: 10,
                lookbackSeconds: 60,
                hideDeterministicUnknownSongs: true,
                refreshedAt: "2026-05-01T16:00:02Z"
            )
        )

        XCTAssertFalse(snapshot.recentMetadata.contains { $0.title.hasPrefix("Unknown song") })
        XCTAssertFalse(snapshot.timelineItems.contains { $0.title.hasPrefix("Unknown song") })
    }

    func testTimelineKeepsDistinctConsecutiveSongMetadataChanges() throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)
        let runID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T15:20:00Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 20,
            segmentURI: "main-020.ts",
            startedAt: "2026-05-01T15:20:01Z",
            endedAt: "2026-05-01T15:20:07Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                songPlays: [
                    SongPlayDraft(
                        song: song(title: "First stale", artist: "Artist A"),
                        startSeconds: 40,
                        endSeconds: 50,
                        source: "timed_id3"
                    ),
                    SongPlayDraft(
                        song: song(title: "Second stale", artist: "Artist B"),
                        startSeconds: 50,
                        endSeconds: 60,
                        source: "timed_id3"
                    ),
                    SongPlayDraft(
                        song: song(title: "Current chunk song", artist: "Artist C"),
                        startSeconds: 60,
                        endSeconds: 70,
                        source: "timed_id3"
                    ),
                ],
                createdAt: "2026-05-01T15:20:02Z"
            )
        )

        let snapshot = try StreamAppTimelineStore(database: fixture.temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                paragraphLimit: 5,
                metadataLimit: 10,
                timelineLimit: 10,
                lookbackSeconds: nil,
                refreshedAt: "2026-05-01T16:00:02Z"
            )
        )

        XCTAssertEqual(
            snapshot.timelineItems.filter { $0.kind == .song }.map(\.title),
            ["Fixture Song", "First stale", "Second stale", "Current chunk song"]
        )
    }

    func testTimelineReadsSongMetadataFromSCTE35MarkerFields() throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)
        let runID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T15:40:00Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 40,
            segmentURI: "main-040.ts",
            startedAt: "2026-05-01T15:40:01Z",
            endedAt: "2026-05-01T15:40:07Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                adMarkers: [
                    AdMarker(
                        type: "SCTE35",
                        classification: .unknown,
                        source: "scte35",
                        pts: 80,
                        fields: [
                            "Title": "Wire Song",
                            "Artist": "Wire Artist",
                            "Album": "Wire Album",
                        ],
                        timestamp: "2026-05-01T15:41:20Z"
                    )
                ],
                createdAt: "2026-05-01T15:40:02Z"
            )
        )

        let snapshot = try StreamAppTimelineStore(database: fixture.temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 80,
                    liveEdgeSeconds: 90
                ),
                paragraphLimit: 5,
                metadataLimit: 10,
                timelineLimit: 10,
                lookbackSeconds: 120,
                refreshedAt: "2026-05-01T16:00:02Z"
            )
        )

        XCTAssertEqual(snapshot.currentMetadata?.title, "Wire Song")
        XCTAssertEqual(snapshot.currentMetadata?.artist, "Wire Artist")
        XCTAssertEqual(snapshot.currentMetadata?.subtitle, "Wire Album")
        XCTAssertTrue(snapshot.timelineItems.contains { $0.kind == .song && $0.title == "Wire Song" })
    }

    func testTimelineSuppressesID3MarkerRowsWhenSongPlayHasSameTrack() throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)
        let runID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T15:45:00Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 45,
            segmentURI: "main-045.ts",
            startedAt: "2026-05-01T15:45:01Z",
            endedAt: "2026-05-01T15:45:31Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                adMarkers: [
                    AdMarker(
                        type: "ID3",
                        classification: .unknown,
                        source: "hls_segment",
                        pts: 100,
                        tags: [
                            "TIT2": .string("The Great Divide"),
                            "TPE1": .string("Noah Kahan"),
                            "TALB": .string("The Great Divide"),
                        ]
                    ),
                    AdMarker(
                        type: "ID3",
                        classification: .unknown,
                        source: "hls_segment",
                        pts: 112,
                        tags: [
                            "TIT2": .string("The Great Divide"),
                            "TPE1": .string("Noah Kahan"),
                            "TALB": .string("The Great Divide"),
                        ]
                    )
                ],
                songPlays: [
                    SongPlayDraft(
                        song: song(title: "The Great Divide", artist: "Noah Kahan"),
                        startSeconds: 100,
                        endSeconds: 130,
                        source: "timed_id3"
                    )
                ],
                createdAt: "2026-05-01T15:45:02Z"
            )
        )

        let snapshot = try StreamAppTimelineStore(database: fixture.temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                paragraphLimit: 5,
                metadataLimit: 20,
                timelineLimit: 20,
                lookbackSeconds: nil,
                refreshedAt: "2026-05-01T16:00:02Z"
            )
        )

        XCTAssertEqual(
            snapshot.timelineItems.filter { $0.title == "The Great Divide" }.map { "\($0.kind.rawValue):\($0.title):\($0.speakerDisplay?.displayLabel ?? "-")" },
            ["song:The Great Divide:Noah Kahan"]
        )
    }

    func testTimelineSuppressesRepeatedSCTETitleOnlyRowsWhenArtistBackedSongPlayExists() throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)
        let runID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T15:46:00Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 46,
            segmentURI: "main-046.ts",
            startedAt: "2026-05-01T15:46:01Z",
            endedAt: "2026-05-01T15:46:31Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                adMarkers: [
                    AdMarker(
                        type: "SCTE35",
                        classification: .unknown,
                        source: "hls_segment",
                        pts: 100,
                        fields: ["Title": .string("The Great Divide")]
                    ),
                    AdMarker(
                        type: "SCTE35",
                        classification: .unknown,
                        source: "hls_segment",
                        pts: 108,
                        fields: ["Title": .string("The Great Divide")]
                    ),
                    AdMarker(
                        type: "SCTE35",
                        classification: .unknown,
                        source: "hls_segment",
                        pts: 116,
                        fields: ["Title": .string("The Great Divide")]
                    ),
                ],
                songPlays: [
                    SongPlayDraft(
                        song: song(title: "The Great Divide", artist: "Noah Kahan"),
                        startSeconds: 100,
                        endSeconds: 140,
                        source: "timed_id3"
                    )
                ],
                createdAt: "2026-05-01T15:46:02Z"
            )
        )

        let snapshot = try StreamAppTimelineStore(database: fixture.temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                paragraphLimit: 5,
                metadataLimit: 20,
                timelineLimit: 20,
                lookbackSeconds: nil,
                refreshedAt: "2026-05-01T16:00:02Z"
            )
        )

        XCTAssertEqual(
            snapshot.timelineItems.filter { $0.title == "The Great Divide" }.map { "\($0.kind.rawValue):\($0.title):\($0.speakerDisplay?.displayLabel ?? "-")" },
            ["song:The Great Divide:Noah Kahan"]
        )
    }

    func testTimelineCoalescesRepeatedID3MarkersWhenSongPlayIsOutsideLiveWindow() throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)
        let runID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T15:45:00Z",
            status: .running
        )
        for (index, pts) in [0.0, 8.0, 16.0, 24.0].enumerated() {
            let chunkID = try writer.createChunk(
                runID: runID,
                sequence: 60 + index,
                segmentURI: "main-06\(index).ts",
                startedAt: "2026-05-01T15:45:\(String(format: "%02d", index + 1))Z",
                endedAt: "2026-05-01T15:45:\(String(format: "%02d", index + 2))Z"
            )
            try writer.persistTimeline(
                IngestChunkTimeline(
                    runID: runID,
                    chunkID: chunkID,
                    adMarkers: [
                        AdMarker(
                            type: "ID3",
                            classification: .unknown,
                            source: "hls_segment",
                            pts: pts,
                            tags: [
                                "TIT2": .string("The Great Divide"),
                                "TPE1": .string("Noah Kahan"),
                                "TALB": .string("The Great Divide"),
                            ],
                            timestamp: "2026-05-01T15:45:\(String(format: "%02d", index + 1))Z"
                        )
                    ],
                    createdAt: "2026-05-01T15:45:\(String(format: "%02d", index + 1))Z"
                )
            )
        }

        let snapshot = try StreamAppTimelineStore(database: fixture.temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 24,
                    liveEdgeSeconds: 24,
                    bufferedStartSeconds: 0,
                    bufferedEndSeconds: 24
                ),
                paragraphLimit: 5,
                metadataLimit: 20,
                timelineLimit: 20,
                lookbackSeconds: nil,
                refreshedAt: "2026-05-01T15:45:30Z"
            )
        )

        let matchingRows = snapshot.timelineItems.filter { $0.title == "The Great Divide" }
        XCTAssertEqual(
            matchingRows.map { "\($0.kind.rawValue):\($0.title):\($0.speakerDisplay?.displayLabel ?? "-")" },
            ["song:The Great Divide:Noah Kahan"]
        )
        XCTAssertEqual(matchingRows.first?.endSeconds, 24)
    }

    func testTimelineDisplaysManifestCueRowsAsAdEvents() throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)
        let runID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T15:50:00Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 50,
            segmentURI: "main-050.ts",
            startedAt: "2026-05-01T15:50:01Z",
            endedAt: "2026-05-01T15:50:07Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                adMarkers: [
                    AdMarker(
                        type: "SCTE35",
                        classification: .unknown,
                        source: "hls_manifest",
                        tag: "#EXT-X-CUE-OUT",
                        pts: 90,
                        fields: ["cue": .string("out"), "DURATION": .string("60.0")]
                    ),
                    AdMarker(
                        type: "SCTE35",
                        classification: .unknown,
                        source: "hls_manifest",
                        tag: "#EXT-X-CUE-IN",
                        pts: 150,
                        fields: ["cue": .string("in")]
                    )
                ],
                createdAt: "2026-05-01T15:50:02Z"
            )
        )

        let snapshot = try StreamAppTimelineStore(database: fixture.temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                paragraphLimit: 5,
                metadataLimit: 20,
                timelineLimit: 20,
                lookbackSeconds: nil,
                refreshedAt: "2026-05-01T16:00:02Z"
            )
        )

        let adEvents = snapshot.timelineItems.filter {
            $0.id.hasPrefix("event:")
                && $0.title.hasPrefix("Ad break")
                && $0.startSeconds >= 90
        }
        XCTAssertEqual(adEvents.map(\.kind), [.event, .event])
        XCTAssertEqual(adEvents.map(\.title), ["Ad break start", "Ad break end"])
    }

    func testTimelineDisplaysICYAdDurationRowsAsAdEvents() throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)
        let runID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T15:52:00Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 52,
            segmentURI: "icy-0",
            startedAt: "2026-05-01T15:52:01Z",
            endedAt: "2026-05-01T15:52:31Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                adMarkers: [
                    AdMarker(
                        type: "ICY",
                        classification: .adStart,
                        source: "icy_stream",
                        pts: 110,
                        fields: [
                            "StreamTitle": .string(""),
                            "adw_ad": .string("true"),
                            "durationMilliseconds": .string("30119"),
                            "insertionType": .string("midroll"),
                        ]
                    )
                ],
                createdAt: "2026-05-01T15:52:02Z"
            )
        )

        let snapshot = try StreamAppTimelineStore(database: fixture.temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                paragraphLimit: 5,
                metadataLimit: 20,
                timelineLimit: 20,
                lookbackSeconds: nil,
                refreshedAt: "2026-05-01T16:00:02Z"
            )
        )

        let adEvent = try XCTUnwrap(snapshot.timelineItems.first {
            $0.id.hasPrefix("event:")
                && $0.startSeconds == 110
        })
        XCTAssertEqual(adEvent.kind, .event)
        XCTAssertEqual(adEvent.title, "Ad break start")
        XCTAssertEqual(adEvent.subtitle, "Duration 30.119s | icy")

        let adSpan = try XCTUnwrap(snapshot.timelineRail.spans.first { $0.id == "ad:\(adEvent.id)" })
        XCTAssertEqual(adSpan.title, "AD")
        XCTAssertEqual(adSpan.colorToken, "ad")
        XCTAssertEqual(adSpan.startSeconds, 110, accuracy: 0.001)
        XCTAssertEqual(adSpan.endSeconds, 140.119, accuracy: 0.001)
    }

    func testTimelineDisplaysID3AdvertisementRowsAsAdEvents() throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)
        let runID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T15:55:00Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 55,
            segmentURI: "main-055.ts",
            startedAt: "2026-05-01T15:55:01Z",
            endedAt: "2026-05-01T15:55:07Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                adMarkers: [
                    AdMarker(
                        type: "ID3",
                        classification: .unknown,
                        source: "hls_segment",
                        pts: 120,
                        tags: ["TXXX:ADVERTISEMENT": .string("ADVERTISEMENT")]
                    )
                ],
                createdAt: "2026-05-01T15:55:02Z"
            )
        )

        let snapshot = try StreamAppTimelineStore(database: fixture.temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                paragraphLimit: 5,
                metadataLimit: 20,
                timelineLimit: 20,
                lookbackSeconds: nil,
                refreshedAt: "2026-05-01T16:00:02Z"
            )
        )

        let adEvents = snapshot.timelineItems.filter { $0.title == "AD" && $0.source == "timed_id3" }
        XCTAssertEqual(adEvents.map(\.kind), [.event])
        XCTAssertEqual(adEvents.first?.subtitle, "timed_id3 | Advertisement")
        XCTAssertEqual(snapshot.timelineRail.markers.first { $0.id == adEvents.first?.id }?.colorToken, "ad")
    }

    func testTimelineTreatsStingrayPADULTHTMarkersAsAdBreaksForNonSongTranscripts() throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)
        let runID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T16:10:00Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 90,
            segmentURI: "stingray-ad.mp3",
            startedAt: "2026-05-01T16:10:01Z",
            endedAt: "2026-05-01T16:10:31Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                segments: [
                    segment(90, "speaker", 214, 226, "Stingray ad copy should remain visible."),
                ],
                adMarkers: [
                    AdMarker(
                        type: "ICY",
                        classification: .unknown,
                        source: "icy_stream",
                        pts: 204,
                        fields: [
                            "StreamTitle": .string("Stingray - PADULTHT26"),
                            "Artist": .string("Stingray"),
                            "Title": .string("PADULTHT26"),
                        ]
                    )
                ],
                songPlays: [
                    SongPlayDraft(
                        song: song(title: "Stressed Out", artist: "TWENTY ONE PILOTS"),
                        startSeconds: 0,
                        endSeconds: 360,
                        confidence: 0.99,
                        source: "icy"
                    )
                ],
                createdAt: "2026-05-01T16:10:02Z"
            )
        )

        let snapshot = try StreamAppTimelineStore(database: fixture.temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 230,
                    liveEdgeSeconds: 240
                ),
                paragraphLimit: 20,
                metadataLimit: 20,
                timelineLimit: 20,
                lookbackSeconds: 240,
                transcriptionPolicy: .nonSongs,
                refreshedAt: "2026-05-01T16:10:35Z"
            )
        )

        let adItem = try XCTUnwrap(snapshot.timelineItems.first { $0.startSeconds == 204 })
        XCTAssertEqual(adItem.kind, .event)
        XCTAssertEqual(adItem.title, "AD")
        XCTAssertEqual(adItem.subtitle, "PADULTHT26 | icy")
        XCTAssertTrue(adItem.isAd)
        XCTAssertEqual(adItem.colorToken, "ad")
        XCTAssertTrue(snapshot.timelineItems.contains { $0.subtitle == "Stingray ad copy should remain visible." })
        XCTAssertTrue(snapshot.timelineRail.spans.contains { $0.isAd && $0.startSeconds == 204 })
    }

    func testTimelineCollapsesSegmentRepeatedID3AdsInsideSCTEBreak() throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)
        let runID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T15:58:00Z",
            status: .running
        )
        for (index, pts) in [100.0, 106.0, 112.0, 118.0, 124.0, 130.0].enumerated() {
            let chunkID = try writer.createChunk(
                runID: runID,
                sequence: 70 + index,
                segmentURI: "main-ad-\(index).ts",
                startedAt: "2026-05-01T15:58:\(String(format: "%02d", index + 1))Z",
                endedAt: "2026-05-01T15:58:\(String(format: "%02d", index + 2))Z"
            )
            var adMarkers = [
                AdMarker(
                    type: "ID3",
                    classification: .adStart,
                    source: "hls_segment",
                    pts: pts,
                    tags: ["TXXX:type": .string("ADVERTISEMENT")]
                )
            ]
            if index == 0 {
                adMarkers.insert(
                    AdMarker(
                        type: "SCTE35",
                        classification: .adStart,
                        source: "hls_manifest",
                        tag: "#EXT-X-CUE-OUT",
                        pts: pts,
                        fields: ["DURATION": .string("60.0")]
                    ),
                    at: 0
                )
            }
            if index == 5 {
                adMarkers.append(
                    AdMarker(
                        type: "SCTE35",
                        classification: .adEnd,
                        source: "hls_manifest",
                        tag: "#EXT-X-CUE-IN",
                        pts: 160,
                        fields: ["cue": .string("in")]
                    )
                )
            }
            try writer.persistTimeline(
                IngestChunkTimeline(
                    runID: runID,
                    chunkID: chunkID,
                    adMarkers: adMarkers,
                    createdAt: "2026-05-01T15:58:\(String(format: "%02d", index + 1))Z"
                )
            )
        }

        let snapshot = try StreamAppTimelineStore(database: fixture.temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                paragraphLimit: 5,
                metadataLimit: 20,
                timelineLimit: 20,
                lookbackSeconds: nil,
                refreshedAt: "2026-05-01T16:00:02Z"
            )
        )

        let adItems = snapshot.timelineItems.filter { $0.title == "AD" }
        XCTAssertEqual(adItems.count, 1)
        XCTAssertEqual(adItems.first?.startSeconds, 100)
        let adSpans = snapshot.timelineRail.spans.filter { $0.isAd && $0.startSeconds >= 100 }
        XCTAssertEqual(
            adSpans.count,
            1,
            adSpans.map { "\($0.id):\($0.startSeconds)-\($0.endSeconds)" }.joined(separator: ", ")
        )
        XCTAssertEqual(adSpans.first?.colorToken, "ad")
    }

    func testTimelineKeepsNewestTimedMetadataWhenRunsReusePTS() throws {
        let fixture = try makeFixture()
        let writer = IngestPersistence(database: fixture.temporary.database)

        let staleRunID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T16:00:00Z",
            status: .completed
        )
        let staleChunkID = try writer.createChunk(
            runID: staleRunID,
            sequence: 1,
            segmentURI: "stale-001.ts",
            startedAt: "2026-05-01T16:00:00Z",
            endedAt: "2026-05-01T16:00:01Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: staleRunID,
                chunkID: staleChunkID,
                adMarkers: [
                    AdMarker(
                        type: "ID3",
                        classification: .unknown,
                        source: "hls_segment",
                        pts: 118,
                        tags: [
                            "TIT2": .string("Old Collision"),
                            "TPE1": .string("Old Artist"),
                        ],
                        timestamp: "2026-05-01T16:00:00Z"
                    )
                ],
                createdAt: "2026-05-01T16:00:00Z"
            )
        )

        let currentRunID = try writer.createRun(
            streamID: fixture.mainStreamID,
            startedAt: "2026-05-01T16:10:00Z",
            status: .completed
        )
        let currentChunkID = try writer.createChunk(
            runID: currentRunID,
            sequence: 1,
            segmentURI: "current-001.ts",
            startedAt: "2026-05-01T16:10:00Z",
            endedAt: "2026-05-01T16:10:01Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: currentRunID,
                chunkID: currentChunkID,
                adMarkers: [
                    AdMarker(
                        type: "ID3",
                        classification: .unknown,
                        source: "hls_segment",
                        pts: 120,
                        tags: [
                            "TIT2": .string("Current Collision"),
                            "TPE1": .string("Current Artist"),
                        ],
                        timestamp: "2026-05-01T16:10:00Z"
                    )
                ],
                createdAt: "2026-05-01T16:10:00Z"
            )
        )

        let snapshot = try StreamAppTimelineStore(database: fixture.temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 120,
                    liveEdgeSeconds: 180,
                    bufferedStartSeconds: 0,
                    bufferedEndSeconds: 180
                ),
                paragraphLimit: 5,
                metadataLimit: 20,
                timelineLimit: 20,
                lookbackSeconds: nil,
                refreshedAt: "2026-05-01T16:10:02Z"
            )
        )

        let songTitles = snapshot.timelineItems.filter { $0.kind == .song }.map(\.title)
        XCTAssertTrue(songTitles.contains("Current Collision"))
        XCTAssertFalse(songTitles.contains("Old Collision"))
    }

    func testTimelineTranscriptParagraphsStayBoundedWhenSpeakerDoesNotChange() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Long Talk",
            streamType: "hls",
            source: "https://example.test/live.m3u8",
            createdAt: "2026-05-01T15:00:00Z"
        )
        let writer = IngestPersistence(database: temporary.database)
        let runID = try writer.createRun(
            streamID: stream.id,
            startedAt: "2026-05-01T15:00:01Z",
            status: .running
        )
        let chunkID = try writer.createChunk(
            runID: runID,
            sequence: 0,
            segmentURI: "main-000.ts",
            startedAt: "2026-05-01T15:00:02Z",
            endedAt: "2026-05-01T15:02:02Z"
        )
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: runID,
                chunkID: chunkID,
                segments: [
                    segment(0, "speaker", 0, 30, "first long thought"),
                    segment(1, "speaker", 30, 60, "second long thought"),
                    segment(2, "speaker", 60, 90, "third long thought"),
                ],
                createdAt: "2026-05-01T15:00:03Z"
            )
        )

        let snapshot = try StreamAppTimelineStore(database: temporary.database).snapshot(
            request: StreamAppTimelineRequest(
                streamID: stream.id,
                paragraphLimit: 5,
                wordLimitPerParagraph: 5,
                metadataLimit: 5,
                timelineLimit: 10,
                lookbackSeconds: 120,
                refreshedAt: "2026-05-01T16:00:00Z"
            )
        )

        XCTAssertEqual(
            snapshot.timelineItems.filter { $0.kind == .transcript }.map(\.subtitle),
            ["first long thought", "second long thought", "third long thought"]
        )
    }

    func testSpeakerDisplayOverridesPersistAndDoNotMutateProviderRowsOrFts() throws {
        let fixture = try makeFixture()
        let store = StreamAppTimelineStore(database: fixture.temporary.database)

        try store.updateSpeakerDisplay(
            streamID: fixture.mainStreamID,
            rawLabel: "host",
            displayLabel: "Morning Host",
            colorToken: "violet",
            updatedAt: "2026-05-01T16:05:00Z"
        )

        let reloaded = StreamAppTimelineStore(database: fixture.temporary.database)
        let snapshot = try reloaded.snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: nil,
                paragraphLimit: 5,
                wordLimitPerParagraph: 5,
                metadataLimit: 5,
                timelineLimit: 10,
                lookbackSeconds: 60,
                refreshedAt: "2026-05-01T16:05:01Z"
            )
        )

        XCTAssertEqual(snapshot.speakers.first { $0.rawLabel == "host" }?.displayLabel, "Morning Host")
        XCTAssertEqual(snapshot.speakers.first { $0.rawLabel == "host" }?.colorToken, "violet")
        XCTAssertEqual(snapshot.transcriptParagraphs.first?.speakerDisplay.displayLabel, "Morning Host")

        let providerRows = try fixture.temporary.database.read { db in
            try (
                segmentLabels: String.fetchAll(db, sql: "SELECT DISTINCT speaker_label FROM transcript_segments ORDER BY speaker_label"),
                wordLabels: String.fetchAll(db, sql: "SELECT DISTINCT speaker_label FROM transcript_words ORDER BY speaker_label"),
                turnLabels: String.fetchAll(db, sql: "SELECT DISTINCT speaker_label FROM speaker_turns ORDER BY speaker_label"),
                ftsLabels: String.fetchAll(db, sql: "SELECT DISTINCT speaker_label FROM transcript_segments_fts ORDER BY speaker_label")
            )
        }

        XCTAssertEqual(providerRows.segmentLabels, ["caller", "dj", "guest", "host"])
        XCTAssertEqual(providerRows.wordLabels, ["caller", "dj", "guest", "host"])
        XCTAssertEqual(providerRows.turnLabels, ["caller", "dj", "guest", "host"])
        XCTAssertEqual(providerRows.ftsLabels, ["caller", "dj", "guest", "host"])
    }

    func testFocusedSnapshotIncludesOlderSegmentOutsideNewestWindowAndLookback() throws {
        let fixture = try makeFixture()
        let store = StreamAppTimelineStore(database: fixture.temporary.database)
        let focusedSegmentID = try fixture.temporary.database.read { db in
            try XCTUnwrap(
                Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM transcript_segments WHERE text = ?",
                    arguments: ["Opening alpha words"]
                )
            )
        }

        try store.updateSpeakerDisplay(
            streamID: fixture.mainStreamID,
            rawLabel: "host",
            displayLabel: "Morning Host",
            colorToken: "violet",
            updatedAt: "2026-05-01T16:10:00Z"
        )

        let snapshot = try store.snapshot(
            request: StreamAppTimelineRequest(
                streamID: fixture.mainStreamID,
                player: AppPlayerTimelineSnapshot(
                    streamID: fixture.mainStreamID,
                    positionSeconds: 28,
                    liveEdgeSeconds: 30,
                    bufferedStartSeconds: 0,
                    bufferedEndSeconds: 30
                ),
                paragraphLimit: 2,
                wordLimitPerParagraph: 2,
                metadataLimit: 2,
                timelineLimit: 6,
                lookbackSeconds: 5,
                focusedSegmentID: focusedSegmentID,
                refreshedAt: "2026-05-01T16:10:01Z"
            )
        )

        XCTAssertEqual(snapshot.transcriptParagraphs.map(\.text), ["Opening alpha words", "Middle beta words"])
        XCTAssertEqual(snapshot.transcriptParagraphs.first?.id, focusedSegmentID)
        XCTAssertEqual(snapshot.transcriptParagraphs.first?.speakerDisplay.displayLabel, "Morning Host")
        XCTAssertEqual(snapshot.transcriptParagraphs.first?.words.map(\.text), ["Opening", "alpha"])
        XCTAssertEqual(snapshot.timelineItems.first { $0.id == "transcript:\(focusedSegmentID)" }?.isSeekable, true)
        XCTAssertEqual(snapshot.diagnostics.focusedSegmentID, focusedSegmentID)
    }

    func testFocusedSnapshotRejectsInvalidMissingAndCrossStreamSegmentIDs() throws {
        let fixture = try makeFixture()
        let store = StreamAppTimelineStore(database: fixture.temporary.database)
        let otherSegmentID = try fixture.temporary.database.read { db in
            try XCTUnwrap(
                Int64.fetchOne(
                    db,
                    sql: """
                        SELECT transcript_segments.id
                        FROM transcript_segments
                        JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
                        WHERE ingest_runs.stream_id = ?
                        ORDER BY transcript_segments.id
                        LIMIT 1
                        """,
                    arguments: [fixture.otherStreamID]
                )
            )
        }

        XCTAssertThrowsError(
            try store.snapshot(
                request: StreamAppTimelineRequest(
                    streamID: fixture.mainStreamID,
                    focusedSegmentID: 0
                )
            )
        ) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .invalidFocusedSegmentID)
        }
        XCTAssertThrowsError(
            try store.snapshot(
                request: StreamAppTimelineRequest(
                    streamID: fixture.mainStreamID,
                    focusedSegmentID: 9_999_999
                )
            )
        ) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .focusedSegmentNotFound)
        }
        XCTAssertThrowsError(
            try store.snapshot(
                request: StreamAppTimelineRequest(
                    streamID: fixture.mainStreamID,
                    focusedSegmentID: otherSegmentID
                )
            )
        ) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .focusedSegmentNotFound)
        }
    }

    func testValidationRejectsMalformedInputsBeforeSql() throws {
        let fixture = try makeFixture()
        let store = StreamAppTimelineStore(database: fixture.temporary.database)

        XCTAssertThrowsError(try store.snapshot(request: StreamAppTimelineRequest(streamID: -1))) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .invalidStreamID)
        }
        XCTAssertThrowsError(try store.snapshot(request: StreamAppTimelineRequest(streamID: fixture.mainStreamID, paragraphLimit: 0))) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .invalidLimit("paragraphLimit"))
        }
        XCTAssertThrowsError(try store.snapshot(request: StreamAppTimelineRequest(streamID: fixture.mainStreamID, lookbackSeconds: -1))) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .invalidWindow)
        }
        XCTAssertThrowsError(try store.snapshot(request: StreamAppTimelineRequest(streamID: 9_999))) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .streamNotFound)
        }
        XCTAssertThrowsError(try store.updateSpeakerDisplay(streamID: fixture.mainStreamID, rawLabel: " ", displayLabel: "Host")) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .emptyRawSpeakerLabel)
        }
        XCTAssertThrowsError(try store.updateSpeakerDisplay(streamID: fixture.mainStreamID, rawLabel: "host", displayLabel: " ")) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .emptyDisplayLabel)
        }
        XCTAssertThrowsError(try store.updateSpeakerDisplay(streamID: fixture.mainStreamID, rawLabel: "host", displayLabel: String(repeating: "A", count: 65))) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .displayLabelTooLong(max: 64))
        }
        XCTAssertThrowsError(try store.updateSpeakerDisplay(streamID: fixture.mainStreamID, rawLabel: "host", displayLabel: "Host", colorToken: "DROP TABLE")) { error in
            XCTAssertEqual(error as? StreamAppTimelineStoreError, .invalidColorToken("DROP TABLE"))
        }
    }

    func testEmptyTimelineReturnsDiagnosticsWithValidationErrors() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(
            name: "Empty",
            streamType: "hls",
            source: "https://example.test/empty.m3u8?token=secret",
            createdAt: "2026-05-01T17:00:00Z"
        )
        let store = StreamAppTimelineStore(database: temporary.database)

        let snapshot = try store.snapshot(
            request: StreamAppTimelineRequest(
                streamID: stream.id,
                player: AppPlayerTimelineSnapshot(streamID: stream.id, positionSeconds: 4, liveEdgeSeconds: 8),
                refreshedAt: "2026-05-01T17:00:01Z"
            )
        )

        XCTAssertEqual(snapshot.transcriptParagraphs, [])
        XCTAssertNil(snapshot.currentMetadata)
        XCTAssertEqual(snapshot.timelineItems, [])
        XCTAssertNil(snapshot.diagnostics.latestSegmentEndSeconds)
        XCTAssertEqual(snapshot.diagnostics.lagSeconds, 4)
        XCTAssertEqual(snapshot.diagnostics.validationErrors, [])
        XCTAssertFalse(String(describing: snapshot).contains("token=secret"))
    }

    private struct Fixture {
        var temporary: TemporarySoundingDatabase
        var mainStreamID: Int64
        var otherStreamID: Int64
    }

    private func makeFixture() throws -> Fixture {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        let main = try registry.add(
            name: "Managed Main",
            streamType: "hls",
            source: "https://example.test/main.m3u8?token=fixture-secret",
            createdAt: "2026-05-01T15:00:00Z"
        )
        let other = try registry.add(
            name: "Managed Other",
            streamType: "icy",
            source: "https://example.test/other-radio?token=other-secret",
            createdAt: "2026-05-01T15:30:00Z"
        )

        let writer = IngestPersistence(database: temporary.database)
        let mainRunID = try writer.createRun(streamID: main.id, startedAt: "2026-05-01T15:00:01Z", status: .running)
        let mainChunk0ID = try writer.createChunk(runID: mainRunID, sequence: 0, segmentURI: "main-000.ts", startedAt: "2026-05-01T15:00:02Z", endedAt: "2026-05-01T15:00:12Z")
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: mainRunID,
                chunkID: mainChunk0ID,
                segments: [
                    segment(0, "host", 0, 10, "Opening alpha words"),
                    segment(1, "guest", 10, 20, "Middle beta words"),
                ],
                speakerTurns: [
                    SpeakerTurnDraft(speakerLabel: "host", startSeconds: 0, endSeconds: 10, confidence: 0.91),
                    SpeakerTurnDraft(speakerLabel: "guest", startSeconds: 10, endSeconds: 20, confidence: 0.88),
                ],
                adMarkers: [
                    AdMarker(type: "splice_insert", classification: .adStart, source: "manifest", pts: 9, segment: "main-000.ts", timestamp: "2026-05-01T15:00:09Z")
                ],
                songPlays: [
                    SongPlayDraft(song: knownSong, startSeconds: 5, endSeconds: 25, confidence: 0.92, source: "fixture")
                ],
                createdAt: "2026-05-01T15:00:03Z"
            )
        )
        let mainChunk1ID = try writer.createChunk(runID: mainRunID, sequence: 1, segmentURI: "main-001.ts", startedAt: "2026-05-01T15:00:12Z", endedAt: "2026-05-01T15:00:22Z")
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: mainRunID,
                chunkID: mainChunk1ID,
                segments: [segment(2, "host", 20, 30, "Closing gamma words")],
                speakerTurns: [SpeakerTurnDraft(speakerLabel: "host", startSeconds: 20, endSeconds: 30, confidence: 0.86)],
                adMarkers: [AdMarker(type: "splice_insert", classification: .adEnd, source: "manifest", pts: 21, segment: "main-001.ts", timestamp: "2026-05-01T15:00:21Z")],
                createdAt: "2026-05-01T15:00:13Z"
            )
        )
        try insertHLSIngestSegment(
            database: temporary.database,
            streamID: main.id,
            mediaSequence: 7,
            segmentIdentity: "main-000.ts",
            runID: mainRunID,
            chunkID: mainChunk0ID
        )
        try insertHLSIngestSegment(
            database: temporary.database,
            streamID: main.id,
            mediaSequence: 8,
            segmentIdentity: "main-001.ts",
            runID: mainRunID,
            chunkID: mainChunk1ID
        )

        let otherRunID = try writer.createRun(streamID: other.id, startedAt: "2026-05-01T15:30:01Z", status: .running)
        let otherChunkID = try writer.createChunk(runID: otherRunID, sequence: 0, segmentURI: "other-000", startedAt: "2026-05-01T15:30:02Z", endedAt: "2026-05-01T15:30:12Z")
        try writer.persistTimeline(
            IngestChunkTimeline(
                runID: otherRunID,
                chunkID: otherChunkID,
                segments: [
                    segment(0, "dj", 0, 9, "Other station intro"),
                    segment(1, "caller", 9, 18, "Other station call"),
                ],
                speakerTurns: [
                    SpeakerTurnDraft(speakerLabel: "dj", startSeconds: 0, endSeconds: 9, confidence: 0.82),
                    SpeakerTurnDraft(speakerLabel: "caller", startSeconds: 9, endSeconds: 18, confidence: 0.80),
                ],
                createdAt: "2026-05-01T15:30:03Z"
            )
        )
        try insertHLSIngestSegment(
            database: temporary.database,
            streamID: other.id,
            mediaSequence: 1,
            segmentIdentity: "other-000",
            runID: otherRunID,
            chunkID: otherChunkID
        )

        return Fixture(temporary: temporary, mainStreamID: main.id, otherStreamID: other.id)
    }

    private func insertHLSIngestSegment(
        database: SoundingDatabase,
        streamID: Int64,
        mediaSequence: Int,
        segmentIdentity: String,
        runID: Int64,
        chunkID: Int64
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO hls_ingest_segments (
                        stream_id, media_sequence, segment_identity, segment_identity_hash,
                        claimed_run_id, chunk_id, claimed_at, finalized_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    streamID,
                    mediaSequence,
                    segmentIdentity,
                    "fixture-\(mediaSequence)",
                    runID,
                    chunkID,
                    "2026-05-01T15:00:00Z",
                    "2026-05-01T15:00:01Z",
                    "2026-05-01T15:00:01Z"
                ]
            )
        }
    }

    private var knownSong: UnresolvedSongDraft {
        UnresolvedSongDraft(
            songKey: "fixture:artist:song",
            title: "Fixture Song",
            artist: "Fixture Artist",
            album: "Timeline Proofs",
            isrc: "US-S02-26-00001",
            displayName: "Fixture Artist — Fixture Song"
        )
    }

    private func song(title: String, artist: String) -> UnresolvedSongDraft {
        UnresolvedSongDraft(
            songKey: "fixture:\(artist):\(title)",
            title: title,
            artist: artist,
            album: "Metadata Fixture",
            displayName: "\(artist) — \(title)"
        )
    }

    private func unknownSong(songKey: String) -> UnresolvedSongDraft {
        UnresolvedSongDraft(
            songKey: songKey,
            displayName: songKey,
            isUnknown: true
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
}

private actor StoreRecordingAdVerifier: TranscriptAdVerifier {
    struct Call: Equatable {
        var paragraph: StreamAppTranscriptParagraph
        var neighbors: [StreamAppTranscriptParagraph]
    }

    private var calls: [Call] = []
    private let response: TranscriptAdVerification

    init(response: TranscriptAdVerification) {
        self.response = response
    }

    func verify(
        paragraph: StreamAppTranscriptParagraph,
        neighbors: [StreamAppTranscriptParagraph]
    ) async throws -> TranscriptAdVerification {
        calls.append(Call(paragraph: paragraph, neighbors: neighbors))
        return response
    }

    func recordedCalls() -> [Call] {
        calls
    }
}
