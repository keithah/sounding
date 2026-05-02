import Foundation
import GRDB
import XCTest

@testable import SoundingKit

final class AppVerifyFixtureRunnerTests: XCTestCase {
    func testFixtureRunnerProducesPassingEvidenceThroughAppRuntimeService() async throws {
        let root = temporaryRoot("success")
        defer { try? FileManager.default.removeItem(at: root) }

        let player = DiagnosticsRecordingPlayer()
        let runner = makeRunner(root: root, player: player)

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .pass, evidence.summary.message)
        XCTAssertEqual(Set(evidence.checks.map(\.name)), Set(AppVerifyCheckName.fixtureRequired))
        assertCheck(evidence, .runtimeStarted, .pass)
        assertCheck(evidence, .decodeCompleted, .pass)
        assertCheck(evidence, .avfoundationPlaybackScheduled, .pass)
        assertCheck(evidence, .runtimeStopped, .pass)
        assertCheck(evidence, .playbackMuted, .pass)
        assertCheck(evidence, .playbackUnmuted, .pass)
        assertCheck(evidence, .playbackVolumeChanged, .pass)
        assertCheck(evidence, .runtimeStopObserved, .pass)
        assertCheck(evidence, .runtimeRestartObserved, .pass)
        assertCheck(evidence, .diagnosticsWritten, .pass)
        let transcriptPersistence = try projectionCheck(evidence, .transcriptPersistence, .pass)
        XCTAssertGreaterThan(transcriptPersistence.projectionFacts?.rowCount ?? 0, 0)
        XCTAssertEqual(transcriptPersistence.projectionFacts?.sampleFields["segments"], "1")
        XCTAssertEqual(transcriptPersistence.projectionFacts?.sampleFields["words"], "3")
        XCTAssertEqual(transcriptPersistence.projectionFacts?.sampleFields["ftsRows"], "1")
        let transcriptTimeline = try projectionCheck(evidence, .transcriptTimelineProjection, .pass)
        XCTAssertGreaterThan(transcriptTimeline.projectionFacts?.projectionCount ?? 0, 0)
        XCTAssertEqual(transcriptTimeline.projectionFacts?.sampleFields["paragraphs"], "1")
        XCTAssertEqual(transcriptTimeline.projectionFacts?.sampleFields["timelineTranscriptItems"], "1")
        let transcriptSearch = try projectionCheck(evidence, .transcriptSearchProjection, .pass)
        XCTAssertGreaterThan(transcriptSearch.projectionFacts?.projectionCount ?? 0, 0)
        XCTAssertEqual(
            transcriptSearch.projectionFacts?.sampleFields["phrase"], "app verify fixture")
        XCTAssertEqual(transcriptSearch.projectionFacts?.sampleFields["results"], "1")
        let songMetadata = try projectionCheck(evidence, .songMetadataProjection, .pass)
        XCTAssertGreaterThan(songMetadata.projectionFacts?.metadataCount ?? 0, 0)
        XCTAssertEqual(songMetadata.projectionFacts?.sampleFields["songRows"], "1")
        XCTAssertEqual(songMetadata.projectionFacts?.sampleFields["songPlays"], "1")
        XCTAssertEqual(songMetadata.projectionFacts?.sampleFields["timelineSongItems"], "1")
        let adMetadata = try projectionCheck(evidence, .adMetadataProjection, .pass)
        XCTAssertGreaterThan(adMetadata.projectionFacts?.metadataCount ?? 0, 0)
        XCTAssertEqual(adMetadata.projectionFacts?.sampleFields["adEvents"], "1")
        XCTAssertEqual(adMetadata.projectionFacts?.sampleFields["adEventsWithPTS"], "1")
        XCTAssertEqual(adMetadata.projectionFacts?.sampleFields["timelineAdItems"], "1")
        XCTAssertGreaterThan(evidence.runtimeFacts?.processedChunks ?? 0, 0)
        XCTAssertGreaterThan(evidence.runtimeFacts?.decodedChunks ?? 0, 0)
        XCTAssertGreaterThan(evidence.runtimeFacts?.scheduledBuffers ?? 0, 0)
        XCTAssertTrue(
            evidence.runtimeFacts?.recentDiagnosticEvents.contains("playback.prepare.succeeded")
                == true)
        XCTAssertTrue(
            evidence.runtimeFacts?.recentDiagnosticEvents.contains("playback.play.scheduled")
                == true)
        XCTAssertTrue(evidence.artifacts.contains { $0.kind == "runtime-events" })
    }

    func testZeroProcessedAndDecodedCountersFailDecodeAndPlaybackProof() async throws {
        let root = temporaryRoot("zero-counters")
        defer { try? FileManager.default.removeItem(at: root) }

        let player = DiagnosticsRecordingPlayer()
        let runner = makeRunner(root: root, decoder: EmptyDecoder(), player: player)

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .fail)
        assertCheck(evidence, .runtimeStarted, .pass)
        assertCheck(evidence, .decodeCompleted, .fail)
        assertCheck(evidence, .avfoundationPlaybackScheduled, .fail)
        assertCheck(evidence, .runtimeStopped, .pass)
        XCTAssertEqual(evidence.runtimeFacts?.processedChunks, 0)
        XCTAssertEqual(evidence.runtimeFacts?.decodedChunks, 0)
    }

    func testMissingPlaybackScheduledDiagnosticFailsPlaybackProof() async throws {
        let root = temporaryRoot("missing-scheduled")
        defer { try? FileManager.default.removeItem(at: root) }

        let player = DiagnosticsRecordingPlayer(recordScheduledEvent: false)
        let runner = makeRunner(root: root, player: player)

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .fail)
        assertCheck(evidence, .decodeCompleted, .pass)
        let playback = try XCTUnwrap(
            evidence.checks.first { $0.name == .avfoundationPlaybackScheduled })
        XCTAssertEqual(playback.status, .fail)
        XCTAssertTrue(
            playback.reason?.contains("missing required AVFoundation diagnostic events") == true,
            playback.reason ?? "")
    }

    func testRuntimeTimeoutProducesFailedStopEvidenceAndCleansUpPlayer() async throws {
        let root = temporaryRoot("timeout")
        defer { try? FileManager.default.removeItem(at: root) }

        let player = DiagnosticsRecordingPlayer()
        let runner = makeRunner(
            root: root,
            timeoutSeconds: 0.05,
            player: player,
            ingesterFactory: { _, _, _, _, _, _, _, _, _, _, _ in HangingIngester() }
        )

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .fail)
        assertCheck(evidence, .runtimeStarted, .pass)
        let stopped = try XCTUnwrap(evidence.checks.first { $0.name == .runtimeStopped })
        XCTAssertEqual(stopped.status, .fail)
        XCTAssertTrue(stopped.reason?.contains("Timed out") == true, stopped.reason ?? "")
        let stops = player.stopCount()
        XCTAssertGreaterThan(stops, 0)
    }

    func testMalformedDiagnosticsFailDiagnosticsWrittenWithoutCrashingEvidence() async throws {
        let root = temporaryRoot("malformed-diagnostics")
        defer { try? FileManager.default.removeItem(at: root) }

        let player = DiagnosticsRecordingPlayer(writeMalformedDiagnostics: true)
        let runner = makeRunner(root: root, player: player)

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .fail)
        let diagnostics = try XCTUnwrap(evidence.checks.first { $0.name == .diagnosticsWritten })
        XCTAssertEqual(diagnostics.status, .fail)
        XCTAssertTrue(
            diagnostics.reason?.contains("malformed JSONL") == true, diagnostics.reason ?? "")
    }

    func testRuntimeThatReachesProjectionStageWithoutRowsFailsS03RequiredChecks() async throws {
        let root = temporaryRoot("missing-projections")
        defer { try? FileManager.default.removeItem(at: root) }

        let player = DiagnosticsRecordingPlayer()
        let runner = makeRunner(
            root: root,
            player: player,
            ingesterFactory: { _, _, _, _, _, _, player, timeline, _, diagnosticsLog, _ in
                NoProjectionIngester(
                    player: player,
                    timeline: timeline,
                    diagnosticsLog: diagnosticsLog
                )
            }
        )

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .fail)
        XCTAssertEqual(
            evidence.summary.failedRequiredCheckCount,
            AppVerifyCheckName.s03ProjectionRequired.count)
        for name in AppVerifyCheckName.s03ProjectionRequired {
            let check = try projectionCheck(evidence, name, .fail)
            XCTAssertTrue(check.required, "Expected \(name) to remain required")
            XCTAssertNotNil(
                check.projectionFacts, "Expected \(name) to include bounded projection facts")
            XCTAssertTrue(
                check.reason?.contains("non-zero sanitized count") == true, check.reason ?? "")
        }
    }

    func testMissingTranscriptPersistenceFailsNamedS03CheckWithSanitizedFacts() async throws {
        let root = temporaryRoot("missing-transcript-persistence")
        defer { try? FileManager.default.removeItem(at: root) }

        let player = DiagnosticsRecordingPlayer()
        let runner = makeRunner(
            root: root,
            player: player,
            ingesterFactory: mutatingIngesterFactory { database, streamID in
                try database.write { db in
                    try db.execute(
                        sql: """
                            DELETE FROM transcript_segments
                            WHERE run_id IN (SELECT id FROM ingest_runs WHERE stream_id = ?)
                            """,
                        arguments: [streamID]
                    )
                }
            }
        )

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .fail)
        let check = try projectionCheck(evidence, .transcriptPersistence, .fail)
        XCTAssertEqual(check.phase, .transcriptPersistence)
        XCTAssertEqual(check.projectionFacts?.rowCount, 0)
        XCTAssertEqual(check.projectionFacts?.sampleFields["segments"], "0")
        XCTAssertEqual(check.projectionFacts?.sampleFields["words"], "0")
        XCTAssertEqual(check.projectionFacts?.sampleFields["ftsRows"], "0")
        assertS03FailureIsSanitized(check)
    }

    func testMissingTranscriptSearchPhraseFailsNamedS03CheckWithSanitizedFacts() async throws {
        let root = temporaryRoot("missing-transcript-search")
        defer { try? FileManager.default.removeItem(at: root) }

        let player = DiagnosticsRecordingPlayer()
        let runner = makeRunner(
            root: root,
            player: player,
            ingesterFactory: mutatingIngesterFactory { database, streamID in
                try database.write { db in
                    try db.execute(
                        sql: """
                            UPDATE transcript_segments
                            SET text = 'unrelated deterministic words'
                            WHERE run_id IN (SELECT id FROM ingest_runs WHERE stream_id = ?)
                            """,
                        arguments: [streamID]
                    )
                    try db.execute(sql: "INSERT INTO transcript_segments_fts(transcript_segments_fts) VALUES('rebuild')")
                }
            }
        )

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .fail)
        _ = try projectionCheck(evidence, .transcriptPersistence, .pass)
        let check = try projectionCheck(evidence, .transcriptSearchProjection, .fail)
        XCTAssertEqual(check.phase, .transcriptSearchProjection)
        XCTAssertGreaterThan(check.projectionFacts?.rowCount ?? 0, 0)
        XCTAssertEqual(check.projectionFacts?.projectionCount, 0)
        XCTAssertEqual(check.projectionFacts?.sampleFields["phrase"], "app verify fixture")
        XCTAssertEqual(check.projectionFacts?.sampleFields["results"], "0")
        assertS03FailureIsSanitized(check)
    }

    func testMissingSongMetadataProjectionFailsNamedS03CheckWithSanitizedFacts() async throws {
        let root = temporaryRoot("missing-song-metadata")
        defer { try? FileManager.default.removeItem(at: root) }

        let player = DiagnosticsRecordingPlayer()
        let runner = makeRunner(
            root: root,
            player: player,
            ingesterFactory: mutatingIngesterFactory { database, streamID in
                try database.write { db in
                    try db.execute(
                        sql: "DELETE FROM song_plays WHERE stream_id = ?",
                        arguments: [streamID]
                    )
                }
            }
        )

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .fail)
        let check = try projectionCheck(evidence, .songMetadataProjection, .fail)
        XCTAssertEqual(check.phase, .songMetadataProjection)
        XCTAssertEqual(check.projectionFacts?.metadataCount, 0)
        XCTAssertEqual(check.projectionFacts?.sampleFields["songRows"], "0")
        XCTAssertEqual(check.projectionFacts?.sampleFields["songPlays"], "0")
        assertS03FailureIsSanitized(check)
    }

    func testMissingAdMetadataProjectionFailsNamedS03CheckWithSanitizedFacts() async throws {
        let root = temporaryRoot("missing-ad-metadata")
        defer { try? FileManager.default.removeItem(at: root) }

        let player = DiagnosticsRecordingPlayer()
        let runner = makeRunner(
            root: root,
            player: player,
            ingesterFactory: mutatingIngesterFactory { database, streamID in
                try database.write { db in
                    try db.execute(
                        sql: """
                            DELETE FROM ad_events
                            WHERE run_id IN (SELECT id FROM ingest_runs WHERE stream_id = ?)
                            """,
                        arguments: [streamID]
                    )
                }
            }
        )

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .fail)
        let check = try projectionCheck(evidence, .adMetadataProjection, .fail)
        XCTAssertEqual(check.phase, .adMetadataProjection)
        XCTAssertEqual(check.projectionFacts?.metadataCount, 0)
        XCTAssertEqual(check.projectionFacts?.sampleFields["adEvents"], "0")
        XCTAssertEqual(check.projectionFacts?.sampleFields["adEventsWithPTS"], "0")
        assertS03FailureIsSanitized(check)
    }

    func testMissingVolumeAppliedDiagnosticFailsControlProof() async throws {
        let root = temporaryRoot("missing-volume")
        defer { try? FileManager.default.removeItem(at: root) }

        let player = DiagnosticsRecordingPlayer(recordVolumeEvent: false)
        let runner = makeRunner(root: root, timeoutSeconds: 0.2, player: player)

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .fail)
        assertCheck(evidence, .playbackMuted, .fail)
        let muted = try XCTUnwrap(evidence.checks.first { $0.name == .playbackMuted })
        XCTAssertTrue(
            muted.reason?.contains("timed out") == true
                || muted.reason?.contains("Control window") == true, muted.reason ?? "")
        XCTAssertGreaterThan(player.stopCount(), 0)
    }

    func testEvidenceRedactsSecretLikeRunPathsAndSources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppVerify-token=super-secret-user-pass", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let player = DiagnosticsRecordingPlayer()
        let runner = makeRunner(root: root, player: player)

        let evidence = await runner.run()
        let json = String(decoding: try evidence.jsonData(), as: UTF8.self)

        XCTAssertFalse(json.contains("token=super-secret"), json)
        XCTAssertFalse(json.contains("user:pass"), json)
        XCTAssertFalse(json.contains("super-secret"), json)
    }

    private func makeRunner(
        root: URL,
        timeoutSeconds: Double = 2,
        decoder: any AudioDecoding = FixedLinearPCMDecoder(),
        player: DiagnosticsRecordingPlayer,
        ingesterFactory: AppVerifyFixtureRunner.IngesterFactory? = nil
    ) -> AppVerifyFixtureRunner {
        AppVerifyFixtureRunner(
            configuration: AppVerifyFixtureRunner.Configuration(
                runRootDirectory: root,
                timeoutSeconds: timeoutSeconds,
                timestamp: { "2026-05-02T18:00:00Z" },
                makeRunID: { "test-run" }
            ),
            decoderFactory: { decoder },
            playerFactory: { volumeStore, diagnosticsLog in
                player.attach(volumeStore: volumeStore, diagnosticsLog: diagnosticsLog)
                return player
            },
            ingesterFactory: ingesterFactory ?? {
                database, decoder, transcriber, diarizer, fingerprinter, fingerprintEnricher,
                player, timeline, rollingBuffer, diagnosticsLog, now in
                StreamIngestAppRuntimeRunner(
                    database: database,
                    decoder: decoder,
                    transcriber: transcriber,
                    diarizer: diarizer,
                    fingerprinter: fingerprinter,
                    fingerprintEnricher: fingerprintEnricher,
                    player: player,
                    timeline: timeline,
                    rollingBuffer: rollingBuffer,
                    diagnosticsLog: diagnosticsLog,
                    keepPlaybackRunningAfterIngestCompletes: false,
                    now: now
                )
            }
        )
    }

    private func temporaryRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AppVerifyFixtureRunnerTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func assertCheck(
        _ evidence: AppVerifyEvidence,
        _ name: AppVerifyCheckName,
        _ status: AppVerifyEvidenceStatus,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let check = evidence.checks.first { $0.name == name }
        XCTAssertEqual(
            check?.status, status, "Missing or unexpected check \(name)", file: file, line: line)
    }

    private func projectionCheck(
        _ evidence: AppVerifyEvidence,
        _ name: AppVerifyCheckName,
        _ status: AppVerifyEvidenceStatus,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AppVerifyCheckRecord {
        let check = try XCTUnwrap(
            evidence.checks.first { $0.name == name },
            "Missing projection check \(name)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            check.status, status, "Unexpected projection check status for \(name)", file: file,
            line: line)
        XCTAssertNotNil(
            check.projectionFacts, "Missing projection facts for \(name)", file: file, line: line)
        return check
    }

    private func mutatingIngesterFactory(
        _ mutate: @escaping @Sendable (_ database: SoundingDatabase, _ streamID: Int64) throws -> Void
    ) -> AppVerifyFixtureRunner.IngesterFactory {
        { database, decoder, transcriber, diarizer, fingerprinter, fingerprintEnricher,
          player, timeline, rollingBuffer, diagnosticsLog, now in
            MutatingProjectionIngester(
                base: StreamIngestAppRuntimeRunner(
                    database: database,
                    decoder: decoder,
                    transcriber: transcriber,
                    diarizer: diarizer,
                    fingerprinter: fingerprinter,
                    fingerprintEnricher: fingerprintEnricher,
                    player: player,
                    timeline: timeline,
                    rollingBuffer: rollingBuffer,
                    diagnosticsLog: diagnosticsLog,
                    keepPlaybackRunningAfterIngestCompletes: false,
                    now: now
                ),
                database: database,
                mutate: mutate
            )
        }
    }

    private func assertS03FailureIsSanitized(
        _ check: AppVerifyCheckRecord,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(check.required, file: file, line: line)
        XCTAssertTrue(
            check.reason?.contains("non-zero sanitized count") == true,
            check.reason ?? "",
            file: file,
            line: line
        )
        let json = String(decoding: (try? AppVerifyEvidence(
            generatedAt: "2026-05-02T18:00:00Z",
            runID: "token=synthetic-secret",
            checks: [check]
        ).jsonData()) ?? Data(), as: UTF8.self)
        XCTAssertFalse(json.contains("synthetic-secret"), json, file: file, line: line)
        XCTAssertFalse(json.contains("/tmp/"), json, file: file, line: line)
        XCTAssertFalse(json.contains("user:pass"), json, file: file, line: line)
    }
}

private struct MutatingProjectionIngester: AppStreamRuntimeIngesting {
    var base: any AppStreamRuntimeIngesting
    var database: SoundingDatabase
    var mutate: @Sendable (_ database: SoundingDatabase, _ streamID: Int64) throws -> Void

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        let result = try await base.run(request)
        try mutate(database, request.streamID)
        return result
    }
}

private final class DiagnosticsRecordingPlayer: AppPCMPlaybackAdapting, @unchecked Sendable {
    private let recordScheduledEvent: Bool
    private let recordVolumeEvent: Bool
    private let writeMalformedDiagnostics: Bool
    private let queue = DispatchQueue(
        label: "AppVerifyFixtureRunnerTests.DiagnosticsRecordingPlayer")
    private var diagnosticsLog: AppRuntimeDiagnosticsLog?
    private var currentStreamID: Int64?
    private var volumeObserverTask: Task<Void, Never>?
    private var stops = 0

    init(
        recordScheduledEvent: Bool = true, recordVolumeEvent: Bool = true,
        writeMalformedDiagnostics: Bool = false
    ) {
        self.recordScheduledEvent = recordScheduledEvent
        self.recordVolumeEvent = recordVolumeEvent
        self.writeMalformedDiagnostics = writeMalformedDiagnostics
    }

    deinit {
        volumeObserverTask?.cancel()
    }

    func attach(volumeStore: AppPlaybackVolumeStore, diagnosticsLog: AppRuntimeDiagnosticsLog) {
        queue.sync {
            self.diagnosticsLog = diagnosticsLog
        }
        guard recordVolumeEvent else { return }
        volumeObserverTask?.cancel()
        volumeObserverTask = Task { [weak self, volumeStore] in
            let changes = await volumeStore.changes()
            for await snapshot in changes {
                guard let self else { return }
                if self.currentStreamIDValue() == snapshot.streamID {
                    diagnosticsLog.recordEvent(
                        "playback.volume.applied",
                        streamID: snapshot.streamID,
                        phase: "playback.volume",
                        fields: [
                            "volume": String(format: "%.3f", snapshot.volume),
                            "isMuted": String(snapshot.isMuted),
                            "effectiveVolume": String(format: "%.3f", snapshot.effectiveVolume),
                            "source": "test-observer",
                        ]
                    )
                }
            }
        }
    }

    func prepare(streamID: Int64, sourceDescription: String, timeline: AppPlayerTimelineClock)
        async throws
    {
        setCurrentStreamID(streamID)
        currentDiagnosticsLog()?.recordEvent(
            "playback.prepare.succeeded",
            streamID: streamID,
            sourceDescription: sourceDescription,
            phase: "playback.prepare"
        )
        await timeline.reset(streamID: streamID, message: "Prepared test playback.")
    }

    func play(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock) async throws {
        let diagnosticsLog = currentDiagnosticsLog()
        if recordScheduledEvent {
            diagnosticsLog?.recordEvent(
                "playback.play.scheduled",
                streamID: frames.first?.streamID,
                phase: "playback.play",
                fields: ["frameCount": String(frames.count)]
            )
        }
        if writeMalformedDiagnostics, let diagnosticsLog {
            try? "not-json\n".data(using: .utf8)?.write(
                to: diagnosticsLog.eventLogURL, options: .atomic)
            diagnosticsLog.recordEvent(
                "runtime.event.published", streamID: frames.first?.streamID, phase: "test")
        }
        await timeline.recordDecodedFrames(frames)
        await timeline.updatePlayerState(
            .playing,
            positionSeconds: frames.last?.startSeconds,
            message: "Scheduled \(frames.count) test frame(s)."
        )
    }

    func pause(timeline: AppPlayerTimelineClock) async {}
    func resume(timeline: AppPlayerTimelineClock) async {}

    func stop(timeline: AppPlayerTimelineClock) async {
        let streamID = currentStreamIDValue()
        queue.sync {
            stops += 1
            currentStreamID = nil
        }
        currentDiagnosticsLog()?.recordEvent(
            "playback.stop.applied",
            streamID: streamID,
            phase: "playback.stop",
            fields: ["source": "test-player"]
        )
        await timeline.updatePlayerState(.stopped, message: "Test playback stopped.")
    }

    func stopCount() -> Int {
        queue.sync { stops }
    }

    private func currentDiagnosticsLog() -> AppRuntimeDiagnosticsLog? {
        queue.sync { diagnosticsLog }
    }

    private func setCurrentStreamID(_ streamID: Int64?) {
        queue.sync { currentStreamID = streamID }
    }

    private func currentStreamIDValue() -> Int64? {
        queue.sync { currentStreamID }
    }
}

private struct FixedLinearPCMDecoder: AudioDecoding {
    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        let format = DecodedAudioFormat.linearPCM(sampleRate: 44_100, channelCount: 1, bitDepth: 16)
        return [
            DecodedAudioChunk(
                sequence: 0,
                segmentURI: request.source,
                audio: Data([0x00, 0x00, 0x10, 0x00, 0x20, 0x00, 0x30, 0x00]),
                audioFormat: format,
                byteCount: 8,
                startSeconds: 0,
                endSeconds: 0.00009,
                startedAt: "2026-05-02T18:00:00Z",
                endedAt: "2026-05-02T18:00:01Z"
            )
        ]
    }
}

private struct EmptyDecoder: AudioDecoding {
    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] { [] }
}

private struct NoProjectionIngester: AppStreamRuntimeIngesting {
    var player: any AppPCMPlaybackAdapting
    var timeline: AppPlayerTimelineClock
    var diagnosticsLog: AppRuntimeDiagnosticsLog

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        try await player.prepare(
            streamID: request.streamID,
            sourceDescription: request.sourceDescription,
            timeline: timeline
        )
        let frame = SharedPCMFrame(
            streamID: request.streamID,
            sequence: 0,
            audio: Data([0x00, 0x00, 0x10, 0x00]),
            startSeconds: 0,
            endSeconds: 0.25
        )
        try await player.play([frame], timeline: timeline)
        diagnosticsLog.recordEvent(
            "runner.ingest.completed",
            streamID: request.streamID,
            streamName: request.name,
            source: request.source,
            sourceDescription: request.sourceDescription,
            phase: "runner.ingest",
            fields: [
                "runID": "0",
                "processedChunks": "1",
                "diagnosticCount": "1",
            ]
        )
        return AppStreamRuntimeResult(
            streamID: request.streamID,
            processedChunks: 1,
            diagnosticCount: 1,
            playerTimeline: await timeline.snapshot()
        )
    }
}

private struct HangingIngester: AppStreamRuntimeIngesting {
    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CancellationError()
    }
}
