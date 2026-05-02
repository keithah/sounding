import Foundation
import XCTest

@testable import SoundingKit

final class SoakProofRunnerTests: XCTestCase {
    func testEvidenceJSONShapeUsesStableSortedTopLevelKeys() throws {
        let evidence = Self.sampleEvidence()

        let data = try XCTUnwrap(evidence.jsonData().successValue)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.hasPrefix("{\"databaseSnapshots\":"), json)
        XCTAssertLessThan(try XCTUnwrap(json.range(of: "\"databaseSnapshots\"")?.lowerBound), try XCTUnwrap(json.range(of: "\"failures\"")?.lowerBound))
        XCTAssertLessThan(try XCTUnwrap(json.range(of: "\"schemaVersion\"")?.lowerBound), try XCTUnwrap(json.range(of: "\"streams\"")?.lowerBound))

        let object = try semanticJSONObject(from: data)
        assertJSONKeys(
            object,
            equal: [
                "databaseSnapshots",
                "failures",
                "generatedAt",
                "hlsDecisionCounts",
                "limits",
                "queueSnapshots",
                "redactionAudit",
                "resourceSamples",
                "runtimeEvents",
                "schemaVersion",
                "streams",
                "summary",
                "thresholds",
                "timeRange"
            ]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, SoakEvidence.currentSchemaVersion)
    }

    func testThresholdQueueDatabaseAndResourceSnapshotsNormalizeCountersAndMapUpstreamModels() throws {
        let queue = SoakEvidenceQueueSnapshot(
            InferenceQueue.Snapshot(
                submitted: -5,
                started: -4,
                completed: -3,
                currentDepth: -2,
                maxDepth: -1,
                isBusy: true
            )
        )
        XCTAssertEqual(queue.submitted, 0)
        XCTAssertEqual(queue.started, 0)
        XCTAssertEqual(queue.completed, 0)
        XCTAssertEqual(queue.currentDepth, 0)
        XCTAssertEqual(queue.maxDepth, 0)
        XCTAssertTrue(queue.isBusy)

        let health = SoundingDatabaseHealth(
            status: .degraded,
            journalMode: "wal",
            walAutoCheckpointPages: -5,
            pageSizeBytes: -4096,
            pageCount: -10,
            files: SoundingDatabaseFileMetrics(databaseBytes: -1, walBytes: -2, shmBytes: -3),
            quickCheck: SoundingDatabaseCheckSummary(name: "quick", status: .warning, issueCount: -1),
            foreignKeyCheck: SoundingDatabaseCheckSummary(name: "fk", status: .ok, issueCount: 0),
            checkpoint: SoundingDatabaseCheckpointResult(
                status: .degraded,
                busyFrameCount: -1,
                logFrameCount: -2,
                checkpointedFrameCount: -3
            )
        )
        let database = SoakEvidenceDatabaseSnapshot(health)
        XCTAssertEqual(database.availability, .available)
        XCTAssertEqual(database.status, .degraded)
        XCTAssertEqual(database.databaseBytes, 0)
        XCTAssertEqual(database.walBytes, 0)
        XCTAssertEqual(database.shmBytes, 0)
        XCTAssertEqual(database.pageCount, 0)
        XCTAssertEqual(database.checkpointBusyFrames, 0)
        XCTAssertEqual(database.checkpointLogFrames, 0)
        XCTAssertEqual(database.checkpointedFrames, 0)
        XCTAssertEqual(database.quickCheckStatus, .warning)

        let resource = SoakEvidenceResourceSample(memoryBytes: -10, cpuPercent: -.infinity, openFileDescriptorCount: -4)
        XCTAssertEqual(resource.memoryBytes, 0)
        XCTAssertEqual(resource.cpuPercent, 0)
        XCTAssertEqual(resource.openFileDescriptorCount, 0)

        let threshold = SoakEvidenceThreshold(
            name: "recoveryLatency",
            status: .fail,
            observed: -1,
            limit: 5,
            unit: "seconds",
            message: "database checkpoint recovery exceeded threshold"
        )
        XCTAssertEqual(threshold.observed, 0)
        XCTAssertEqual(threshold.limit, 5)
        XCTAssertEqual(threshold.status, .fail)
    }

    func testSecretBearingStringsAreRedactedAcrossArbitraryLeaves() throws {
        let secretURL = "https://user:pass@example.test/private/live.m3u8?token=synthetic-secret#frag"
        let secretPath = "/tmp/soak-evidence/private-token=synthetic-secret/db.sqlite-wal"
        let evidence = SoakEvidence(
            generatedAt: "2026-05-01T10:00:00Z",
            timeRange: SoakEvidenceTimeRange(startedAt: "2026-05-01T10:00:00Z", endedAt: "2026-05-01T10:00:01Z", durationSeconds: 1),
            thresholds: [
                SoakEvidenceThreshold(
                    name: "database checkpoint at \(secretPath)",
                    status: .pass,
                    observed: 0,
                    limit: 1,
                    unit: "count",
                    message: "no token=synthetic-secret in \(secretURL)"
                )
            ],
            streams: [
                SoakEvidenceStreamStatusSample(
                    streamID: 1,
                    name: "Main token=synthetic-secret",
                    streamType: "hls",
                    sourceDescription: secretURL,
                    phase: "reconnecting",
                    hasRuntimeStatus: true,
                    attempt: 1,
                    maxAttempts: 3,
                    recentFailure: "failed \(secretURL) \(secretPath)",
                    lifecycleReason: "recovering from \(secretURL) using \(secretPath)",
                    hlsDecisionReason: "duplicate \(secretURL)"
                )
            ],
            runtimeEvents: [
                SoakEvidenceRuntimeEvent(at: "2026-05-01T10:00:00Z", phase: "error", reason: "reason \(secretURL) \(secretPath)")
            ],
            resourceSamples: [
                SoakEvidenceResourceSample(note: "resource sample at \(secretPath)")
            ],
            databaseSnapshots: [
                SoakEvidenceDatabaseSnapshot.unavailable("unavailable \(secretPath)")
            ],
            failures: [
                SoakEvidenceFailure(phase: "encode", message: "EncodingError \(secretURL) \(secretPath)", recoveryGuidance: "retry without token=synthetic-secret")
            ]
        )

        let data = try XCTUnwrap(evidence.jsonData().successValue)
        let payload = try XCTUnwrap(String(data: data, encoding: .utf8))
        assertNoForbiddenSoakSubstrings(payload)
        XCTAssertTrue(payload.contains("[redacted-storage]") || payload.contains("[redacted-path]"))

        let object = try semanticJSONObject(from: data)
        let audit = try XCTUnwrap(object["redactionAudit"] as? [String: Any])
        XCTAssertEqual(audit["passed"] as? Bool, true)
        XCTAssertEqual(audit["forbiddenSubstringCount"] as? Int, 0)
    }

    func testEmptySamplesEncodeUnavailableDiagnosticsAndBoundedAggregateCounts() throws {
        let evidence = SoakEvidence(
            generatedAt: "2026-05-01T10:00:00Z",
            timeRange: SoakEvidenceTimeRange(startedAt: "2026-05-01T10:00:00Z", durationSeconds: -10),
            limits: SoakEvidenceLimits(maxStreams: 1, maxRuntimeEvents: 1, maxResourceSamples: 0, maxQueueSnapshots: 1, maxDatabaseSnapshots: 0, maxFailures: 1),
            streams: [
                SoakEvidenceStreamStatusSample(streamID: 1, name: "A", streamType: "hls", sourceDescription: "https://example.test/a.m3u8", phase: "running", hasRuntimeStatus: true, attempt: 0, maxAttempts: 3),
                SoakEvidenceStreamStatusSample(streamID: 2, name: "B", streamType: "hls", sourceDescription: "https://example.test/b.m3u8", phase: "running", hasRuntimeStatus: true, attempt: 0, maxAttempts: 3)
            ],
            runtimeEvents: [
                SoakEvidenceRuntimeEvent(at: "t1", phase: "running", reason: "one"),
                SoakEvidenceRuntimeEvent(at: "t2", phase: "running", reason: "two")
            ],
            resourceSamples: [],
            queueSnapshots: [
                SoakEvidenceQueueSnapshot(submitted: 1, started: 1, completed: 1, currentDepth: 0, maxDepth: 1, isBusy: false),
                SoakEvidenceQueueSnapshot(submitted: 2, started: 2, completed: 2, currentDepth: 0, maxDepth: 1, isBusy: false)
            ],
            databaseSnapshots: [],
            failures: [
                SoakEvidenceFailure(phase: "one", message: "one"),
                SoakEvidenceFailure(phase: "two", message: "two")
            ]
        )

        XCTAssertEqual(evidence.timeRange.durationSeconds, 0)
        XCTAssertEqual(evidence.streams.count, 1)
        XCTAssertEqual(evidence.runtimeEvents.count, 1)
        XCTAssertEqual(evidence.queueSnapshots.count, 1)
        XCTAssertEqual(evidence.failures.count, 1)
        XCTAssertEqual(evidence.resourceSamples, [.unavailable("Resource sampling unavailable.")])
        XCTAssertEqual(evidence.databaseSnapshots, [.unavailable("Database health unavailable.")])
        XCTAssertEqual(evidence.summary.omittedRuntimeEventCount, 1)
        XCTAssertEqual(evidence.summary.omittedSampleCount, 3)
        XCTAssertEqual(evidence.summary.verdict, .fail)
    }

    func testNDJSONAndUnsupportedFormatReturnTypedRedactedEncodingResults() throws {
        let evidence = Self.sampleEvidence()

        let ndjson = try XCTUnwrap(evidence.ndjsonData().successValue)
        let text = try XCTUnwrap(String(data: ndjson, encoding: .utf8))
        XCTAssertEqual(text.split(separator: "\n").count, 1)
        XCTAssertTrue(text.hasPrefix("{\"databaseSnapshots\":"), text)

        let unsupported = SoakEvidence.renderUnsupportedFormat("xml token=synthetic-secret /tmp/private.sqlite")
        switch unsupported {
        case .success:
            XCTFail("Expected unsupported format to fail")
        case .failure(let failure):
            XCTAssertEqual(failure.message, "Unsupported soak evidence format.")
            XCTAssertFalse(failure.description.contains("synthetic-secret"))
            XCTAssertFalse(failure.description.contains("token="))
            XCTAssertFalse(failure.description.contains(".sqlite"))
        }
    }

    func testShortSoakRunnerRecordsRuntimeQueueDatabaseLifecycleAndRedactedEvidence() async throws {
        let temporary = try TemporarySoundingDatabase()
        let clock = DeterministicSoakClock()
        let runner = SoakProofRunner(
            database: temporary.database,
            configuration: SoakProofRunnerConfiguration(durationSeconds: 0.2, sampleIntervalSeconds: 0.1, maximumSamples: 2),
            resourceProvider: ClosureSoakResourceMetricsProvider { at in
                SoakResourceMetrics(memoryBytes: 4096, cpuPercent: 2.5, openFileDescriptorCount: 12, note: "sample at \(at)")
            },
            now: { clock.next() }
        )

        let result = try await runner.run()
        let evidence = result.evidence
        let payload = try XCTUnwrap(String(data: result.encodedEvidence, encoding: .utf8))

        XCTAssertEqual(evidence.summary.verdict, .pass)
        XCTAssertGreaterThanOrEqual(evidence.streams.count, 2)
        XCTAssertTrue(evidence.streams.contains { $0.name.contains("Short Soak Retry") })
        XCTAssertTrue(evidence.streams.contains { $0.name.contains("Short Soak Sibling") })
        XCTAssertTrue(evidence.runtimeEvents.contains { $0.phase == "reconnecting" })
        XCTAssertTrue(evidence.runtimeEvents.contains { $0.phase == "suspended" || $0.phase == "recovering" || $0.recoveryLatencySeconds != nil })
        XCTAssertTrue(evidence.queueSnapshots.contains { $0.maxDepth > 0 })
        XCTAssertEqual(evidence.queueSnapshots.last?.currentDepth, 0)
        XCTAssertTrue(evidence.databaseSnapshots.contains { $0.status == .healthy })
        XCTAssertTrue(evidence.databaseSnapshots.contains { $0.checkpointLogFrames != nil || $0.checkpointedFrames != nil })
        XCTAssertTrue(evidence.thresholds.allSatisfy { $0.status == .pass })
        XCTAssertEqual(evidence.redactionAudit.passed, true)
        assertNoForbiddenSoakSubstrings(payload)
    }

    func testShortSoakRunnerReportsThresholdResourceAndDatabaseFailuresWithoutLeakingSecrets() async throws {
        let temporary = try TemporarySoundingDatabase()
        let clock = DeterministicSoakClock()
        let degradedHealth = SoundingDatabaseHealth(
            status: .unhealthy,
            journalMode: "wal /tmp/soak-evidence/private.sqlite-wal",
            walAutoCheckpointPages: 0,
            pageSizeBytes: 0,
            pageCount: 0,
            files: SoundingDatabaseFileMetrics(databaseBytes: 0, walBytes: 0, shmBytes: 0),
            quickCheck: SoundingDatabaseCheckSummary(name: "quick", status: .failed, issueCount: 1),
            foreignKeyCheck: SoundingDatabaseCheckSummary(name: "fk", status: .ok, issueCount: 0),
            failure: SoundingDatabaseFailure(phase: .health, guidance: .healthCheck, message: "failed /tmp/soak-evidence/private.sqlite token=synthetic-secret")
        )
        let runner = SoakProofRunner(
            database: temporary.database,
            configuration: SoakProofRunnerConfiguration(
                durationSeconds: 0.1,
                sampleIntervalSeconds: 0.1,
                maximumQueueDepth: 0,
                failOnUnavailableResources: true
            ),
            resourceProvider: ClosureSoakResourceMetricsProvider { _ in
                throw SyntheticResourceFailure(message: "resource failed token=synthetic-secret /tmp/soak-evidence/private.sqlite")
            },
            now: { clock.next() },
            databaseHealth: { _ in degradedHealth },
            databaseCheckpoint: { _ in
                SoundingDatabaseCheckpointResult(
                    status: .degraded,
                    busyFrameCount: 1,
                    logFrameCount: 1,
                    checkpointedFrameCount: 0,
                    failure: SoundingDatabaseFailure(phase: .checkpoint, guidance: .checkpoint, message: "checkpoint failed /tmp/private.sqlite-wal")
                )
            }
        )

        let result = try await runner.run()
        let evidence = result.evidence
        let payload = try XCTUnwrap(String(data: result.encodedEvidence, encoding: .utf8))

        XCTAssertEqual(evidence.summary.verdict, .fail)
        XCTAssertTrue(evidence.thresholds.contains { $0.name == "resourceAvailability" && $0.status == .fail })
        XCTAssertTrue(evidence.thresholds.contains { $0.name == "databaseHealthAndCheckpoint" && $0.status == .fail })
        XCTAssertTrue(evidence.thresholds.contains { $0.name == "queueMaxDepth" && $0.status == .fail })
        XCTAssertGreaterThan(evidence.failures.count, 0)
        XCTAssertEqual(evidence.queueSnapshots.last?.currentDepth, 0)
        XCTAssertTrue(evidence.resourceSamples.contains { $0.availability == .unavailable })
        XCTAssertTrue(evidence.databaseSnapshots.contains { $0.status == .degraded || $0.status == .unhealthy })
        XCTAssertEqual(evidence.redactionAudit.passed, true)
        assertNoForbiddenSoakSubstrings(payload)
    }

    func testShortSoakRunnerRejectsZeroOrNegativeTimingConfiguration() async throws {
        let temporary = try TemporarySoundingDatabase()
        let badDuration = SoakProofRunner(
            database: temporary.database,
            configuration: SoakProofRunnerConfiguration(durationSeconds: 0, sampleIntervalSeconds: 0.1),
            resourceProvider: ClosureSoakResourceMetricsProvider { _ in SoakResourceMetrics() }
        )
        do {
            _ = try await badDuration.run()
            XCTFail("Expected invalid duration to throw")
        } catch let error as SoakProofRunnerError {
            XCTAssertEqual(error, .invalidConfiguration("durationSeconds must be greater than zero."))
        }

        let badInterval = SoakProofRunner(
            database: temporary.database,
            configuration: SoakProofRunnerConfiguration(durationSeconds: 0.1, sampleIntervalSeconds: -1),
            resourceProvider: ClosureSoakResourceMetricsProvider { _ in SoakResourceMetrics() }
        )
        do {
            _ = try await badInterval.run()
            XCTFail("Expected invalid sample interval to throw")
        } catch let error as SoakProofRunnerError {
            XCTAssertEqual(error, .invalidConfiguration("sampleIntervalSeconds must be greater than zero."))
        }
    }

    func testDocumentedSoakEvidenceExampleDecodesAndContainsOnlySafeSyntheticContent() throws {
        let exampleURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/soak-evidence.example.json")
        let data = try Data(contentsOf: exampleURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let evidence = try JSONDecoder().decode(SoakEvidence.self, from: data)

        XCTAssertEqual(evidence.schemaVersion, SoakEvidence.currentSchemaVersion)
        XCTAssertEqual(evidence.summary.verdict, .pass)
        XCTAssertEqual(evidence.redactionAudit.passed, true)
        XCTAssertTrue(evidence.thresholds.contains { $0.name == "databaseHealthAndCheckpoint" })
        XCTAssertTrue(evidence.thresholds.contains { $0.name == "lifecycleRecoveryLatency" })
        XCTAssertTrue(evidence.runtimeEvents.contains { $0.phase == "reconnecting" })
        XCTAssertTrue(evidence.databaseSnapshots.contains { $0.checkpointLogFrames != nil })
        assertNoForbiddenTrackedExampleSubstrings(text)
    }

    private static func sampleEvidence() -> SoakEvidence {
        SoakEvidence(
            generatedAt: "2026-05-01T10:00:02Z",
            timeRange: SoakEvidenceTimeRange(startedAt: "2026-05-01T10:00:00Z", endedAt: "2026-05-01T10:00:02Z", durationSeconds: 2),
            thresholds: [
                SoakEvidenceThreshold(name: "recoveryLatency", status: .pass, observed: 0.2, limit: 5, unit: "seconds", message: "within threshold")
            ],
            streams: [
                SoakEvidenceStreamStatusSample(streamID: 1, name: "Main", streamType: "hls", sourceDescription: "https://example.test/live.m3u8", phase: "running", hasRuntimeStatus: true, attempt: 0, maxAttempts: 3)
            ],
            runtimeEvents: [
                SoakEvidenceRuntimeEvent(at: "2026-05-01T10:00:01Z", streamID: 1, phase: "running", reason: "connected")
            ],
            resourceSamples: [
                SoakEvidenceResourceSample(at: "2026-05-01T10:00:01Z", memoryBytes: 1024, cpuPercent: 1.5, openFileDescriptorCount: 8)
            ],
            queueSnapshots: [
                SoakEvidenceQueueSnapshot(submitted: 1, started: 1, completed: 1, currentDepth: 0, maxDepth: 1, isBusy: false)
            ],
            databaseSnapshots: [
                SoakEvidenceDatabaseSnapshot(status: .healthy, journalMode: "wal", databaseBytes: 4096, walBytes: 0, shmBytes: 0, pageCount: 1, checkpointBusyFrames: 0, checkpointLogFrames: 0, checkpointedFrames: 0, quickCheckStatus: .ok, foreignKeyCheckStatus: .ok)
            ],
            hlsDecisionCounts: SoakEvidenceHLSDecisionCounts(duplicateSegmentCount: 1),
            failures: []
        )
    }
}

private final class DeterministicSoakClock: @unchecked Sendable {
    private let lock = NSLock()
    private var tick: TimeInterval = 0

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let date = Date(timeIntervalSince1970: 1_800_000_000 + tick)
        tick += 0.1
        return date
    }
}

private struct SyntheticResourceFailure: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

private extension Result where Success == Data, Failure == SoakEvidenceEncodingFailure {
    var successValue: Data? {
        guard case .success(let value) = self else { return nil }
        return value
    }
}

private func assertNoForbiddenSoakSubstrings(
    _ payload: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let lowercased = payload.lowercased()
    for forbidden in [
        "token=",
        "synthetic-secret",
        "user:pass",
        "#frag",
        ".sqlite",
        ".wal",
        ".shm",
        "-wal",
        "-shm",
        "/tmp/",
        "/users/",
        "soak-evidence"
    ] {
        XCTAssertFalse(lowercased.contains(forbidden), "Payload leaked forbidden substring \(forbidden): \(payload)", file: file, line: line)
    }
}

private func assertNoForbiddenTrackedExampleSubstrings(
    _ payload: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let lowercased = payload.lowercased()
    for forbidden in [
        "://",
        "?",
        "#",
        "token=",
        "access_token",
        "api_key",
        "synthetic-secret",
        "user:pass",
        "password",
        "passwd",
        "pwd=",
        ".sqlite",
        ".db",
        ".wal",
        ".shm",
        "-wal",
        "-shm",
        "/tmp/",
        "/private/tmp/",
        "/users/",
        "/var/",
        "soak-proof.local",
        "soak-evidence",
        "signing",
        "notary"
    ] {
        XCTAssertFalse(lowercased.contains(forbidden), "Tracked soak evidence example leaked forbidden substring \(forbidden): \(payload)", file: file, line: line)
    }
}
