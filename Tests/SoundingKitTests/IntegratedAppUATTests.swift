import Foundation
import GRDB
import XCTest

@testable import SoundingKit

final class IntegratedAppUATTests: XCTestCase {
    func testAppSupportRuntimePersistsSearchableTimelineAndCLIConfirmsSameSQLite() async throws {
        let temporary = try TemporarySoundingDatabase()
        let spillDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SoundingIntegratedAppUAT-spill-token=spill-secret-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: spillDirectory) }

        let gate = UATRuntimeGate()
        let recorder = UATRuntimeRecorder()
        let factory = SoundingAppRuntimeFactory(
            databaseFactory: { url in
                XCTAssertEqual(url, temporary.fileURL)
                return temporary.database
            },
            ingesterFactory: { database, configuration, timeline, rollingBuffer in
                awaitOrRecord(configuration.issues, recorder: recorder)
                return IntegratedUATIngester(
                    database: database,
                    timeline: timeline,
                    rollingBuffer: rollingBuffer,
                    gate: gate,
                    recorder: recorder
                )
            },
            runtimeFactory: { registry, ingester, timeline, rollingBuffer, statusStore in
                AppStreamRuntimeService(
                    registry: registry,
                    ingester: ingester,
                    retryPolicy: .noRetry,
                    statusStore: statusStore,
                    playbackTimeline: timeline,
                    rollingBuffer: rollingBuffer
                )
            }
        )
        let preferences = SoundingAppPreferences(
            databaseURL: temporary.fileURL,
            rollingBufferTargetSeconds: 120,
            acoustIDKeyStatus: .missing
        )

        var state = factory.makeStartupState(preferences: preferences)
        XCTAssertNotNil(state.registry)
        XCTAssertNotNil(state.runtime)
        XCTAssertNotNil(state.timelineStore)
        XCTAssertNotNil(state.searchStore)
        XCTAssertNotNil(state.statusStore)
        XCTAssertNil(state.persistenceError)
        XCTAssertEqual(state.configuration.issues.map(\.id), ["acoustid.key-missing"])
        XCTAssertEqual(state.configuration.issues.first?.severity, .warning)
        XCTAssertFalse(state.configuration.hasBlockingIssues)

        let registry = try XCTUnwrap(state.registry)
        let runtime = try XCTUnwrap(state.runtime)
        let timelineStore = try XCTUnwrap(state.timelineStore)
        let searchStore = try XCTUnwrap(state.searchStore)
        let secretSource =
            "https://listener:pass@example.test/private/live.m3u8?token=uat-secret&query=hidden#frag"
        state.viewModel.addDraft = StreamAppAddDraft(
            name: "Integrated UAT HLS",
            source: secretSource,
            transport: .hls
        )
        let added = try state.viewModel.addStream(using: registry)
        XCTAssertEqual(added.sourceDescription, "https://example.test/private/live.m3u8")
        XCTAssertFalse(String(describing: state.viewModel).contains("listener:pass"))
        XCTAssertFalse(String(describing: state.viewModel).contains("uat-secret"))

        let events = await runtime.events()
        var iterator = events.makeAsyncIterator()
        try await runtime.start(streamID: added.id)
        let connecting = try await nextEvent(from: &iterator)
        let running = try await nextEvent(from: &iterator)
        state.viewModel.applyRuntimeEvent(connecting)
        state.viewModel.applyRuntimeEvent(running)
        XCTAssertEqual(connecting.phase, .connecting)
        XCTAssertEqual(running.phase, .running)
        assertNoSecrets(connecting.message, temporary: temporary, spillDirectory: spillDirectory)
        assertNoSecrets(running.message, temporary: temporary, spillDirectory: spillDirectory)

        try await gate.waitUntilPersisted()
        let preparedStreams = await recorder.preparedStreams()
        XCTAssertEqual(preparedStreams, [added.id])
        let playedFrames = await recorder.playedFrames()
        XCTAssertEqual(playedFrames.map(\.sequence), [0, 1, 2])

        let initialTimeline = try state.viewModel.refreshSelectedTimeline(
            using: timelineStore,
            refreshedAt: "2026-05-01T20:00:20Z"
        )
        XCTAssertEqual(initialTimeline.streamID, added.id)
        XCTAssertEqual(
            initialTimeline.transcriptParagraphs.map(\.text).suffix(2),
            [
                "closing context only",
                "late alpha beta unbuffered result",
            ])
        XCTAssertTrue(initialTimeline.currentMetadata?.title.hasPrefix("Unknown song (") == true)
        XCTAssertTrue(initialTimeline.timelineItems.contains { $0.kind == .event })
        XCTAssertTrue(initialTimeline.timelineItems.contains { $0.kind == .song })
        XCTAssertNil(initialTimeline.diagnostics.bufferedSeekUnavailableMessage)
        assertNoSecrets(
            String(describing: initialTimeline), temporary: temporary,
            spillDirectory: spillDirectory)

        await runtime.scrubBackward(seconds: 4)
        let scrubbed = try await nextEvent(from: &iterator)
        state.viewModel.applyRuntimeEvent(scrubbed)
        XCTAssertEqual(scrubbed.result?.playerTimeline?.positionSeconds, 30)
        XCTAssertEqual(
            scrubbed.result?.playerTimeline?.lastMessage, "Playback seeked to buffered frame 2.")

        await runtime.seekToLive()
        let live = try await nextEvent(from: &iterator)
        state.viewModel.applyRuntimeEvent(live)
        XCTAssertEqual(live.result?.playerTimeline?.positionSeconds, 30)
        XCTAssertEqual(live.result?.playerTimeline?.liveEdgeSeconds, 34)

        await runtime.seek(to: 99)
        let unavailable = try await nextEvent(from: &iterator)
        state.viewModel.applyRuntimeEvent(unavailable)
        XCTAssertEqual(
            unavailable.result?.playerTimeline?.unavailableRangeMessage,
            "Requested 99.0s is unavailable (available range 0.0-34.0s)."
        )
        let unavailableSelected = try XCTUnwrap(state.viewModel.selectedStream)
        XCTAssertEqual(unavailableSelected.bufferIssue?.id, "buffer.seek-unavailable")
        XCTAssertTrue(
            try XCTUnwrap(unavailableSelected.bufferedSeekUnavailableMessage).contains(
                "unavailable"))

        state.viewModel.updateSearchDraft(
            StreamAppSearchDraft(
                phrase: "alpha beta", scopeToSelectedStream: true, limit: 10, contextSegments: 1)
        )
        let search = try state.viewModel.runSearch(
            using: searchStore,
            refreshedAt: "2026-05-01T20:00:30Z"
        )
        XCTAssertEqual(search.results.map(\.streamID), [added.id, added.id])
        XCTAssertEqual(search.results.map(\.sequence), [1, 3])
        XCTAssertEqual(search.results.map(\.isSeekable), [true, false])
        XCTAssertEqual(search.diagnostics.statusMessage, "Found 2 transcript result(s).")
        XCTAssertEqual(search.diagnostics.unseekableResultCount, 1)
        assertNoSecrets(
            String(describing: search), temporary: temporary, spillDirectory: spillDirectory)

        let bufferedResult = try XCTUnwrap(search.results.first { $0.isSeekable })
        let bufferedAction = try state.viewModel.selectSearchResult(
            id: bufferedResult.id,
            using: timelineStore,
            refreshedAt: "2026-05-01T20:00:40Z"
        )
        XCTAssertTrue(bufferedAction.shouldSeek)
        XCTAssertEqual(bufferedAction.seekSeconds, 10)
        await runtime.seek(to: try XCTUnwrap(bufferedAction.seekSeconds))
        let searchSeek = try await nextEvent(from: &iterator)
        state.viewModel.applyRuntimeEvent(searchSeek)
        XCTAssertEqual(searchSeek.result?.playerTimeline?.positionSeconds, 10)
        XCTAssertEqual(
            state.viewModel.selectedStream?.transcriptScrollTargetSegmentID,
            bufferedResult.segmentID)

        let unbufferedResult = try XCTUnwrap(search.results.first { !$0.isSeekable })
        let unbufferedAction = try state.viewModel.selectSearchResult(
            id: unbufferedResult.id,
            using: timelineStore,
            refreshedAt: "2026-05-01T20:00:50Z"
        )
        XCTAssertFalse(unbufferedAction.shouldSeek)
        XCTAssertNil(unbufferedAction.seekSeconds)
        XCTAssertTrue(
            try XCTUnwrap(unbufferedAction.message).contains("outside the current playback buffer"))
        XCTAssertEqual(
            state.viewModel.selectedStream?.transcriptScrollTargetSegmentID,
            unbufferedResult.segmentID)

        state.viewModel.updateSearchDraft(StreamAppSearchDraft(phrase: "   ", limit: 10))
        XCTAssertThrowsError(try state.viewModel.runSearch(using: searchStore)) { error in
            XCTAssertEqual(error as? StreamAppSearchStoreError, .emptyPhrase)
        }
        XCTAssertEqual(
            state.viewModel.selectedStream?.searchErrorMessage, "Search phrase must not be empty.")

        let cli = CLIRunner()
        let streamsList = try cli.runSounding(arguments: [
            "streams", "list", "--db", temporary.fileURL.path, "--json",
        ])
        XCTAssertEqual(streamsList.exitCode, 0, streamsList.diagnosticSummary)
        XCTAssertEqual(streamsList.stderrText, "", streamsList.diagnosticSummary)
        let streamsPayload = try streamsList.decodeJSON(StreamsPayload.self)
        XCTAssertEqual(streamsPayload.streams.map(\.id), [added.id])
        XCTAssertEqual(
            streamsPayload.streams.first?.source, "https://example.test/private/live.m3u8")

        let cliSearch = try cli.runSounding(arguments: [
            "search", "alpha beta", "--db", temporary.fileURL.path, "--json", "--limit", "10",
            "--context", "1",
        ])
        XCTAssertEqual(cliSearch.exitCode, 0, cliSearch.diagnosticSummary)
        XCTAssertEqual(cliSearch.stderrText, "", cliSearch.diagnosticSummary)
        let searchPayload = try cliSearch.decodeJSON(SearchPayload.self)
        XCTAssertEqual(searchPayload.results.map { $0.identity.streamID }, [added.id, added.id])
        XCTAssertEqual(
            searchPayload.results.map(\.text),
            [
                "alpha beta buffered result",
                "late alpha beta unbuffered result",
            ])
        assertNoSecrets(
            streamsList.stdoutText + streamsList.stderrText, temporary: temporary,
            spillDirectory: spillDirectory)
        assertNoSecrets(
            cliSearch.stdoutText + cliSearch.stderrText, temporary: temporary,
            spillDirectory: spillDirectory)

        await gate.release()
        let stopped = try await nextEvent(from: &iterator)
        state.viewModel.applyRuntimeEvent(stopped)
        XCTAssertEqual(stopped.phase, .stopped)
        XCTAssertEqual(stopped.result?.processedChunks, 3)
        assertNoSecrets(stopped.message, temporary: temporary, spillDirectory: spillDirectory)
    }

    private struct StreamsPayload: Decodable {
        var streams: [Stream]
    }

    private struct Stream: Decodable {
        var id: Int64
        var name: String
        var streamType: String
        var status: String
        var source: String
    }

    private struct SearchPayload: Decodable {
        var results: [TranscriptQuery.SearchResult]
    }

    private func nextEvent(
        from iterator: inout AsyncStream<AppStreamRuntimeEvent>.Iterator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> AppStreamRuntimeEvent {
        guard let event = await iterator.next() else {
            XCTFail("Expected runtime event", file: file, line: line)
            throw UATError.missingEvent
        }
        return event
    }

    private func assertNoSecrets(
        _ text: String,
        temporary: TemporarySoundingDatabase,
        spillDirectory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for forbidden in [
            temporary.fileURL.path,
            temporary.fileURL.deletingLastPathComponent().path,
            spillDirectory.path,
            "listener:pass",
            "uat-secret",
            "token=",
            "query=hidden",
            "#frag",
            "spill-secret",
            "api_key=",
        ] {
            XCTAssertFalse(
                text.contains(forbidden),
                "Expected redaction of \(forbidden), got: \(text)",
                file: file,
                line: line
            )
        }
    }
}

private enum UATError: Error {
    case missingEvent
}

private actor UATRuntimeGate {
    private var persistedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var didPersist = false
    private var didRelease = false

    func markPersisted() {
        didPersist = true
        let waiters = persistedWaiters
        persistedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilPersisted() async throws {
        if didPersist { return }
        await withCheckedContinuation { continuation in
            persistedWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        if didRelease { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        didRelease = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor UATRuntimeRecorder {
    private var _configurationIssues: [SoundingAppConfigurationIssue] = []
    private var _preparedStreams: [Int64] = []
    private var _playedFrames: [SharedPCMFrame] = []

    func recordConfigurationIssues(_ issues: [SoundingAppConfigurationIssue]) {
        _configurationIssues = issues
    }

    func recordPreparedStream(_ streamID: Int64) {
        _preparedStreams.append(streamID)
    }

    func recordPlayedFrames(_ frames: [SharedPCMFrame]) {
        _playedFrames.append(contentsOf: frames)
    }

    func preparedStreams() -> [Int64] { _preparedStreams }
    func playedFrames() -> [SharedPCMFrame] { _playedFrames }
}

private func awaitOrRecord(
    _ issues: [SoundingAppConfigurationIssue],
    recorder: UATRuntimeRecorder
) {
    Task { await recorder.recordConfigurationIssues(issues) }
}

private struct IntegratedUATIngester: AppStreamRuntimeIngesting {
    let database: SoundingDatabase
    let timeline: AppPlayerTimelineClock
    let rollingBuffer: RollingPCMBuffer
    let gate: UATRuntimeGate
    let recorder: UATRuntimeRecorder

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        let player = RecordingDeterministicPlayer(recorder: recorder)
        await rollingBuffer.start(streamID: request.streamID)
        await timeline.updateRollingBuffer(await rollingBuffer.snapshot())
        try await player.prepare(
            streamID: request.streamID,
            sourceDescription: request.sourceDescription,
            timeline: timeline
        )
        let decoder = SinglePathPCMDecoder(
            streamID: request.streamID,
            upstream: IntegratedUATDecoder(),
            player: player,
            timeline: timeline,
            rollingBuffer: rollingBuffer
        )
        let result = try await StreamIngestPipeline(
            database: database,
            decoder: decoder,
            transcriber: IntegratedUATTranscriber(),
            diarizer: IntegratedUATDiarizer(),
            fingerprinter: DeterministicAudioFingerprinter(),
            fingerprintEnricher: NoOpAudioFingerprintEnricher(),
            now: { "2026-05-01T20:00:00Z" }
        ).run(streamID: request.streamID, source: request.source, streamType: request.streamType)
        await gate.markPersisted()
        await gate.waitForRelease()
        let snapshot = await timeline.snapshot()
        await player.stop(timeline: timeline)
        _ = await rollingBuffer.cleanup()
        return AppStreamRuntimeResult(
            streamID: result.streamID,
            runID: result.runID,
            processedChunks: result.processedChunks,
            diagnosticCount: result.diagnostics.count,
            playerTimeline: snapshot
        )
    }
}

private struct RecordingDeterministicPlayer: AppPCMPlaybackAdapting {
    let recorder: UATRuntimeRecorder
    private let adapter = DeterministicAppPCMPlayerAdapter()

    func prepare(streamID: Int64, sourceDescription: String, timeline: AppPlayerTimelineClock)
        async throws
    {
        await recorder.recordPreparedStream(streamID)
        try await adapter.prepare(
            streamID: streamID, sourceDescription: sourceDescription, timeline: timeline)
    }

    func play(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock) async throws {
        await recorder.recordPlayedFrames(frames)
        try await adapter.play(frames, timeline: timeline)
    }

    func pause(timeline: AppPlayerTimelineClock) async { await adapter.pause(timeline: timeline) }
    func resume(timeline: AppPlayerTimelineClock) async { await adapter.resume(timeline: timeline) }
    func stop(timeline: AppPlayerTimelineClock) async { await adapter.stop(timeline: timeline) }
}

private struct IntegratedUATDecoder: AudioDecoding {
    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        XCTAssertEqual(request.streamType, .hls)
        XCTAssertTrue(request.source.contains("uat-secret"))
        return [
            DecodedAudioChunk(
                sequence: 0,
                segmentURI:
                    "https://listener:pass@example.test/private/segment-0.ts?token=uat-secret#frag",
                audio: Data([0x01, 0x02, 0x03, 0x04]),
                startSeconds: 0,
                endSeconds: 8,
                startedAt: "2026-05-01T20:00:00Z",
                endedAt: "2026-05-01T20:00:08Z",
                adMarkers: [
                    AdMarker(
                        type: "splice_insert",
                        classification: .adStart,
                        source: "manifest",
                        pts: 6,
                        segment: "segment-0.ts?token=uat-secret",
                        timestamp: "2026-05-01T20:00:06Z"
                    )
                ]
            ),
            DecodedAudioChunk(
                sequence: 1,
                segmentURI:
                    "https://listener:pass@example.test/private/segment-1.ts?token=uat-secret#frag",
                audio: Data([0x05, 0x06, 0x07, 0x08]),
                startSeconds: 10,
                endSeconds: 14,
                startedAt: "2026-05-01T20:00:10Z",
                endedAt: "2026-05-01T20:00:14Z",
                adMarkers: [
                    AdMarker(
                        type: "splice_insert",
                        classification: .adEnd,
                        source: "manifest",
                        pts: 12,
                        segment: "segment-1.ts?token=uat-secret",
                        timestamp: "2026-05-01T20:00:12Z"
                    )
                ]
            ),
            DecodedAudioChunk(
                sequence: 2,
                segmentURI:
                    "https://listener:pass@example.test/private/segment-2.ts?token=uat-secret#frag",
                audio: Data([0x09, 0x0a, 0x0b, 0x0c]),
                startSeconds: 30,
                endSeconds: 34,
                startedAt: "2026-05-01T20:00:30Z",
                endedAt: "2026-05-01T20:00:34Z"
            ),
        ]
    }
}

private struct IntegratedUATTranscriber: MLTranscription {
    func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
        switch chunk.sequence {
        case 0:
            return [segment(0, "host", 0, 8, "opening context only")]
        case 1:
            return [segment(0, "host", 10, 14, "alpha beta buffered result")]
        case 2:
            return [
                segment(0, "guest", 30, 34, "closing context only"),
                segment(1, "guest", 90, 94, "late alpha beta unbuffered result"),
            ]
        default:
            return []
        }
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
            confidence: 0.94,
            words: words.enumerated().map { index, word in
                TranscriptWordDraft(
                    sequence: index,
                    speakerLabel: speakerLabel,
                    startSeconds: startSeconds + Double(index) * duration,
                    endSeconds: startSeconds + Double(index + 1) * duration,
                    text: word,
                    confidence: 0.9
                )
            }
        )
    }
}

private struct IntegratedUATDiarizer: SpeakerDiarization {
    func diarize(
        _ chunk: DecodedAudioChunk,
        transcriptSegments: [TranscriptSegmentDraft]
    ) async throws -> [SpeakerTurnDraft] {
        transcriptSegments.map { segment in
            SpeakerTurnDraft(
                speakerLabel: segment.speakerLabel ?? "speaker",
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                confidence: 0.88
            )
        }
    }
}
