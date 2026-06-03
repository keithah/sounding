import Foundation
import GRDB
import XCTest

@testable import SoundingKit

final class SoundingAppRuntimeFactoryTests: AppStreamRuntimeTestCase {
    func testDefaultRuntimeFingerprintingUsesChromaprintAndConfiguredAcoustIDLookup() throws {
        let temporary = try TemporarySoundingDatabase()

        XCTAssertTrue(
            SoundingAppRuntimeFactory.defaultAudioFingerprinter(environment: [:])
                is ChromaSwiftAudioFingerprinter
        )
        XCTAssertTrue(
            SoundingAppRuntimeFactory.defaultAudioFingerprinter(
                environment: ["SOUNDING_DETERMINISTIC_FINGERPRINT": "1"]
            ) is DeterministicAudioFingerprinter
        )
        XCTAssertTrue(
            SoundingAppRuntimeFactory.defaultFingerprintEnricher(
                database: temporary.database,
                environment: [:]
            ) is NoOpAudioFingerprintEnricher
        )
        XCTAssertTrue(
            SoundingAppRuntimeFactory.defaultFingerprintEnricher(
                database: temporary.database,
                environment: ["SOUNDING_ACOUSTID_API_KEY": "fixture-key"]
            ) is AcoustIDAudioFingerprintEnricher
        )
    }

    func testRuntimeFactoryBuildsDefaultStartupStateWithConfiguredModelBufferAndNonBlockingAcoustID() throws {
        let directory = try makeRuntimeFactoryTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = SoundingAppPreferences(
            databaseURL: directory.appendingPathComponent("Sounding.sqlite"),
            acoustIDKeyStatus: .missing
        )
        let recorder = RuntimeFactoryRecorder()
        let factory = SoundingAppRuntimeFactory(
            ingesterFactory: { _, configuration, _, _, _, _, _ in
                recorder.recordIngesterConfiguration(configuration)
                return RecordingAppRuntimeIngester(result: AppStreamRuntimeResult(streamID: 1))
            },
            runtimeFactory: { registry, ingester, timeline, rollingBuffer, audioArchiveStore, _, volumeStore, player in
                recorder.recordRuntimeConstructed()
                return AppStreamRuntimeService(
                    registry: registry,
                    ingester: ingester,
                    retryPolicy: .noRetry,
                    volumeStore: volumeStore,
                    playbackTimeline: timeline,
                    rollingBuffer: rollingBuffer,
                    audioArchiveStore: audioArchiveStore,
                    playbackController: player
                )
            }
        )

        let state = factory.makeStartupState(preferences: preferences)

        XCTAssertNotNil(state.registry)
        XCTAssertNotNil(state.runtime)
        XCTAssertNotNil(state.timelineStore)
        XCTAssertNotNil(state.searchStore)
        XCTAssertNil(state.persistenceError)
        XCTAssertEqual(recorder.ingesterConfigurations.count, 1)
        XCTAssertEqual(recorder.ingesterConfigurations[0].whisperModelName, "tiny")
        XCTAssertEqual(
            recorder.ingesterConfigurations[0].rollingBuffer.targetDurationSeconds,
            RollingBufferConfiguration.appDefault().targetDurationSeconds
        )
        XCTAssertTrue(recorder.runtimeConstructed)
        XCTAssertEqual(state.configuration.issues.map(\.id), ["acoustid.key-missing"])
        XCTAssertFalse(state.configuration.hasBlockingIssues)
    }

    func testRuntimeFactoryClearsStaleTransientStatusesOnStartup() throws {
        let directory = try makeRuntimeFactoryTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("Sounding.sqlite")
        let database = try SoundingDatabase(fileURL: databaseURL)
        let registry = StreamRegistry(database: database)
        let stream = try registry.add(
            name: "Startup HLS",
            streamType: "hls",
            source: "https://example.test/startup.m3u8"
        )
        let statusStore = AppStreamRuntimeStatusStore(database: database)
        try statusStore.upsert(
            AppStreamRuntimeStatusUpdate(
                streamID: stream.id,
                phase: .running,
                attempt: 1,
                maxAttempts: 3,
                nextRetrySeconds: 10,
                nextRetryAt: "2026-05-01T10:00:11Z",
                updatedAt: "2026-05-01T10:00:01Z"
            )
        )
        let factory = SoundingAppRuntimeFactory(
            ingesterFactory: { _, _, _, _, _, _, _ in
                RecordingAppRuntimeIngester(result: AppStreamRuntimeResult(streamID: stream.id))
            }
        )

        let state = factory.makeStartupState(
            preferences: SoundingAppPreferences(
                databaseURL: databaseURL,
                acoustIDKeyStatus: .present
            )
        )

        XCTAssertNotNil(state.runtime)
        let snapshot = try XCTUnwrap(try statusStore.status(streamID: stream.id))
        XCTAssertEqual(snapshot.phase, .stopped)
        XCTAssertEqual(snapshot.attempt, 0)
        XCTAssertNil(snapshot.nextRetrySeconds)
        XCTAssertNil(snapshot.nextRetryAt)
    }

    func testRuntimeFactoryDatabaseOpenFailureShortCircuitsBeforeIngesterAndRedactsIssue() throws {
        let directory = try makeRuntimeFactoryTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("Sounding.sqlite")
        let recorder = RuntimeFactoryRecorder()
        let rawPath = directory.appendingPathComponent("private.sqlite").path
        let factory = SoundingAppRuntimeFactory(
            databaseFactory: { _ in
                recorder.recordDatabaseOpen()
                throw RuntimeFailure(
                    message: "open failed at \(rawPath) for https://user:pass@example.test/db?token=secret#frag"
                )
            },
            ingesterFactory: { _, configuration, _, _, _, _, _ in
                recorder.recordIngesterConfiguration(configuration)
                return RecordingAppRuntimeIngester(result: AppStreamRuntimeResult(streamID: 1))
            }
        )

        let state = factory.makeStartupState(
            preferences: SoundingAppPreferences(databaseURL: databaseURL, acoustIDKeyStatus: .present)
        )

        XCTAssertEqual(recorder.databaseOpenCount, 1)
        XCTAssertTrue(recorder.ingesterConfigurations.isEmpty)
        XCTAssertNil(state.registry)
        XCTAssertNil(state.runtime)
        let issue = try XCTUnwrap(state.configuration.issues.first { $0.id == "database.open-failed" })
        XCTAssertEqual(issue.action.kind, .chooseDatabaseLocation)
        XCTAssertEqual(issue.phase, .startup)
        XCTAssertTrue(issue.blocksRuntime)
        XCTAssertFalse(issue.detail?.contains(rawPath) ?? true, issue.detail ?? "")
        XCTAssertFalse(issue.detail?.contains("user:pass") ?? true, issue.detail ?? "")
        XCTAssertFalse(issue.detail?.contains("token=secret") ?? true, issue.detail ?? "")
    }

    func testRuntimeFactoryInvalidModelBlocksBeforeDatabaseAndDependencyConstruction() throws {
        let directory = try makeRuntimeFactoryTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawModel = "/Users/example/private-model?api_key=secret"
        let recorder = RuntimeFactoryRecorder()
        let factory = SoundingAppRuntimeFactory(
            databaseFactory: { url in
                recorder.recordDatabaseOpen()
                return try SoundingDatabase(fileURL: url)
            },
            ingesterFactory: { _, configuration, _, _, _, _, _ in
                recorder.recordIngesterConfiguration(configuration)
                return RecordingAppRuntimeIngester(result: AppStreamRuntimeResult(streamID: 1))
            }
        )

        let state = factory.makeStartupState(
            preferences: SoundingAppPreferences(
                databaseURL: directory.appendingPathComponent("Sounding.sqlite"),
                whisperModelName: rawModel,
                acoustIDKeyStatus: .present
            )
        )

        XCTAssertEqual(recorder.databaseOpenCount, 0)
        XCTAssertTrue(recorder.ingesterConfigurations.isEmpty)
        XCTAssertNil(state.registry)
        XCTAssertNil(state.runtime)
        let issue = try XCTUnwrap(state.configuration.issues.first { $0.category == .model })
        XCTAssertEqual(issue.id, "model.invalid-name")
        XCTAssertEqual(issue.action.kind, .chooseWhisperModel)
        XCTAssertFalse(String(describing: issue).contains(rawModel))
        XCTAssertFalse(String(describing: issue).contains("api_key=secret"))
        XCTAssertFalse(String(describing: issue).contains("/Users/example"))
    }

    func testRuntimeFactoryDependencyFailureKeepsStoresButDoesNotStartRuntime() throws {
        let directory = try makeRuntimeFactoryTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawPath = directory.appendingPathComponent("cache/private-model").path
        let factory = SoundingAppRuntimeFactory(
            ingesterFactory: { _, _, _, _, _, _, _ in
                throw ModelCacheError.setupFailed(
                    provider: "whisperkit",
                    model: "tiny",
                    reason: "cache unavailable at \(rawPath)"
                )
            }
        )

        let state = factory.makeStartupState(
            preferences: SoundingAppPreferences(
                databaseURL: directory.appendingPathComponent("Sounding.sqlite"),
                acoustIDKeyStatus: .present
            )
        )

        XCTAssertNotNil(state.registry)
        XCTAssertNotNil(state.timelineStore)
        XCTAssertNotNil(state.searchStore)
        XCTAssertNil(state.runtime)
        let issue = try XCTUnwrap(state.configuration.issues.first { $0.id == "model.setup-failed" })
        XCTAssertEqual(issue.phase, .startup)
        XCTAssertEqual(issue.action.kind, .chooseWhisperModel)
        XCTAssertTrue(issue.blocksRuntime)
        XCTAssertFalse(issue.detail?.contains(rawPath) ?? true, issue.detail ?? "")
        XCTAssertTrue(issue.detail?.contains("[redacted-path]") ?? false, issue.detail ?? "")
    }

    func testRuntimeFactoryCapsHugeBufferBeforeRollingBufferConstruction() throws {
        let directory = try makeRuntimeFactoryTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = RuntimeFactoryRecorder()
        let factory = SoundingAppRuntimeFactory(
            ingesterFactory: { _, configuration, _, _, _, _, _ in
                recorder.recordIngesterConfiguration(configuration)
                return RecordingAppRuntimeIngester(result: AppStreamRuntimeResult(streamID: 1))
            }
        )

        let state = factory.makeStartupState(
            preferences: SoundingAppPreferences(
                databaseURL: directory.appendingPathComponent("Sounding.sqlite"),
                rollingBufferTargetSeconds: SoundingAppConfiguration.maximumRollingBufferSeconds * 100,
                acoustIDKeyStatus: .present
            )
        )

        XCTAssertNotNil(state.runtime)
        XCTAssertEqual(recorder.ingesterConfigurations.count, 1)
        XCTAssertEqual(
            recorder.ingesterConfigurations[0].rollingBuffer.targetDurationSeconds,
            SoundingAppConfiguration.maximumRollingBufferSeconds
        )
        XCTAssertEqual(state.configuration.issues.map(\.id), ["rolling-buffer.too-large"])
        XCTAssertFalse(state.configuration.hasBlockingIssues)
    }
}
