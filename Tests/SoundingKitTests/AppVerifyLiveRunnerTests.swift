import Foundation
import XCTest

@testable import SoundingKit

final class AppVerifyLiveRunnerTests: XCTestCase {
    private let secretHLS = "https://viewer:letmein@example.test/live/main.m3u8?token=synthetic-secret#private-fragment"
    private let secretHTTP = "https://viewer:letmein@example.test/radio/stream?access_token=synthetic-secret#private-fragment"

    func testSuccessfulRequiredStreamProducesPassingLiveEvidenceInStableOrder() async throws {
        let root = temporaryRoot("success")
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = FakeLiveStreamExecutor(outcomes: [
            .success(.passing(streamID: 101, diagnosticsEvents: ["runtime.event.published", "playback.play.scheduled"]))
        ])
        let runner = try makeRunner(root: root, streams: [
            AppVerifyLiveStreamSpec(id: "main", source: "https://example.test/live/main.m3u8")
        ], executor: executor)

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .pass, evidence.summary.message)
        XCTAssertEqual(evidence.summary.failedRequiredCheckCount, 0)
        XCTAssertEqual(evidence.checks.map(\.name), [
            .liveConfigValidated,
            .liveStreamRegistered,
            .liveRuntimeStarted,
            .liveDecodeOpened,
            .livePlaybackScheduled,
            .liveRuntimeStopped,
            .liveDiagnosticsWritten,
            .liveTranscriptObserved,
            .liveMetadataObserved,
        ])
        assertCheck(evidence, .liveStreamRegistered, .pass)
        assertCheck(evidence, .liveDecodeOpened, .pass)
        assertCheck(evidence, .livePlaybackScheduled, .pass)
        assertCheck(evidence, .liveDiagnosticsWritten, .pass)
        let decode = try XCTUnwrap(evidence.checks.first { $0.name == .liveDecodeOpened })
        XCTAssertEqual(decode.liveFacts?.streamID, "main")
        XCTAssertEqual(decode.liveFacts?.resolvedStreamType, .hls)
        XCTAssertEqual(decode.liveFacts?.redactedSource, "https://example.test/live/main.m3u8")
        XCTAssertEqual(decode.liveFacts?.processedChunks, 2)
        XCTAssertEqual(decode.liveFacts?.decodedChunks, 2)
        XCTAssertEqual(decode.liveFacts?.scheduledBuffers, 2)
        XCTAssertTrue(evidence.artifacts.contains { $0.kind == "live-run-directory" })
        XCTAssertEqual(executor.requests.map(\.stream.id), ["main"])
        XCTAssertEqual(executor.stopRequests.map(\.stream.id), ["main"])
    }

    func testRequiredExecutionFailureFailsRequiredChecksAndStillAttemptsCleanup() async throws {
        let root = temporaryRoot("required-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = FakeLiveStreamExecutor(outcomes: [.failure(FakeError("open failed token=synthetic-secret"))])
        let runner = try makeRunner(root: root, streams: [
            AppVerifyLiveStreamSpec(id: "required", source: "https://example.test/live/main.m3u8", required: true)
        ], executor: executor)

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .fail)
        XCTAssertGreaterThan(evidence.summary.failedRequiredCheckCount, 0)
        assertCheck(evidence, .liveRuntimeStarted, .fail)
        assertCheck(evidence, .liveRuntimeStopped, .pass)
        assertCheck(evidence, .liveDiagnosticsWritten, .fail)
        XCTAssertEqual(executor.stopRequests.map(\.stream.id), ["required"])
        assertSanitized(try evidenceJSON(evidence))
    }

    func testOptionalExecutionFailureWarnsWithoutFailedRequiredChecks() async throws {
        let root = temporaryRoot("optional-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = FakeLiveStreamExecutor(outcomes: [.failure(FakeError("optional unavailable"))])
        let runner = try makeRunner(root: root, streams: [
            AppVerifyLiveStreamSpec(id: "optional", source: secretHTTP, streamType: .icecast, required: false)
        ], executor: executor)

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .warn)
        XCTAssertEqual(evidence.summary.failedRequiredCheckCount, 0)
        assertCheck(evidence, .liveRuntimeStarted, .warn)
        assertCheck(evidence, .liveDiagnosticsWritten, .warn)
        assertSanitized(try evidenceJSON(evidence))
    }

    func testTimeoutProducesFailureWithCleanupEvidence() async throws {
        let root = temporaryRoot("timeout")
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = FakeLiveStreamExecutor(outcomes: [.hang])
        let runner = try makeRunner(
            root: root,
            streams: [AppVerifyLiveStreamSpec(id: "slow", source: "https://example.test/live/main.m3u8", timeoutSeconds: 0.05)],
            executor: executor
        )

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .fail)
        let started = try XCTUnwrap(evidence.checks.first { $0.name == .liveRuntimeStarted })
        XCTAssertEqual(started.status, .fail)
        XCTAssertTrue(started.reason?.contains("Timed out") == true, started.reason ?? "")
        assertCheck(evidence, .liveRuntimeStopped, .pass)
        XCTAssertEqual(executor.stopRequests.map(\.stream.id), ["slow"])
    }

    func testZeroDecodeAndPlaybackCountersFailRequiredRuntimeProofs() async throws {
        let root = temporaryRoot("zero-counters")
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = FakeLiveStreamExecutor(outcomes: [
            .success(.passing(streamID: 1, processedChunks: 1, decodedChunks: 0, scheduledBuffers: 0))
        ])
        let runner = try makeRunner(root: root, streams: [
            AppVerifyLiveStreamSpec(id: "zero", source: "https://example.test/live/main.m3u8")
        ], executor: executor)

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .fail)
        assertCheck(evidence, .liveDecodeOpened, .fail)
        assertCheck(evidence, .livePlaybackScheduled, .fail)
        XCTAssertEqual(evidence.checks.first { $0.name == .liveDecodeOpened }?.liveFacts?.decodedChunks, 0)
        XCTAssertEqual(evidence.checks.first { $0.name == .livePlaybackScheduled }?.liveFacts?.scheduledBuffers, 0)
    }

    func testMissingDiagnosticsFileFailsButPreservesArtifactReferences() async throws {
        let root = temporaryRoot("missing-diagnostics")
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = FakeLiveStreamExecutor(outcomes: [
            .success(.passing(streamID: 1, diagnosticsFileWritten: false))
        ])
        let runner = try makeRunner(root: root, streams: [
            AppVerifyLiveStreamSpec(id: "main", source: "https://example.test/live/main.m3u8")
        ], executor: executor)

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .fail)
        let diagnostics = try XCTUnwrap(evidence.checks.first { $0.name == .liveDiagnosticsWritten })
        XCTAssertEqual(diagnostics.status, .fail)
        XCTAssertTrue(diagnostics.reason?.contains("Diagnostics") == true, diagnostics.reason ?? "")
        XCTAssertTrue(diagnostics.artifacts.contains { $0.kind == "live-diagnostics" })
        XCTAssertTrue(evidence.artifacts.contains { $0.kind == "live-diagnostics" })
    }

    func testTranscriptAndMetadataWarnByDefaultAndStrictExpectationFailsRequiredStream() async throws {
        let root = temporaryRoot("expectations")
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = FakeLiveStreamExecutor(outcomes: [
            .success(.passing(streamID: 1, transcriptCount: 0, metadataCount: 0)),
            .success(.passing(streamID: 2, transcriptCount: 0, metadataCount: 0)),
        ])
        let runner = try makeRunner(root: root, streams: [
            AppVerifyLiveStreamSpec(id: "warn", source: "https://example.test/live/warn.m3u8"),
            AppVerifyLiveStreamSpec(
                id: "strict",
                source: "https://example.test/live/strict.m3u8",
                expectations: AppVerifyLiveExpectations(transcript: .strict, metadata: .strict)
            ),
        ], executor: executor)

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .fail)
        let transcriptChecks = evidence.checks.filter { $0.name == .liveTranscriptObserved }
        let metadataChecks = evidence.checks.filter { $0.name == .liveMetadataObserved }
        XCTAssertEqual(transcriptChecks.map(\.status), [.warn, .fail])
        XCTAssertEqual(metadataChecks.map(\.status), [.warn, .fail])
        XCTAssertFalse(transcriptChecks[0].required)
        XCTAssertTrue(transcriptChecks[1].required)
    }

    func testCleanupFailureBecomesEvidenceWithoutDroppingPriorFacts() async throws {
        let root = temporaryRoot("cleanup-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = FakeLiveStreamExecutor(
            outcomes: [.success(.passing(streamID: 1))],
            stopError: FakeError("cleanup failed token=synthetic-secret")
        )
        let runner = try makeRunner(root: root, streams: [
            AppVerifyLiveStreamSpec(id: "main", source: "https://example.test/live/main.m3u8")
        ], executor: executor)

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .fail)
        assertCheck(evidence, .liveDecodeOpened, .pass)
        assertCheck(evidence, .livePlaybackScheduled, .pass)
        let stopped = try XCTUnwrap(evidence.checks.first { $0.name == .liveRuntimeStopped })
        XCTAssertEqual(stopped.status, .fail)
        XCTAssertTrue(stopped.reason?.contains("cleanup failed") == true, stopped.reason ?? "")
        assertSanitized(try evidenceJSON(evidence))
    }

    func testDefaultExecutorAdvertisesRealRuntimeFactories() {
        let executor = AppVerifyAVFoundationLiveStreamExecutor()

        XCTAssertEqual(executor.factoryConfiguration.database, "SoundingDatabase")
        XCTAssertEqual(executor.factoryConfiguration.registry, "StreamRegistry")
        XCTAssertEqual(executor.factoryConfiguration.runtime, "StreamIngestAppRuntimeRunner/AppStreamRuntimeService")
        XCTAssertEqual(executor.factoryConfiguration.decoder, "AVFoundationAudioDecoder")
        XCTAssertEqual(executor.factoryConfiguration.player, "AVFoundationAppPCMPlayerAdapter")
        XCTAssertEqual(executor.factoryConfiguration.rollingBuffer, "RollingPCMBuffer")
    }

    func testDefaultExecutorRejectsUnsupportedResolvedTypesBeforeDatabaseOrRuntime() async throws {
        let root = temporaryRoot("unsupported-default")
        defer { try? FileManager.default.removeItem(at: root) }
        let streamDirectory = root.appendingPathComponent("stream", isDirectory: true)
        try FileManager.default.createDirectory(at: streamDirectory, withIntermediateDirectories: true)
        let executor = AppVerifyAVFoundationLiveStreamExecutor(
            databaseFactory: { _ in
                XCTFail("Unsupported live stream types must not open SoundingDatabase")
                throw FakeError("database should not open")
            },
            runtimeFactory: { _, _, _, _, _, _, _ in
                XCTFail("Unsupported live stream types must not reach AppStreamRuntimeService")
                return FakeRuntimeController()
            }
        )
        let unsupportedStreams = [
            AppVerifyLiveStreamSpec(id: "auto", source: "https://example.test/radio", streamType: .auto),
            AppVerifyLiveStreamSpec(id: "mpegts", source: "udp://239.0.0.1:1234", streamType: .mpegts),
            AppVerifyLiveStreamSpec(id: "udp", source: "udp://239.0.0.1:1234", streamType: .udp),
        ]

        for stream in unsupportedStreams {
            do {
                _ = try await executor.execute(AppVerifyLiveStreamExecutionRequest(
                    runID: "unsupported-run",
                    runDirectory: root,
                    streamDirectory: streamDirectory,
                    stream: stream,
                    diagnosticsLogURL: streamDirectory.appendingPathComponent("live-diagnostics.jsonl"),
                    generatedAt: "2026-05-02T18:00:00Z"
                ))
                XCTFail("Expected unsupported stream \(stream.id) to throw before runtime start")
            } catch {
                XCTAssertTrue(String(describing: error).contains("unsupported resolved stream type"), String(describing: error))
            }
        }
    }

    func testRunnerExecutesStreamsSequentiallyAndBoundsFactsForTenXInput() async throws {
        let root = temporaryRoot("sequential")
        defer { try? FileManager.default.removeItem(at: root) }
        let streams = (0..<10).map { index in
            AppVerifyLiveStreamSpec(id: "s\(index)", source: "https://example.test/live/s\(index).m3u8")
        }
        let executor = FakeLiveStreamExecutor(outcomes: Array(repeating: .success(.passing(streamID: 1, diagnosticsEvents: (0..<50).map { "event.\($0)" })), count: streams.count))
        let runner = try makeRunner(root: root, streams: streams, executor: executor)

        let evidence = await runner.run()

        XCTAssertEqual(evidence.summary.status, .pass)
        XCTAssertEqual(executor.requests.map(\.stream.id), streams.map(\.id))
        XCTAssertLessThanOrEqual(evidence.checks.count, 64)
        XCTAssertTrue(evidence.checks.allSatisfy { ($0.liveFacts?.recentDiagnosticEvents.count ?? 0) <= 32 })
    }

    func testEvidenceRedactsSecretSourcesConfigAndRunDirectoryStrings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppVerifyLiveRunnerTests-token=synthetic-secret-user-pass", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = FakeLiveStreamExecutor(outcomes: [
            .success(.passing(
                streamID: 1,
                diagnosticsEvents: ["opened \(secretHLS)", "/tmp/live-token=synthetic-secret.json"],
                fields: [
                    "configPath": "/Users/alice/app-verify-live.local.json",
                    "runDirectory": root.path,
                    "source": secretHLS,
                ]
            ))
        ])
        let runner = try makeRunner(
            root: root,
            streams: [AppVerifyLiveStreamSpec(id: "secret", source: secretHLS)],
            executor: executor,
            configPath: "/Users/alice/app-verify-live.local.json?token=synthetic-secret"
        )

        let json = try evidenceJSON(await runner.run())

        XCTAssertTrue(json.contains(#""redactedSource":"https://example.test/live/main.m3u8""#), json)
        assertSanitized(json)
        XCTAssertFalse(json.contains("/Users/alice"), json)
        XCTAssertFalse(json.contains("AppVerifyLiveRunnerTests-token"), json)
        XCTAssertFalse(json.contains("configPath"), json)
        XCTAssertFalse(json.contains("runDirectory"), json)
    }

    private func makeRunner(
        root: URL,
        streams: [AppVerifyLiveStreamSpec],
        executor: FakeLiveStreamExecutor,
        configPath: String? = nil
    ) throws -> AppVerifyLiveRunner {
        let config = try AppVerifyLiveConfiguration(streams: streams)
        return AppVerifyLiveRunner(
            configuration: AppVerifyLiveRunner.Configuration(
                liveConfiguration: config,
                runRootDirectory: root,
                configPath: configPath,
                timestamp: { "2026-05-02T18:00:00Z" },
                makeRunID: { "live-test-run" }
            ),
            streamExecutor: executor
        )
    }

    private func temporaryRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AppVerifyLiveRunnerTests-\(name)-\(UUID().uuidString)", isDirectory: true)
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

    private func evidenceJSON(_ evidence: AppVerifyEvidence) throws -> String {
        try XCTUnwrap(String(data: try evidence.jsonData(), encoding: .utf8))
    }

    private func assertSanitized(_ value: String, file: StaticString = #filePath, line: UInt = #line) {
        for forbidden in [
            "viewer",
            "letmein",
            "token=synthetic-secret",
            "access_token=synthetic-secret",
            "synthetic-secret",
            "private-fragment",
            "#private",
            "?token",
            "?access_token",
            "user-pass",
        ] {
            XCTAssertFalse(
                value.contains(forbidden),
                "Live runner evidence leaked forbidden literal '\(forbidden)': \(value)",
                file: file,
                line: line
            )
        }
    }
}

private final class FakeLiveStreamExecutor: AppVerifyLiveStreamExecuting, @unchecked Sendable {
    enum Outcome: Sendable {
        case success(AppVerifyLiveStreamExecutionResult)
        case failure(any Error)
        case hang
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private let stopError: (any Error)?
    private(set) var requests: [AppVerifyLiveStreamExecutionRequest] = []
    private(set) var stopRequests: [AppVerifyLiveStreamStopRequest] = []

    init(outcomes: [Outcome], stopError: (any Error)? = nil) {
        self.outcomes = outcomes
        self.stopError = stopError
    }

    func execute(_ request: AppVerifyLiveStreamExecutionRequest) async throws -> AppVerifyLiveStreamExecutionResult {
        let outcome: Outcome = lock.withLock {
            requests.append(request)
            return outcomes.isEmpty ? .success(.passing(streamID: Int64(requests.count))) : outcomes.removeFirst()
        }
        switch outcome {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        case .hang:
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CancellationError()
        }
    }

    func stop(_ request: AppVerifyLiveStreamStopRequest) async throws {
        lock.withLock { stopRequests.append(request) }
        if let stopError { throw stopError }
    }
}

private extension AppVerifyLiveStreamExecutionResult {
    static func passing(
        streamID: Int64,
        processedChunks: Int = 2,
        decodedChunks: Int = 2,
        scheduledBuffers: Int = 2,
        transcriptCount: Int = 1,
        metadataCount: Int = 1,
        diagnosticsEvents: [String] = ["runtime.event.published"],
        diagnosticsFileWritten: Bool = true,
        fields: [String: String] = [:]
    ) -> AppVerifyLiveStreamExecutionResult {
        AppVerifyLiveStreamExecutionResult(
            registeredStreamID: streamID,
            runtimeStarted: true,
            processedChunks: processedChunks,
            decodedChunks: decodedChunks,
            scheduledBuffers: scheduledBuffers,
            transcriptCount: transcriptCount,
            metadataCount: metadataCount,
            diagnosticEvents: diagnosticsEvents,
            diagnosticsFileWritten: diagnosticsFileWritten,
            fields: fields
        )
    }
}

private struct FakeRuntimeController: AppStreamRuntimeControlling {
    func events() async -> AsyncStream<AppStreamRuntimeEvent> { AsyncStream { $0.finish() } }
    func start(streamID: Int64) async throws {}
    func restart(streamID: Int64) async throws {}
    func pause() async {}
    func pause(streamID: Int64) async {}
    func resume() async {}
    func resume(streamID: Int64) async {}
    func stop() async {}
    func stop(streamID: Int64) async {}
    func stopAll() async {}
    func suspendForSystemSleep(reason: String) async {}
    func recoverFromSystemWake(reason: String) async {}
    func setVolume(streamID: Int64, volume: Double) async {}
    func setMuted(streamID: Int64, isMuted: Bool) async {}
    func seek(to seconds: Double, streamID: Int64) async {}
    func seekToLive(streamID: Int64) async {}
    func scrubBackward(seconds: Double, streamID: Int64) async {}
    func snapshot() async -> AppStreamRuntimeEvent? { nil }
    func snapshot(streamID: Int64) async -> AppStreamRuntimeEvent? { nil }
    func snapshots() async -> [AppStreamRuntimeEvent] { [] }
}

private struct FakeError: Error, CustomStringConvertible, Sendable {
    var description: String
    init(_ description: String) { self.description = description }
}
