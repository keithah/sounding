import Foundation

public enum SoakEvidenceFormat: String, Codable, Equatable, Sendable {
    case json
    case ndjson
}

public enum SoakEvidenceThresholdStatus: String, Codable, Equatable, Sendable {
    case pass
    case fail
    case unavailable
}

public enum SoakEvidenceDiagnosticAvailability: String, Codable, Equatable, Sendable {
    case available
    case unavailable
}

public struct SoakEvidenceLimits: Codable, Equatable, Sendable {
    public var maxStreams: Int
    public var maxRuntimeEvents: Int
    public var maxResourceSamples: Int
    public var maxQueueSnapshots: Int
    public var maxDatabaseSnapshots: Int
    public var maxFailures: Int

    public init(
        maxStreams: Int = 16,
        maxRuntimeEvents: Int = 256,
        maxResourceSamples: Int = 256,
        maxQueueSnapshots: Int = 256,
        maxDatabaseSnapshots: Int = 64,
        maxFailures: Int = 64
    ) {
        self.maxStreams = Self.safeLimit(maxStreams)
        self.maxRuntimeEvents = Self.safeLimit(maxRuntimeEvents)
        self.maxResourceSamples = Self.safeLimit(maxResourceSamples)
        self.maxQueueSnapshots = Self.safeLimit(maxQueueSnapshots)
        self.maxDatabaseSnapshots = Self.safeLimit(maxDatabaseSnapshots)
        self.maxFailures = Self.safeLimit(maxFailures)
    }

    private static func safeLimit(_ value: Int) -> Int {
        max(0, value)
    }
}

public struct SoakEvidenceTimeRange: Codable, Equatable, Sendable {
    public var startedAt: String
    public var endedAt: String?
    public var durationSeconds: Double

    public init(startedAt: String, endedAt: String? = nil, durationSeconds: Double) {
        self.startedAt = SoakEvidenceSanitizer.redact(startedAt)
        self.endedAt = endedAt.map(SoakEvidenceSanitizer.redact)
        self.durationSeconds = SoakEvidenceSanitizer.nonNegative(durationSeconds)
    }
}

public struct SoakEvidenceThreshold: Codable, Equatable, Sendable {
    public var name: String
    public var status: SoakEvidenceThresholdStatus
    public var observed: Double?
    public var limit: Double?
    public var unit: String
    public var message: String

    public init(
        name: String,
        status: SoakEvidenceThresholdStatus,
        observed: Double? = nil,
        limit: Double? = nil,
        unit: String,
        message: String
    ) {
        self.name = SoakEvidenceSanitizer.redact(name)
        self.status = status
        self.observed = observed.map(SoakEvidenceSanitizer.nonNegative)
        self.limit = limit.map(SoakEvidenceSanitizer.nonNegative)
        self.unit = SoakEvidenceSanitizer.redact(unit)
        self.message = SoakEvidenceSanitizer.redact(message)
    }

    public static func unavailable(_ name: String, message: String) -> SoakEvidenceThreshold {
        SoakEvidenceThreshold(name: name, status: .unavailable, unit: "count", message: message)
    }
}

public struct SoakEvidenceStreamStatusSample: Codable, Equatable, Sendable {
    public var streamID: Int64
    public var name: String
    public var streamType: String
    public var sourceDescription: String
    public var phase: String
    public var hasRuntimeStatus: Bool
    public var attempt: Int
    public var maxAttempts: Int
    public var nextRetrySeconds: Int?
    public var updatedAt: String?
    public var recentFailure: String?
    public var lifecycleReason: String?
    public var recoveryLatencySeconds: Double?
    public var hlsDecisionReason: String?

    public init(
        streamID: Int64,
        name: String,
        streamType: String,
        sourceDescription: String,
        phase: String,
        hasRuntimeStatus: Bool,
        attempt: Int,
        maxAttempts: Int,
        nextRetrySeconds: Int? = nil,
        updatedAt: String? = nil,
        recentFailure: String? = nil,
        lifecycleReason: String? = nil,
        recoveryLatencySeconds: Double? = nil,
        hlsDecisionReason: String? = nil
    ) {
        self.streamID = max(0, streamID)
        self.name = SoakEvidenceSanitizer.redact(name)
        self.streamType = SoakEvidenceSanitizer.redact(streamType)
        self.sourceDescription = SoakEvidenceSanitizer.sourceDescription(sourceDescription)
        self.phase = SoakEvidenceSanitizer.redact(phase)
        self.hasRuntimeStatus = hasRuntimeStatus
        self.attempt = max(0, attempt)
        self.maxAttempts = max(0, maxAttempts)
        self.nextRetrySeconds = nextRetrySeconds.map { max(0, $0) }
        self.updatedAt = updatedAt.map(SoakEvidenceSanitizer.redact)
        self.recentFailure = recentFailure.map(SoakEvidenceSanitizer.redact)
        self.lifecycleReason = lifecycleReason.map(SoakEvidenceSanitizer.redact)
        self.recoveryLatencySeconds = recoveryLatencySeconds.map(SoakEvidenceSanitizer.nonNegative)
        self.hlsDecisionReason = hlsDecisionReason.map(SoakEvidenceSanitizer.redact)
    }

    public init(_ inspection: AppStreamRuntimeStatusInspection) {
        self.init(
            streamID: inspection.streamID,
            name: inspection.name,
            streamType: inspection.streamType,
            sourceDescription: inspection.sourceDescription,
            phase: inspection.phase,
            hasRuntimeStatus: inspection.hasRuntimeStatus,
            attempt: inspection.attempt,
            maxAttempts: inspection.maxAttempts,
            nextRetrySeconds: inspection.nextRetrySeconds,
            updatedAt: inspection.updatedAt,
            recentFailure: inspection.recentFailure?.message,
            lifecycleReason: inspection.lifecycleEvidence?.reason,
            recoveryLatencySeconds: inspection.lifecycleEvidence?.recoveryLatencySeconds,
            hlsDecisionReason: inspection.latestHLSDecision?.reason
        )
    }
}

public struct SoakEvidenceRuntimeEvent: Codable, Equatable, Sendable {
    public var at: String
    public var streamID: Int64?
    public var phase: String
    public var reason: String
    public var attempt: Int
    public var recoveryLatencySeconds: Double?

    public init(
        at: String,
        streamID: Int64? = nil,
        phase: String,
        reason: String,
        attempt: Int = 0,
        recoveryLatencySeconds: Double? = nil
    ) {
        self.at = SoakEvidenceSanitizer.redact(at)
        self.streamID = streamID.map { max(0, $0) }
        self.phase = SoakEvidenceSanitizer.redact(phase)
        self.reason = SoakEvidenceSanitizer.redact(reason)
        self.attempt = max(0, attempt)
        self.recoveryLatencySeconds = recoveryLatencySeconds.map(SoakEvidenceSanitizer.nonNegative)
    }
}

public struct SoakEvidenceResourceSample: Codable, Equatable, Sendable {
    public var availability: SoakEvidenceDiagnosticAvailability
    public var at: String?
    public var memoryBytes: Int64?
    public var cpuPercent: Double?
    public var openFileDescriptorCount: Int?
    public var note: String?

    public init(
        availability: SoakEvidenceDiagnosticAvailability = .available,
        at: String? = nil,
        memoryBytes: Int64? = nil,
        cpuPercent: Double? = nil,
        openFileDescriptorCount: Int? = nil,
        note: String? = nil
    ) {
        self.availability = availability
        self.at = at.map(SoakEvidenceSanitizer.redact)
        self.memoryBytes = memoryBytes.map { max(0, $0) }
        self.cpuPercent = cpuPercent.map(SoakEvidenceSanitizer.nonNegative)
        self.openFileDescriptorCount = openFileDescriptorCount.map { max(0, $0) }
        self.note = note.map(SoakEvidenceSanitizer.redact)
    }

    public static func unavailable(_ note: String) -> SoakEvidenceResourceSample {
        SoakEvidenceResourceSample(availability: .unavailable, note: note)
    }
}

public struct SoakEvidenceQueueSnapshot: Codable, Equatable, Sendable {
    public var submitted: Int
    public var started: Int
    public var completed: Int
    public var currentDepth: Int
    public var maxDepth: Int
    public var isBusy: Bool

    public init(
        submitted: Int,
        started: Int,
        completed: Int,
        currentDepth: Int,
        maxDepth: Int,
        isBusy: Bool
    ) {
        self.submitted = max(0, submitted)
        self.started = max(0, started)
        self.completed = max(0, completed)
        self.currentDepth = max(0, currentDepth)
        self.maxDepth = max(0, maxDepth)
        self.isBusy = isBusy
    }

    public init(_ snapshot: InferenceQueue.Snapshot) {
        self.init(
            submitted: snapshot.submitted,
            started: snapshot.started,
            completed: snapshot.completed,
            currentDepth: snapshot.currentDepth,
            maxDepth: snapshot.maxDepth,
            isBusy: snapshot.isBusy
        )
    }
}

public struct SoakEvidenceDatabaseSnapshot: Codable, Equatable, Sendable {
    public var availability: SoakEvidenceDiagnosticAvailability
    public var status: SoundingDatabaseOperationalStatus?
    public var journalMode: String?
    public var databaseBytes: Int64?
    public var walBytes: Int64?
    public var shmBytes: Int64?
    public var pageCount: Int?
    public var checkpointBusyFrames: Int?
    public var checkpointLogFrames: Int?
    public var checkpointedFrames: Int?
    public var quickCheckStatus: SoundingDatabaseCheckStatus?
    public var foreignKeyCheckStatus: SoundingDatabaseCheckStatus?
    public var failure: SoakEvidenceFailure?
    public var note: String?

    public init(
        availability: SoakEvidenceDiagnosticAvailability = .available,
        status: SoundingDatabaseOperationalStatus? = nil,
        journalMode: String? = nil,
        databaseBytes: Int64? = nil,
        walBytes: Int64? = nil,
        shmBytes: Int64? = nil,
        pageCount: Int? = nil,
        checkpointBusyFrames: Int? = nil,
        checkpointLogFrames: Int? = nil,
        checkpointedFrames: Int? = nil,
        quickCheckStatus: SoundingDatabaseCheckStatus? = nil,
        foreignKeyCheckStatus: SoundingDatabaseCheckStatus? = nil,
        failure: SoakEvidenceFailure? = nil,
        note: String? = nil
    ) {
        self.availability = availability
        self.status = status
        self.journalMode = journalMode.map(SoakEvidenceSanitizer.redact)
        self.databaseBytes = databaseBytes.map { max(0, $0) }
        self.walBytes = walBytes.map { max(0, $0) }
        self.shmBytes = shmBytes.map { max(0, $0) }
        self.pageCount = pageCount.map { max(0, $0) }
        self.checkpointBusyFrames = checkpointBusyFrames.map { max(0, $0) }
        self.checkpointLogFrames = checkpointLogFrames.map { max(0, $0) }
        self.checkpointedFrames = checkpointedFrames.map { max(0, $0) }
        self.quickCheckStatus = quickCheckStatus
        self.foreignKeyCheckStatus = foreignKeyCheckStatus
        self.failure = failure
        self.note = note.map(SoakEvidenceSanitizer.redact)
    }

    public init(_ health: SoundingDatabaseHealth) {
        self.init(
            status: health.status,
            journalMode: health.journalMode,
            databaseBytes: health.files.databaseBytes,
            walBytes: health.files.walBytes,
            shmBytes: health.files.shmBytes,
            pageCount: health.pageCount,
            checkpointBusyFrames: health.checkpoint?.busyFrameCount,
            checkpointLogFrames: health.checkpoint?.logFrameCount,
            checkpointedFrames: health.checkpoint?.checkpointedFrameCount,
            quickCheckStatus: health.quickCheck.status,
            foreignKeyCheckStatus: health.foreignKeyCheck.status,
            failure: health.failure.map(SoakEvidenceFailure.init)
        )
    }

    public init(_ checkpoint: SoundingDatabaseCheckpointResult) {
        self.init(
            status: checkpoint.status,
            checkpointBusyFrames: checkpoint.busyFrameCount,
            checkpointLogFrames: checkpoint.logFrameCount,
            checkpointedFrames: checkpoint.checkpointedFrameCount,
            failure: checkpoint.failure.map(SoakEvidenceFailure.init)
        )
    }

    public static func unavailable(_ note: String) -> SoakEvidenceDatabaseSnapshot {
        SoakEvidenceDatabaseSnapshot(availability: .unavailable, note: note)
    }
}

public struct SoakEvidenceHLSDecisionCounts: Codable, Equatable, Sendable {
    public var duplicateSegmentCount: Int
    public var mediaSequenceGapCount: Int
    public var segmentIdentityConflictCount: Int
    public var unavailableCount: Int

    public init(
        duplicateSegmentCount: Int = 0,
        mediaSequenceGapCount: Int = 0,
        segmentIdentityConflictCount: Int = 0,
        unavailableCount: Int = 0
    ) {
        self.duplicateSegmentCount = max(0, duplicateSegmentCount)
        self.mediaSequenceGapCount = max(0, mediaSequenceGapCount)
        self.segmentIdentityConflictCount = max(0, segmentIdentityConflictCount)
        self.unavailableCount = max(0, unavailableCount)
    }
}

public struct SoakEvidenceFailure: Codable, Equatable, Sendable {
    public var phase: String
    public var message: String
    public var recoveryGuidance: String?

    public init(phase: String, message: String, recoveryGuidance: String? = nil) {
        self.phase = SoakEvidenceSanitizer.redact(phase)
        self.message = SoakEvidenceSanitizer.redact(message)
        self.recoveryGuidance = recoveryGuidance.map(SoakEvidenceSanitizer.redact)
    }

    public init(_ failure: SoundingDatabaseFailure) {
        self.init(
            phase: failure.phase.rawValue,
            message: failure.message,
            recoveryGuidance: failure.guidance.rawValue
        )
    }
}

public struct SoakEvidenceSummary: Codable, Equatable, Sendable {
    public var verdict: SoakEvidenceThresholdStatus
    public var streamCount: Int
    public var runtimeEventCount: Int
    public var resourceSampleCount: Int
    public var queueSnapshotCount: Int
    public var databaseSnapshotCount: Int
    public var failureCount: Int
    public var omittedRuntimeEventCount: Int
    public var omittedSampleCount: Int
    public var message: String

    public init(
        verdict: SoakEvidenceThresholdStatus,
        streamCount: Int,
        runtimeEventCount: Int,
        resourceSampleCount: Int,
        queueSnapshotCount: Int,
        databaseSnapshotCount: Int,
        failureCount: Int,
        omittedRuntimeEventCount: Int = 0,
        omittedSampleCount: Int = 0,
        message: String
    ) {
        self.verdict = verdict
        self.streamCount = max(0, streamCount)
        self.runtimeEventCount = max(0, runtimeEventCount)
        self.resourceSampleCount = max(0, resourceSampleCount)
        self.queueSnapshotCount = max(0, queueSnapshotCount)
        self.databaseSnapshotCount = max(0, databaseSnapshotCount)
        self.failureCount = max(0, failureCount)
        self.omittedRuntimeEventCount = max(0, omittedRuntimeEventCount)
        self.omittedSampleCount = max(0, omittedSampleCount)
        self.message = SoakEvidenceSanitizer.redact(message)
    }
}

public struct SoakEvidenceRedactionAudit: Codable, Equatable, Sendable {
    public var checkedStringCount: Int
    public var forbiddenSubstringCount: Int
    public var forbiddenSubstrings: [String]
    public var passed: Bool

    public init(checkedStringCount: Int, forbiddenSubstringCount: Int, forbiddenSubstrings: [String], passed: Bool) {
        self.checkedStringCount = max(0, checkedStringCount)
        self.forbiddenSubstringCount = max(0, forbiddenSubstringCount)
        self.forbiddenSubstrings = forbiddenSubstrings.map(SoakEvidenceSanitizer.redact).sorted()
        self.passed = passed
    }
}

public struct SoakEvidenceEncodingFailure: Codable, Equatable, Error, Sendable, CustomStringConvertible {
    public var format: String
    public var message: String

    public init(format: String, message: String) {
        self.format = SoakEvidenceSanitizer.redact(format)
        self.message = SoakEvidenceSanitizer.redact(message)
    }

    public var description: String {
        "SoakEvidenceEncodingFailure(format: \(format), message: \(message))"
    }
}

public struct SoakEvidence: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generatedAt: String
    public var timeRange: SoakEvidenceTimeRange
    public var limits: SoakEvidenceLimits
    public var thresholds: [SoakEvidenceThreshold]
    public var streams: [SoakEvidenceStreamStatusSample]
    public var runtimeEvents: [SoakEvidenceRuntimeEvent]
    public var resourceSamples: [SoakEvidenceResourceSample]
    public var queueSnapshots: [SoakEvidenceQueueSnapshot]
    public var databaseSnapshots: [SoakEvidenceDatabaseSnapshot]
    public var hlsDecisionCounts: SoakEvidenceHLSDecisionCounts
    public var failures: [SoakEvidenceFailure]
    public var summary: SoakEvidenceSummary
    public var redactionAudit: SoakEvidenceRedactionAudit

    public init(
        schemaVersion: Int = SoakEvidence.currentSchemaVersion,
        generatedAt: String,
        timeRange: SoakEvidenceTimeRange,
        limits: SoakEvidenceLimits = SoakEvidenceLimits(),
        thresholds: [SoakEvidenceThreshold] = [],
        streams: [SoakEvidenceStreamStatusSample] = [],
        runtimeEvents: [SoakEvidenceRuntimeEvent] = [],
        resourceSamples: [SoakEvidenceResourceSample] = [],
        queueSnapshots: [SoakEvidenceQueueSnapshot] = [],
        databaseSnapshots: [SoakEvidenceDatabaseSnapshot] = [],
        hlsDecisionCounts: SoakEvidenceHLSDecisionCounts = SoakEvidenceHLSDecisionCounts(),
        failures: [SoakEvidenceFailure] = [],
        summary: SoakEvidenceSummary? = nil,
        redactionAudit: SoakEvidenceRedactionAudit? = nil
    ) {
        let safeLimits = limits
        let boundedStreams = Array(streams.prefix(safeLimits.maxStreams))
        let boundedRuntimeEvents = Array(runtimeEvents.prefix(safeLimits.maxRuntimeEvents))
        let boundedResourceSamples = Array(resourceSamples.prefix(safeLimits.maxResourceSamples))
        let boundedQueueSnapshots = Array(queueSnapshots.prefix(safeLimits.maxQueueSnapshots))
        let boundedDatabaseSnapshots = Array(databaseSnapshots.prefix(safeLimits.maxDatabaseSnapshots))
        let boundedFailures = Array(failures.prefix(safeLimits.maxFailures))
        let omittedRuntimeEvents = max(0, runtimeEvents.count - boundedRuntimeEvents.count)
        let omittedSamples = max(0, resourceSamples.count - boundedResourceSamples.count)
            + max(0, queueSnapshots.count - boundedQueueSnapshots.count)
            + max(0, databaseSnapshots.count - boundedDatabaseSnapshots.count)
            + max(0, streams.count - boundedStreams.count)
            + max(0, failures.count - boundedFailures.count)

        self.schemaVersion = max(0, schemaVersion)
        self.generatedAt = SoakEvidenceSanitizer.redact(generatedAt)
        self.timeRange = timeRange
        self.limits = safeLimits
        self.thresholds = thresholds
        self.streams = boundedStreams
        self.runtimeEvents = boundedRuntimeEvents
        self.resourceSamples = boundedResourceSamples.isEmpty ? [.unavailable("Resource sampling unavailable.")] : boundedResourceSamples
        self.queueSnapshots = boundedQueueSnapshots
        self.databaseSnapshots = boundedDatabaseSnapshots.isEmpty ? [.unavailable("Database health unavailable.")] : boundedDatabaseSnapshots
        self.hlsDecisionCounts = hlsDecisionCounts
        self.failures = boundedFailures
        self.summary = summary ?? SoakEvidenceSummary(
            verdict: boundedFailures.isEmpty && !thresholds.contains(where: { $0.status == .fail }) ? .pass : .fail,
            streamCount: boundedStreams.count,
            runtimeEventCount: boundedRuntimeEvents.count,
            resourceSampleCount: self.resourceSamples.count,
            queueSnapshotCount: boundedQueueSnapshots.count,
            databaseSnapshotCount: self.databaseSnapshots.count,
            failureCount: boundedFailures.count,
            omittedRuntimeEventCount: omittedRuntimeEvents,
            omittedSampleCount: omittedSamples,
            message: boundedFailures.isEmpty ? "Soak proof completed." : "Soak proof recorded failures."
        )
        self.redactionAudit = redactionAudit ?? SoakEvidenceRedactionAudit.inspect(
            generatedAt: self.generatedAt,
            timeRange: self.timeRange,
            thresholds: self.thresholds,
            streams: self.streams,
            runtimeEvents: self.runtimeEvents,
            resourceSamples: self.resourceSamples,
            databaseSnapshots: self.databaseSnapshots,
            failures: self.failures,
            summary: self.summary
        )
    }

    public func render(_ format: SoakEvidenceFormat) -> Result<Data, SoakEvidenceEncodingFailure> {
        switch format {
        case .json:
            return Self.encodeJSON(self)
        case .ndjson:
            return Self.encodeNDJSON([self])
        }
    }

    public func jsonData() -> Result<Data, SoakEvidenceEncodingFailure> {
        render(.json)
    }

    public func ndjsonData() -> Result<Data, SoakEvidenceEncodingFailure> {
        render(.ndjson)
    }

    public static func encodeJSON<T: Encodable>(_ value: T) -> Result<Data, SoakEvidenceEncodingFailure> {
        do {
            return .success(try stableJSONEncoder().encode(value))
        } catch {
            return .failure(SoakEvidenceEncodingFailure(format: SoakEvidenceFormat.json.rawValue, message: String(describing: error)))
        }
    }

    public static func encodeNDJSON<T: Encodable>(_ values: [T]) -> Result<Data, SoakEvidenceEncodingFailure> {
        do {
            let lines = try values.map { value -> String in
                let data = try stableJSONEncoder().encode(value)
                guard let line = String(data: data, encoding: .utf8) else {
                    throw SoakEvidenceInternalEncodingError.invalidUTF8
                }
                return line
            }
            return .success(Data(lines.joined(separator: "\n").utf8))
        } catch {
            return .failure(SoakEvidenceEncodingFailure(format: SoakEvidenceFormat.ndjson.rawValue, message: String(describing: error)))
        }
    }

    public static func renderUnsupportedFormat(_ rawFormat: String) -> Result<Data, SoakEvidenceEncodingFailure> {
        .failure(SoakEvidenceEncodingFailure(format: rawFormat, message: "Unsupported soak evidence format."))
    }

    private static func stableJSONEncoder() -> JSONEncoder {
        SoundingJSONCoding.stableEncoder()
    }
}

private enum SoakEvidenceInternalEncodingError: Error {
    case invalidUTF8
}

enum SoakEvidenceSanitizer {
    static let forbiddenSubstrings = [
        "token=",
        "synthetic-secret",
        "user:pass",
        "#frag",
        ".sqlite",
        ".wal",
        ".shm",
        "-wal",
        "-shm",
        "/Users/",
        "/tmp/",
        "/private/tmp/",
        "soak-evidence"
    ]

    static func redact(_ value: String) -> String {
        scrubStorageArtifacts(IngestRedaction.diagnostic(value))
    }

    static func sourceDescription(_ value: String) -> String {
        scrubStorageArtifacts(IngestRedaction.diagnosticSourceDescription(value))
    }

    static func nonNegative(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    private static func scrubStorageArtifacts(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"(?i)[^\s\"'<>)]*(?:\.sqlite|\.wal|\.shm|-wal|-shm)[^\s\"'<>)]*"#,
            with: "[redacted-storage]",
            options: .regularExpression
        )
    }

}

private extension SoakEvidenceRedactionAudit {
    static func inspect(
        generatedAt: String,
        timeRange: SoakEvidenceTimeRange,
        thresholds: [SoakEvidenceThreshold],
        streams: [SoakEvidenceStreamStatusSample],
        runtimeEvents: [SoakEvidenceRuntimeEvent],
        resourceSamples: [SoakEvidenceResourceSample],
        databaseSnapshots: [SoakEvidenceDatabaseSnapshot],
        failures: [SoakEvidenceFailure],
        summary: SoakEvidenceSummary
    ) -> SoakEvidenceRedactionAudit {
        var strings: [String] = [generatedAt, timeRange.startedAt, summary.message]
        if let endedAt = timeRange.endedAt { strings.append(endedAt) }
        strings.append(contentsOf: thresholds.flatMap { threshold in
            [threshold.name, threshold.unit, threshold.message]
        })
        strings.append(contentsOf: streams.flatMap { stream in
            [stream.name, stream.streamType, stream.sourceDescription, stream.phase]
                + [stream.updatedAt, stream.recentFailure, stream.lifecycleReason, stream.hlsDecisionReason].compactMap { $0 }
        })
        strings.append(contentsOf: runtimeEvents.flatMap { event in
            [event.at, event.phase, event.reason]
        })
        strings.append(contentsOf: resourceSamples.compactMap(\.at))
        strings.append(contentsOf: resourceSamples.compactMap(\.note))
        strings.append(contentsOf: databaseSnapshots.compactMap(\.journalMode))
        strings.append(contentsOf: databaseSnapshots.compactMap(\.note))
        strings.append(contentsOf: failures.flatMap { failure in
            [failure.phase, failure.message] + [failure.recoveryGuidance].compactMap { $0 }
        })

        let lowercasedPayload = strings.joined(separator: "\n").lowercased()
        let found = SoakEvidenceSanitizer.forbiddenSubstrings.filter { lowercasedPayload.contains($0.lowercased()) }
        return SoakEvidenceRedactionAudit(
            checkedStringCount: strings.count,
            forbiddenSubstringCount: found.count,
            forbiddenSubstrings: found,
            passed: found.isEmpty
        )
    }
}
