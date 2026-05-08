import Foundation

public struct SoakProofRunnerConfiguration: Equatable, Sendable {
    public var durationSeconds: Double
    public var sampleIntervalSeconds: Double
    public var maximumReconnectAttempts: Int
    public var maximumSamples: Int
    public var limits: SoakEvidenceLimits
    public var maximumRuntimeFailures: Int
    public var maximumReconnectAttemptsObserved: Int
    public var maximumQueueDepth: Int
    public var maximumRecoveryLatencySeconds: Double
    public var failOnUnavailableResources: Bool
    public var simulateLifecycle: Bool

    public init(
        durationSeconds: Double = 0.3,
        sampleIntervalSeconds: Double = 0.1,
        maximumReconnectAttempts: Int = 1,
        maximumSamples: Int = 8,
        limits: SoakEvidenceLimits = SoakEvidenceLimits(),
        maximumRuntimeFailures: Int = 1,
        maximumReconnectAttemptsObserved: Int = 1,
        maximumQueueDepth: Int = 4,
        maximumRecoveryLatencySeconds: Double = 5,
        failOnUnavailableResources: Bool = false,
        simulateLifecycle: Bool = true
    ) {
        self.durationSeconds = durationSeconds
        self.sampleIntervalSeconds = sampleIntervalSeconds
        self.maximumReconnectAttempts = max(0, maximumReconnectAttempts)
        self.maximumSamples = max(1, maximumSamples)
        self.limits = limits
        self.maximumRuntimeFailures = max(0, maximumRuntimeFailures)
        self.maximumReconnectAttemptsObserved = max(0, maximumReconnectAttemptsObserved)
        self.maximumQueueDepth = max(0, maximumQueueDepth)
        self.maximumRecoveryLatencySeconds = SoakEvidenceSanitizer.nonNegative(maximumRecoveryLatencySeconds)
        self.failOnUnavailableResources = failOnUnavailableResources
        self.simulateLifecycle = simulateLifecycle
    }

    fileprivate func validated() throws -> SoakProofRunnerConfiguration {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw SoakProofRunnerError.invalidConfiguration("durationSeconds must be greater than zero.")
        }
        guard sampleIntervalSeconds.isFinite, sampleIntervalSeconds > 0 else {
            throw SoakProofRunnerError.invalidConfiguration("sampleIntervalSeconds must be greater than zero.")
        }
        guard durationSeconds <= 30 else {
            throw SoakProofRunnerError.invalidConfiguration("short soak duration must be 30 seconds or less.")
        }
        guard sampleIntervalSeconds >= 0.01 else {
            throw SoakProofRunnerError.invalidConfiguration("sampleIntervalSeconds must be at least 0.01 seconds.")
        }
        return self
    }
}

public enum SoakProofRunnerError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidConfiguration(String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let message):
            return SoakEvidenceSanitizer.redact(message)
        }
    }
}

public struct SoakProofRunnerResult: Equatable, Sendable {
    public var evidence: SoakEvidence
    public var encodedEvidence: Data

    public init(evidence: SoakEvidence, encodedEvidence: Data) {
        self.evidence = evidence
        self.encodedEvidence = encodedEvidence
    }
}

public struct SoakProofRunner: Sendable {
    public typealias DateProvider = @Sendable () -> Date
    public typealias DatabaseHealthProvider = @Sendable (SoundingDatabase) -> SoundingDatabaseHealth
    public typealias DatabaseCheckpointProvider = @Sendable (SoundingDatabase) -> SoundingDatabaseCheckpointResult

    private let database: SoundingDatabase
    private let configuration: SoakProofRunnerConfiguration
    private let resourceProvider: any SoakResourceMetricsProvider
    private let evidenceFormat: SoakEvidenceFormat
    private let now: DateProvider
    private let databaseHealth: DatabaseHealthProvider
    private let databaseCheckpoint: DatabaseCheckpointProvider

    public init(
        database: SoundingDatabase,
        configuration: SoakProofRunnerConfiguration = SoakProofRunnerConfiguration(),
        resourceProvider: any SoakResourceMetricsProvider = ProcessSoakResourceMetricsProvider(),
        evidenceFormat: SoakEvidenceFormat = .json,
        now: @escaping DateProvider = { Date() },
        databaseHealth: @escaping DatabaseHealthProvider = { database in database.health(includeIntegrityCheck: false) },
        databaseCheckpoint: @escaping DatabaseCheckpointProvider = { database in database.checkpoint(mode: .passive) }
    ) {
        self.database = database
        self.configuration = configuration
        self.resourceProvider = resourceProvider
        self.evidenceFormat = evidenceFormat
        self.now = now
        self.databaseHealth = databaseHealth
        self.databaseCheckpoint = databaseCheckpoint
    }

    public func run() async throws -> SoakProofRunnerResult {
        let config = try configuration.validated()
        let formatter = Self.timestampFormatter()
        let startedAtDate = now()
        let startedAt = formatter.string(from: startedAtDate)
        let registry = StreamRegistry(database: database)
        let statusStore = AppStreamRuntimeStatusStore(database: database)
        let queue = InferenceQueue()
        let queueGate = SoakProofGate()
        let ingester = SyntheticSoakIngester(queue: queue, gate: queueGate)
        let runtime = AppStreamRuntimeService(
            registry: registry,
            ingester: ingester,
            retryPolicy: AppStreamRuntimeRetryPolicy(
                maximumReconnectAttempts: config.maximumReconnectAttempts,
                backoffSeconds: { _ in 0 }
            ),
            statusStore: statusStore,
            now: now,
            retrySleep: { _ in }
        )
        let eventRecorder = SoakRuntimeEventRecorder(formatter: formatter)
        let eventStream = await runtime.events()
        let eventTask = Task {
            for await event in eventStream {
                await eventRecorder.record(event)
            }
        }

        var failures: [SoakEvidenceFailure] = []
        var resourceSamples: [SoakEvidenceResourceSample] = []
        var queueSnapshots: [SoakEvidenceQueueSnapshot] = []
        var databaseSnapshots: [SoakEvidenceDatabaseSnapshot] = []
        var statusSamples: [SoakEvidenceStreamStatusSample] = []

        do {
            let streams = try seedSyntheticStreams(registry: registry, startedAt: startedAt)
            queueSnapshots.append(SoakEvidenceQueueSnapshot(await queue.snapshot()))

            try await runtime.start(streamID: streams.retrying.id)
            try await runtime.start(streamID: streams.sibling.id)
            await Task.yield()
            queueSnapshots.append(SoakEvidenceQueueSnapshot(await queue.snapshot()))
            await queueGate.release(count: 2)
            for _ in 0..<20 {
                if await eventRecorder.containsPhase(AppStreamRuntimeStatusPhase.reconnecting.rawValue) { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            if config.simulateLifecycle {
                await runtime.suspendForSystemSleep(reason: "synthetic short soak sleep token=synthetic-secret")
                await runtime.recoverFromSystemWake(reason: "synthetic short soak wake token=synthetic-secret")
                await Task.yield()
            }

            let sampleCount = min(
                config.maximumSamples,
                max(1, Int(ceil(config.durationSeconds / config.sampleIntervalSeconds)))
            )
            for _ in 0..<sampleCount {
                let at = formatter.string(from: now())
                do {
                    let metrics = try await resourceProvider.sample(at: at)
                    resourceSamples.append(
                        SoakEvidenceResourceSample(
                            at: at,
                            memoryBytes: metrics.memoryBytes,
                            cpuPercent: metrics.cpuPercent,
                            openFileDescriptorCount: metrics.openFileDescriptorCount,
                            note: metrics.note
                        )
                    )
                } catch {
                    resourceSamples.append(.unavailable("Resource metrics unavailable: \(error)."))
                }

                databaseSnapshots.append(SoakEvidenceDatabaseSnapshot(databaseHealth(database)))
                databaseSnapshots.append(SoakEvidenceDatabaseSnapshot(databaseCheckpoint(database)))
                statusSamples = try statusStore.inspections().map(SoakEvidenceStreamStatusSample.init)
                queueSnapshots.append(SoakEvidenceQueueSnapshot(await queue.snapshot()))
                await Task.yield()
            }

            await queueGate.releaseAll()
            await Task.yield()
            queueSnapshots.append(SoakEvidenceQueueSnapshot(await queue.snapshot()))
            statusSamples = try statusStore.inspections().map(SoakEvidenceStreamStatusSample.init)
        } catch {
            failures.append(SoakEvidenceFailure(phase: "runner", message: String(describing: error)))
        }

        await runtime.stopAll()
        await queueGate.releaseAll()
        await Task.yield()
        queueSnapshots.append(SoakEvidenceQueueSnapshot(await queue.snapshot()))
        eventTask.cancel()

        let runtimeEvents = await eventRecorder.events()
        let endedAtDate = now()
        let endedAt = formatter.string(from: endedAtDate)
        let thresholds = Self.thresholds(
            runtimeEvents: runtimeEvents,
            resourceSamples: resourceSamples,
            queueSnapshots: queueSnapshots,
            databaseSnapshots: databaseSnapshots,
            config: config
        )
        failures.append(contentsOf: Self.failures(thresholds: thresholds, redactionPassed: true))
        let preliminarySummary = SoakEvidenceSummary(
            verdict: thresholds.contains(where: { $0.status == .fail }) || !failures.isEmpty ? .fail : .pass,
            streamCount: statusSamples.count,
            runtimeEventCount: runtimeEvents.count,
            resourceSampleCount: resourceSamples.count,
            queueSnapshotCount: queueSnapshots.count,
            databaseSnapshotCount: databaseSnapshots.count,
            failureCount: failures.count,
            message: thresholds.contains(where: { $0.status == .fail }) || !failures.isEmpty
                ? "Short soak proof recorded failures."
                : "Short soak proof completed."
        )
        var evidence = SoakEvidence(
            generatedAt: endedAt,
            timeRange: SoakEvidenceTimeRange(
                startedAt: startedAt,
                endedAt: endedAt,
                durationSeconds: endedAtDate.timeIntervalSince(startedAtDate)
            ),
            limits: config.limits,
            thresholds: thresholds,
            streams: statusSamples,
            runtimeEvents: runtimeEvents,
            resourceSamples: resourceSamples,
            queueSnapshots: queueSnapshots,
            databaseSnapshots: databaseSnapshots,
            failures: failures,
            summary: preliminarySummary
        )
        if !evidence.redactionAudit.passed {
            var redactionFailures = failures
            redactionFailures.append(
                SoakEvidenceFailure(
                    phase: "redaction-audit",
                    message: "Forbidden substrings remained in short soak evidence."
                )
            )
            evidence = SoakEvidence(
                generatedAt: endedAt,
                timeRange: evidence.timeRange,
                limits: config.limits,
                thresholds: thresholds + [
                    SoakEvidenceThreshold(
                        name: "redactionAudit",
                        status: .fail,
                        observed: Double(evidence.redactionAudit.forbiddenSubstringCount),
                        limit: 0,
                        unit: "count",
                        message: "Forbidden substrings remained in short soak evidence."
                    )
                ],
                streams: statusSamples,
                runtimeEvents: runtimeEvents,
                resourceSamples: resourceSamples,
                queueSnapshots: queueSnapshots,
                databaseSnapshots: databaseSnapshots,
                failures: redactionFailures,
                summary: SoakEvidenceSummary(
                    verdict: .fail,
                    streamCount: statusSamples.count,
                    runtimeEventCount: runtimeEvents.count,
                    resourceSampleCount: resourceSamples.count,
                    queueSnapshotCount: queueSnapshots.count,
                    databaseSnapshotCount: databaseSnapshots.count,
                    failureCount: redactionFailures.count,
                    message: "Short soak proof failed redaction audit."
                )
            )
        }
        let encoded: Data
        switch evidence.render(evidenceFormat) {
        case .success(let data):
            encoded = data
        case .failure(let failure):
            throw failure
        }
        return SoakProofRunnerResult(evidence: evidence, encodedEvidence: encoded)
    }

    private func seedSyntheticStreams(registry: StreamRegistry, startedAt: String) throws -> (retrying: StreamRecord, sibling: StreamRecord) {
        let suffix = UUID().uuidString
        let retrying = try registry.add(
            name: "Short Soak Retry \(suffix)",
            streamType: StreamType.hls.rawValue,
            source: "https://user:pass@example.test/short-soak/retry.m3u8?token=synthetic-secret#frag",
            createdAt: startedAt
        )
        let sibling = try registry.add(
            name: "Short Soak Sibling \(suffix)",
            streamType: StreamType.icy.rawValue,
            source: "http://user:pass@example.test/short-soak/sibling?token=synthetic-secret#frag",
            createdAt: startedAt
        )
        return (retrying, sibling)
    }

    private static func thresholds(
        runtimeEvents: [SoakEvidenceRuntimeEvent],
        resourceSamples: [SoakEvidenceResourceSample],
        queueSnapshots: [SoakEvidenceQueueSnapshot],
        databaseSnapshots: [SoakEvidenceDatabaseSnapshot],
        config: SoakProofRunnerConfiguration
    ) -> [SoakEvidenceThreshold] {
        let reconnects = runtimeEvents.filter { $0.phase == AppStreamRuntimeStatusPhase.reconnecting.rawValue }.count
        let runtimeErrors = runtimeEvents.filter { $0.phase == AppStreamRuntimeStatusPhase.error.rawValue }.count
        let maxQueueDepth = queueSnapshots.map(\.maxDepth).max() ?? 0
        let finalQueueDepth = queueSnapshots.last?.currentDepth ?? 0
        let maxRecoveryLatency = runtimeEvents.compactMap(\.recoveryLatencySeconds).max() ?? 0
        let databaseFailures = databaseSnapshots.filter { snapshot in
            snapshot.availability == .unavailable || snapshot.status == .degraded || snapshot.status == .unhealthy || snapshot.failure != nil
        }.count
        let unavailableResources = resourceSamples.filter { $0.availability == .unavailable }.count

        return [
            SoakEvidenceThreshold(
                name: "runtimeReconnectAttempts",
                status: reconnects <= config.maximumReconnectAttemptsObserved ? .pass : .fail,
                observed: Double(reconnects),
                limit: Double(config.maximumReconnectAttemptsObserved),
                unit: "count",
                message: reconnects <= config.maximumReconnectAttemptsObserved ? "bounded reconnect evidence recorded" : "reconnect attempts exceeded threshold"
            ),
            SoakEvidenceThreshold(
                name: "runtimeTerminalErrors",
                status: runtimeErrors <= config.maximumRuntimeFailures ? .pass : .fail,
                observed: Double(runtimeErrors),
                limit: Double(config.maximumRuntimeFailures),
                unit: "count",
                message: runtimeErrors <= config.maximumRuntimeFailures ? "terminal runtime errors within threshold" : "terminal runtime errors exceeded threshold"
            ),
            SoakEvidenceThreshold(
                name: "queueFinalDepth",
                status: finalQueueDepth == 0 ? .pass : .fail,
                observed: Double(finalQueueDepth),
                limit: 0,
                unit: "count",
                message: finalQueueDepth == 0 ? "inference queue drained" : "inference queue did not drain"
            ),
            SoakEvidenceThreshold(
                name: "queueMaxDepth",
                status: maxQueueDepth <= config.maximumQueueDepth ? .pass : .fail,
                observed: Double(maxQueueDepth),
                limit: Double(config.maximumQueueDepth),
                unit: "count",
                message: maxQueueDepth <= config.maximumQueueDepth ? "queue depth stayed within threshold" : "queue depth exceeded threshold"
            ),
            SoakEvidenceThreshold(
                name: "databaseHealthAndCheckpoint",
                status: databaseFailures == 0 ? .pass : .fail,
                observed: Double(databaseFailures),
                limit: 0,
                unit: "count",
                message: databaseFailures == 0 ? "database health and checkpoint samples healthy" : "database health or checkpoint degraded"
            ),
            SoakEvidenceThreshold(
                name: "resourceAvailability",
                status: unavailableResources == 0 || !config.failOnUnavailableResources ? .pass : .fail,
                observed: Double(unavailableResources),
                limit: 0,
                unit: "count",
                message: unavailableResources == 0 ? "resource samples available" : "resource samples unavailable but non-fatal"
            ),
            SoakEvidenceThreshold(
                name: "lifecycleRecoveryLatency",
                status: maxRecoveryLatency <= config.maximumRecoveryLatencySeconds ? .pass : .fail,
                observed: maxRecoveryLatency,
                limit: config.maximumRecoveryLatencySeconds,
                unit: "seconds",
                message: maxRecoveryLatency <= config.maximumRecoveryLatencySeconds ? "lifecycle recovery latency within threshold" : "lifecycle recovery latency exceeded threshold"
            )
        ]
    }

    private static func failures(thresholds: [SoakEvidenceThreshold], redactionPassed: Bool) -> [SoakEvidenceFailure] {
        var failures = thresholds.filter { $0.status == .fail }.map { threshold in
            SoakEvidenceFailure(phase: "threshold", message: threshold.message)
        }
        if !redactionPassed {
            failures.append(SoakEvidenceFailure(phase: "redaction-audit", message: "Redaction audit failed."))
        }
        return failures
    }

    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

private actor SoakRuntimeEventRecorder {
    private let formatter: ISO8601DateFormatter
    private var recorded: [SoakEvidenceRuntimeEvent] = []

    init(formatter: ISO8601DateFormatter) {
        self.formatter = formatter
    }

    func record(_ event: AppStreamRuntimeEvent) {
        recorded.append(
            SoakEvidenceRuntimeEvent(
                at: formatter.string(from: Date()),
                streamID: event.streamID,
                phase: event.phase.statusPhase.rawValue,
                reason: event.message,
                recoveryLatencySeconds: event.lifecycleEvidence?.recoveryLatencySeconds
            )
        )
    }

    func containsPhase(_ phase: String) -> Bool {
        recorded.contains { $0.phase == phase }
    }

    func events() -> [SoakEvidenceRuntimeEvent] {
        recorded
    }
}

private actor SoakProofGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releasedCount = 0

    func wait() async {
        if releasedCount > 0 {
            releasedCount -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release(count: Int) {
        let bounded = max(0, count)
        let current = Array(waiters.prefix(bounded))
        waiters.removeFirst(min(bounded, waiters.count))
        releasedCount += max(0, bounded - current.count)
        for waiter in current { waiter.resume() }
    }

    func releaseAll() {
        releasedCount = max(releasedCount, 4)
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private actor SyntheticSoakIngester: AppStreamRuntimeIngesting {
    private let queue: InferenceQueue
    private let gate: SoakProofGate
    private var callsByStream: [Int64: Int] = [:]

    init(queue: InferenceQueue, gate: SoakProofGate) {
        self.queue = queue
        self.gate = gate
    }

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        let nextCall = (callsByStream[request.streamID] ?? 0) + 1
        callsByStream[request.streamID] = nextCall
        let shouldExerciseRetry = request.name.contains("Short Soak Retry")
        try await queue.run("soak-proof") {
            await gate.wait()
        }
        try Task.checkCancellation()
        if shouldExerciseRetry, nextCall == 1 {
            throw SyntheticSoakFailure(
                message: "synthetic runtime failure for https://user:pass@example.test/fail.m3u8?token=synthetic-secret#frag"
            )
        }
        return AppStreamRuntimeResult(streamID: request.streamID, processedChunks: 1)
    }
}

private struct SyntheticSoakFailure: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}
