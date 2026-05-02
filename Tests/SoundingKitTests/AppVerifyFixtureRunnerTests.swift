import Foundation
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
        XCTAssertEqual(Set(evidence.checks.map(\.name)), Set(AppVerifyCheckName.s01Required))
        assertCheck(evidence, .runtimeStarted, .pass)
        assertCheck(evidence, .decodeCompleted, .pass)
        assertCheck(evidence, .avfoundationPlaybackScheduled, .pass)
        assertCheck(evidence, .runtimeStopped, .pass)
        assertCheck(evidence, .diagnosticsWritten, .pass)
        XCTAssertGreaterThan(evidence.runtimeFacts?.processedChunks ?? 0, 0)
        XCTAssertGreaterThan(evidence.runtimeFacts?.decodedChunks ?? 0, 0)
        XCTAssertGreaterThan(evidence.runtimeFacts?.scheduledBuffers ?? 0, 0)
        XCTAssertTrue(evidence.runtimeFacts?.recentDiagnosticEvents.contains("playback.prepare.succeeded") == true)
        XCTAssertTrue(evidence.runtimeFacts?.recentDiagnosticEvents.contains("playback.play.scheduled") == true)
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
        let playback = try XCTUnwrap(evidence.checks.first { $0.name == .avfoundationPlaybackScheduled })
        XCTAssertEqual(playback.status, .fail)
        XCTAssertTrue(playback.reason?.contains("missing required AVFoundation diagnostic events") == true, playback.reason ?? "")
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
        XCTAssertTrue(diagnostics.reason?.contains("malformed JSONL") == true, diagnostics.reason ?? "")
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
            playerFactory: { _, diagnosticsLog in
                player.attach(diagnosticsLog: diagnosticsLog)
                return player
            },
            ingesterFactory: ingesterFactory ?? { database, decoder, transcriber, diarizer, fingerprinter, fingerprintEnricher, player, timeline, rollingBuffer, diagnosticsLog, now in
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
            .appendingPathComponent("AppVerifyFixtureRunnerTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func assertCheck(
        _ evidence: AppVerifyEvidence,
        _ name: AppVerifyCheckName,
        _ status: AppVerifyEvidenceStatus,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let check = evidence.checks.first { $0.name == name }
        XCTAssertEqual(check?.status, status, "Missing or unexpected check \(name)", file: file, line: line)
    }
}

private final class DiagnosticsRecordingPlayer: AppPCMPlaybackAdapting, @unchecked Sendable {
    private let recordScheduledEvent: Bool
    private let writeMalformedDiagnostics: Bool
    private let queue = DispatchQueue(label: "AppVerifyFixtureRunnerTests.DiagnosticsRecordingPlayer")
    private var diagnosticsLog: AppRuntimeDiagnosticsLog?
    private var stops = 0

    init(recordScheduledEvent: Bool = true, writeMalformedDiagnostics: Bool = false) {
        self.recordScheduledEvent = recordScheduledEvent
        self.writeMalformedDiagnostics = writeMalformedDiagnostics
    }

    func attach(diagnosticsLog: AppRuntimeDiagnosticsLog) {
        queue.sync {
            self.diagnosticsLog = diagnosticsLog
        }
    }

    func prepare(streamID: Int64, sourceDescription: String, timeline: AppPlayerTimelineClock) async throws {
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
            try? "not-json\n".data(using: .utf8)?.write(to: diagnosticsLog.eventLogURL, options: .atomic)
            diagnosticsLog.recordEvent("runtime.event.published", streamID: frames.first?.streamID, phase: "test")
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
        queue.sync {
            stops += 1
        }
        await timeline.updatePlayerState(.stopped, message: "Test playback stopped.")
    }

    func stopCount() -> Int {
        queue.sync { stops }
    }

    private func currentDiagnosticsLog() -> AppRuntimeDiagnosticsLog? {
        queue.sync { diagnosticsLog }
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

private struct HangingIngester: AppStreamRuntimeIngesting {
    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CancellationError()
    }
}
