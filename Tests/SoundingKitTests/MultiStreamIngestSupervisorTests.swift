import Foundation
import GRDB
import XCTest

@testable import SoundingKit

final class MultiStreamIngestSupervisorTests: XCTestCase {
    func testConcurrentStreamsShareInferenceQueueAndRemainSearchDistinct() async throws {
        let temporary = try TemporarySoundingDatabase()
        let decodeGate = DecodeBarrier(expectedSources: ["https://user:pass@example.test/alpha.m3u8?token=secret", "https://user:pass@example.test/bravo.m3u8?token=secret"])
        let mlGate = MLGate()
        let baseTranscriber = TrackingTranscriber(gate: mlGate)
        let baseDiarizer = TrackingDiarizer(gate: mlGate)
        let queue = InferenceQueue()
        let registry = DecoderRegistry(decoders: [
            "https://user:pass@example.test/alpha.m3u8?token=secret": BarrierDecoder(
                gate: decodeGate,
                chunks: [Self.chunk(sequence: 0, streamName: "alpha")]
            ),
            "https://user:pass@example.test/bravo.m3u8?token=secret": BarrierDecoder(
                gate: decodeGate,
                chunks: [Self.chunk(sequence: 0, streamName: "bravo")]
            )
        ])
        let supervisor = MultiStreamIngestSupervisor(
            database: temporary.database,
            decoderFactory: { request in
                try await registry.decoder(for: request.source)
            },
            transcriber: QueuedTranscriber(baseTranscriber, queue: queue),
            diarizer: QueuedDiarizer(baseDiarizer, queue: queue),
            now: { "2026-05-01T00:00:00Z" }
        )

        let task = Task {
            try await supervisor.run([
                StreamIngestRequest(source: "https://user:pass@example.test/alpha.m3u8?token=secret", streamType: .hls, maxChunks: 1),
                StreamIngestRequest(source: "https://user:pass@example.test/bravo.m3u8?token=secret", streamType: .hls, maxChunks: 1)
            ])
        }
        await decodeGate.waitUntilAllRequested()
        let startedBeforeRelease = await mlGate.startedCount()
        XCTAssertEqual(startedBeforeRelease, 0, "ML must not start until both decoders have been requested at the pipeline boundary.")
        await decodeGate.release()

        let outcomes = try await task.value

        XCTAssertEqual(outcomes.map(\.status), [.completed, .completed])
        XCTAssertEqual(outcomes.map(\.processedChunks), [1, 1])
        XCTAssertEqual(outcomes.map(\.diagnosticCount), [0, 0])
        XCTAssertEqual(Set(outcomes.compactMap(\.streamID)).count, 2)
        XCTAssertEqual(Set(outcomes.compactMap(\.runID)).count, 2)
        XCTAssertEqual(outcomes.map(\.sourceDescription), [
            "https://example.test/alpha.m3u8",
            "https://example.test/bravo.m3u8"
        ])
        let maxActiveML = await mlGate.maxActive()
        XCTAssertEqual(maxActiveML, 1)
        let queueSnapshot = await queue.snapshot()
        XCTAssertEqual(queueSnapshot.submitted, 4)
        XCTAssertEqual(queueSnapshot.completed, 4)
        XCTAssertEqual(queueSnapshot.isBusy, false)

        let rowCounts = try temporary.database.read { db in
            try [
                "streams": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM streams"),
                "completed_runs": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_runs WHERE status = 'completed'"),
                "chunks": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_chunks"),
                "zero_sequence_chunks": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_chunks WHERE sequence = 0"),
                "segments": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments"),
                "words": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_words"),
                "turns": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_turns"),
                "ads": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ad_events"),
                "diagnostics": Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingest_diagnostics")
            ]
        }
        XCTAssertEqual(rowCounts, [
            "streams": 2,
            "completed_runs": 2,
            "chunks": 2,
            "zero_sequence_chunks": 2,
            "segments": 2,
            "words": 8,
            "turns": 2,
            "ads": 2,
            "diagnostics": 0
        ])

        let query = TranscriptQuery(database: temporary.database)
        let searchResults = try query.search(phrase: "shared phrase", limit: 10)
        XCTAssertEqual(searchResults.count, 2)
        XCTAssertEqual(Set(searchResults.map(\.identity.streamID)).count, 2)
        XCTAssertEqual(Set(searchResults.map(\.identity.runID)).count, 2)
        XCTAssertEqual(Set(searchResults.map { $0.identity.streamSource }), [
            "https://example.test/alpha.m3u8",
            "https://example.test/bravo.m3u8"
        ])
        XCTAssertEqual(Set(searchResults.map { $0.identity.speakerLabel ?? "" }), ["alpha-speaker", "bravo-speaker"])
        XCTAssertEqual(Set(searchResults.map { $0.identity.sequence }), [0])

        let counts = try query.count(phrase: "shared phrase")
        XCTAssertEqual(counts.count, 2)
        XCTAssertEqual(Set(counts.map(\.streamID)), Set(searchResults.map(\.identity.streamID)))
        XCTAssertEqual(Set(counts.map(\.runID)), Set(searchResults.map(\.identity.runID)))
        XCTAssertEqual(Set(counts.map { $0.speakerLabel ?? "" }), ["alpha-speaker", "bravo-speaker"])
        XCTAssertEqual(counts.map(\.occurrenceCount), [1, 1])
        XCTAssertEqual(counts.map(\.matchingSegmentCount), [1, 1])
    }

    func testFatalStreamFailureDoesNotCancelSiblingAndOutcomeUsesRedactedDiagnostics() async throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = DecoderRegistry(decoders: [
            "https://user:pass@example.test/failing.m3u8?token=secret": FailingDecoder(
                error: FakeIngestError("decoder failed at /tmp/source-token=secret.wav for https://user:pass@example.test/failing.m3u8?token=secret")
            ),
            "https://user:pass@example.test/healthy.m3u8?token=secret": StaticDecoder(
                chunks: [Self.chunk(sequence: 0, streamName: "healthy")]
            )
        ])
        let queue = InferenceQueue()
        let supervisor = MultiStreamIngestSupervisor(
            database: temporary.database,
            decoderFactory: { request in
                try await registry.decoder(for: request.source)
            },
            transcriber: QueuedTranscriber(TrackingTranscriber(gate: MLGate()), queue: queue),
            diarizer: QueuedDiarizer(TrackingDiarizer(gate: MLGate()), queue: queue),
            now: { "2026-05-01T00:00:00Z" }
        )

        let outcomes = try await supervisor.run([
            StreamIngestRequest(source: "https://user:pass@example.test/failing.m3u8?token=secret", streamType: .hls, maxChunks: 1),
            StreamIngestRequest(source: "https://user:pass@example.test/healthy.m3u8?token=secret", streamType: .hls, maxChunks: 1)
        ])

        let failedOutcome = try XCTUnwrap(outcomes.first { $0.status == .failed })
        let completedOutcome = try XCTUnwrap(outcomes.first { $0.status == .completed })
        XCTAssertEqual(failedOutcome.processedChunks, 0)
        XCTAssertEqual(failedOutcome.diagnosticCount, 1)
        XCTAssertNotNil(failedOutcome.streamID)
        XCTAssertNotNil(failedOutcome.runID)
        XCTAssertTrue(
            failedOutcome.errorDescription?.contains("[redacted-path]") ?? false,
            failedOutcome.errorDescription ?? "nil"
        )
        XCTAssertFalse(
            failedOutcome.errorDescription?.contains("user:pass") ?? true,
            failedOutcome.errorDescription ?? "nil"
        )
        XCTAssertFalse(
            failedOutcome.errorDescription?.contains("token=secret") ?? true,
            failedOutcome.errorDescription ?? "nil"
        )
        XCTAssertEqual(completedOutcome.processedChunks, 1)

        let persisted = try temporary.database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT streams.source AS source, ingest_runs.status AS status,
                           ingest_diagnostics.reason AS reason, ingest_diagnostics.context_json AS context
                    FROM streams
                    JOIN ingest_runs ON ingest_runs.stream_id = streams.id
                    LEFT JOIN ingest_diagnostics ON ingest_diagnostics.run_id = ingest_runs.id
                    ORDER BY streams.id
                    """
            )
        }
        XCTAssertEqual(persisted.map { $0["status"] as String }, ["failed", "completed"])
        let failedContext: String = persisted.first?["context"] ?? ""
        XCTAssertTrue(failedContext.contains("[redacted-path]"), failedContext)
        XCTAssertFalse(failedContext.contains("user:pass"), failedContext)
        XCTAssertFalse(failedContext.contains("token=secret"), failedContext)

        let query = TranscriptQuery(database: temporary.database)
        let results = try query.search(phrase: "shared phrase", limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.identity.streamSource, "https://example.test/healthy.m3u8")
        XCTAssertEqual(results.first?.identity.speakerLabel, "healthy-speaker")
    }

    func testSupervisorLimitsConcurrentRequestExecutionWhenMaximumAllowsMoreStreams() async throws {
        let temporary = try TemporarySoundingDatabase()
        let factory = DelayedDecoderFactory()
        let supervisor = MultiStreamIngestSupervisor(
            database: temporary.database,
            maximumRequests: 3,
            maxConcurrentRequests: 1,
            decoderFactory: { request in try await factory.decoder(for: request) },
            transcriber: TrackingTranscriber(gate: MLGate()),
            diarizer: TrackingDiarizer(gate: MLGate()),
            now: { "2026-05-01T00:00:00Z" }
        )

        let outcomes = try await supervisor.run([
            StreamIngestRequest(source: "https://example.test/one.m3u8", streamType: .hls, maxChunks: 1),
            StreamIngestRequest(source: "https://example.test/two.m3u8", streamType: .hls, maxChunks: 1),
            StreamIngestRequest(source: "https://example.test/three.m3u8", streamType: .hls, maxChunks: 1)
        ])

        let statuses: [IngestRunStatus] = outcomes.map(\.status)
        let maxActive = await factory.maxActive()
        let requestedSources = await factory.requestedSources()

        XCTAssertEqual(statuses, [.completed, .completed, .completed])
        XCTAssertEqual(maxActive, 1)
        XCTAssertEqual(requestedSources, [
            "https://example.test/one.m3u8",
            "https://example.test/two.m3u8",
            "https://example.test/three.m3u8"
        ])
    }

    func testValidationRejectsEmptyTooManyAndUnboundedRequestsBeforeFactoryStarts() async throws {
        let temporary = try TemporarySoundingDatabase()
        let factory = CountingDecoderFactory()
        let supervisor = MultiStreamIngestSupervisor(
            database: temporary.database,
            maximumRequests: 2,
            decoderFactory: { request in try await factory.decoder(for: request) },
            transcriber: TrackingTranscriber(gate: MLGate()),
            diarizer: TrackingDiarizer(gate: MLGate())
        )

        do {
            _ = try await supervisor.run([])
            XCTFail("Expected empty request validation failure")
        } catch let error as MultiStreamIngestSupervisorError {
            XCTAssertEqual(error, .emptyRequests)
        }
        let countAfterEmptyValidation = await factory.requestCount()
        XCTAssertEqual(countAfterEmptyValidation, 0)

        do {
            _ = try await supervisor.run([
                StreamIngestRequest(source: "https://example.test/one", maxChunks: 1),
                StreamIngestRequest(source: "https://example.test/two", maxChunks: 1),
                StreamIngestRequest(source: "https://example.test/three", maxChunks: 1)
            ])
            XCTFail("Expected too many requests validation failure")
        } catch let error as MultiStreamIngestSupervisorError {
            XCTAssertEqual(error, .tooManyRequests(count: 3, maximum: 2))
        }
        let countAfterTooManyValidation = await factory.requestCount()
        XCTAssertEqual(countAfterTooManyValidation, 0)

        do {
            _ = try await supervisor.run([
                StreamIngestRequest(source: "https://example.test/unbounded")
            ])
            XCTFail("Expected unbounded request validation failure")
        } catch let error as MultiStreamIngestSupervisorError {
            XCTAssertEqual(error, .unboundedRequest(index: 0))
        }
        let countAfterUnboundedValidation = await factory.requestCount()
        XCTAssertEqual(countAfterUnboundedValidation, 0)
    }

    private static func chunk(sequence: Int, streamName: String) -> DecodedAudioChunk {
        DecodedAudioChunk(
            sequence: sequence,
            segmentURI: "https://user:pass@example.test/\(streamName)-\(sequence).ts?token=secret#frag",
            audio: Data([0x01, 0x02, 0x03]),
            startSeconds: Double(sequence) * 2.0,
            endSeconds: Double(sequence + 1) * 2.0,
            startedAt: "2026-05-01T00:00:0\(sequence)Z",
            endedAt: "2026-05-01T00:00:0\(sequence + 1)Z",
            adMarkers: [
                AdMarker(
                    type: "SCTE35",
                    classification: .adStart,
                    source: "hls_segment",
                    pts: 1.0,
                    segment: "https://user:pass@example.test/\(streamName)-\(sequence).ts?token=secret",
                    rawBase64: "AAAAAQ==",
                    timestamp: "2026-05-01T00:00:0\(sequence)Z"
                )
            ]
        )
    }
}

private struct BarrierDecoder: AudioDecoding {
    let gate: DecodeBarrier
    let chunks: [DecodedAudioChunk]

    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        await gate.requested(request.source)
        return chunks
    }
}

private struct FailingDecoder: AudioDecoding {
    let error: any Error

    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        throw error
    }
}

private struct StaticDecoder: AudioDecoding {
    let chunks: [DecodedAudioChunk]

    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        chunks
    }
}

private actor DecodeBarrier {
    private let expectedSources: Set<String>
    private var requestedSources: Set<String> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(expectedSources: [String]) {
        self.expectedSources = Set(expectedSources)
    }

    func requested(_ source: String) async {
        requestedSources.insert(source)
        if expectedSources.isSubset(of: requestedSources) {
            let currentWaiters = waiters
            waiters.removeAll()
            for waiter in currentWaiters { waiter.resume() }
        }
        if isReleased { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilAllRequested() async {
        if expectedSources.isSubset(of: requestedSources) { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let currentWaiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in currentWaiters { waiter.resume() }
    }
}

private actor MLGate {
    private var active = 0
    private var maxActiveValue = 0
    private var started = 0

    func begin() {
        started += 1
        active += 1
        maxActiveValue = max(maxActiveValue, active)
    }

    func end() {
        active -= 1
    }

    func startedCount() -> Int { started }
    func maxActive() -> Int { maxActiveValue }
}

private actor TrackingTranscriber: MLTranscription {
    let gate: MLGate

    init(gate: MLGate) {
        self.gate = gate
    }

    func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
        await gate.begin()
        try await Task.sleep(nanoseconds: 20_000_000)
        await gate.end()
        let streamName = Self.streamName(from: chunk)
        let speaker = "\(streamName)-speaker"
        return [
            TranscriptSegmentDraft(
                sequence: 0,
                speakerLabel: speaker,
                startSeconds: chunk.startSeconds,
                endSeconds: chunk.endSeconds,
                text: "shared phrase from \(streamName)",
                confidence: 0.91,
                words: ["shared", "phrase", "from", streamName].enumerated().map { index, text in
                    TranscriptWordDraft(
                        sequence: index,
                        speakerLabel: speaker,
                        startSeconds: chunk.startSeconds + (Double(index) * 0.2),
                        endSeconds: chunk.startSeconds + (Double(index + 1) * 0.2),
                        text: text,
                        confidence: 0.9
                    )
                }
            )
        ]
    }

    private static func streamName(from chunk: DecodedAudioChunk) -> String {
        if chunk.segmentURI?.contains("alpha") == true { return "alpha" }
        if chunk.segmentURI?.contains("bravo") == true { return "bravo" }
        if chunk.segmentURI?.contains("healthy") == true { return "healthy" }
        return "unknown"
    }
}

private actor TrackingDiarizer: SpeakerDiarization {
    let gate: MLGate

    init(gate: MLGate) {
        self.gate = gate
    }

    func diarize(_ chunk: DecodedAudioChunk, transcriptSegments: [TranscriptSegmentDraft]) async throws -> [SpeakerTurnDraft] {
        await gate.begin()
        try await Task.sleep(nanoseconds: 20_000_000)
        await gate.end()
        return transcriptSegments.map { segment in
            SpeakerTurnDraft(
                speakerLabel: segment.speakerLabel ?? "unknown-speaker",
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                confidence: 0.86
            )
        }
    }
}

private actor DecoderRegistry {
    private var decoders: [String: any AudioDecoding]

    init(decoders: [String: any AudioDecoding]) {
        self.decoders = decoders
    }

    func decoder(for source: String) throws -> any AudioDecoding {
        guard let decoder = decoders[source] else {
            throw FakeIngestError("missing decoder for \(source)")
        }
        return decoder
    }
}

private actor CountingDecoderFactory {
    private var count = 0

    func decoder(for request: StreamIngestRequest) throws -> any AudioDecoding {
        count += 1
        return BarrierDecoder(gate: DecodeBarrier(expectedSources: [request.source]), chunks: [])
    }

    func requestCount() -> Int { count }
}

private actor DelayedDecoderFactory {
    private var active = 0
    private var maxActiveValue = 0
    private var sources: [String] = []

    func decoder(for request: StreamIngestRequest) async throws -> any AudioDecoding {
        sources.append(request.source)
        active += 1
        maxActiveValue = max(maxActiveValue, active)
        try await Task.sleep(nanoseconds: 20_000_000)
        active -= 1
        return StaticDecoder(chunks: [
            DecodedAudioChunk(
                sequence: 0,
                audio: Data([0x01]),
                startSeconds: 0,
                endSeconds: 1,
                startedAt: "2026-05-01T00:00:00Z",
                endedAt: "2026-05-01T00:00:01Z"
            )
        ])
    }

    func maxActive() -> Int { maxActiveValue }
    func requestedSources() -> [String] { sources }
}

private struct FakeIngestError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
