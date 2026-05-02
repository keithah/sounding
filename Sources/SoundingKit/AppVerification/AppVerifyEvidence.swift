import Foundation

public enum AppVerifyEvidenceStatus: String, Codable, Equatable, Sendable, Comparable {
    case pass
    case warn
    case fail

    public static func < (lhs: AppVerifyEvidenceStatus, rhs: AppVerifyEvidenceStatus) -> Bool {
        lhs.severityRank < rhs.severityRank
    }

    public var passed: Bool { self == .pass }

    private var severityRank: Int {
        switch self {
        case .pass: return 0
        case .warn: return 1
        case .fail: return 2
        }
    }
}

public enum AppVerifyRuntimePhase: String, Codable, Equatable, Sendable, CaseIterable {
    case fixture
    case database
    case registration
    case runtimeStart = "runtime_start"
    case decode
    case playback
    case runtimeStop = "runtime_stop"
    case diagnostics
    case output
}

public enum AppVerifyCheckName: String, Codable, Equatable, Sendable, CaseIterable {
    case fixtureSourceCreated = "fixture_source_created"
    case databaseOpened = "database_opened"
    case streamRegistered = "stream_registered"
    case runtimeStarted = "runtime_started"
    case decodeCompleted = "decode_completed"
    case avfoundationPlaybackScheduled = "avfoundation_playback_scheduled"
    case runtimeStopped = "runtime_stopped"
    case diagnosticsWritten = "diagnostics_written"

    public static let s01Required: [AppVerifyCheckName] = [
        .fixtureSourceCreated,
        .databaseOpened,
        .streamRegistered,
        .runtimeStarted,
        .decodeCompleted,
        .avfoundationPlaybackScheduled,
        .runtimeStopped,
        .diagnosticsWritten,
    ]
}

public struct AppVerifyRedactedArtifact: Codable, Equatable, Sendable {
    public var kind: String
    public var path: String
    public var note: String?

    public init(kind: String, path: String, note: String? = nil) {
        self.kind = AppVerifyEvidenceSanitizer.redact(kind)
        self.path = AppVerifyEvidenceSanitizer.artifactPath(path)
        self.note = note.map(AppVerifyEvidenceSanitizer.redact)
    }
}

public struct AppVerifyRuntimeFacts: Codable, Equatable, Sendable {
    public var phase: AppVerifyRuntimePhase
    public var processedChunks: Int
    public var decodedChunks: Int
    public var scheduledBuffers: Int
    public var diagnosticCount: Int
    public var recentDiagnosticEvents: [String]
    public var timelineSnapshotFields: [String: String]

    public init(
        phase: AppVerifyRuntimePhase,
        processedChunks: Int = 0,
        decodedChunks: Int = 0,
        scheduledBuffers: Int = 0,
        diagnosticCount: Int = 0,
        recentDiagnosticEvents: [String] = [],
        timelineSnapshotFields: [String: String] = [:]
    ) {
        self.phase = phase
        self.processedChunks = max(0, processedChunks)
        self.decodedChunks = max(0, decodedChunks)
        self.scheduledBuffers = max(0, scheduledBuffers)
        self.diagnosticCount = max(0, diagnosticCount)
        self.recentDiagnosticEvents = Array(recentDiagnosticEvents.prefix(32)).map(AppVerifyEvidenceSanitizer.redact)
        self.timelineSnapshotFields = timelineSnapshotFields.reduce(into: [:]) { partial, pair in
            partial[AppVerifyEvidenceSanitizer.redact(pair.key)] = AppVerifyEvidenceSanitizer.redact(pair.value)
        }
    }
}

public struct AppVerifyCheckRecord: Codable, Equatable, Sendable {
    public var name: AppVerifyCheckName
    public var status: AppVerifyEvidenceStatus
    public var required: Bool
    public var phase: AppVerifyRuntimePhase
    public var reason: String?
    public var facts: AppVerifyRuntimeFacts?
    public var artifacts: [AppVerifyRedactedArtifact]

    public init(
        name: AppVerifyCheckName,
        status: AppVerifyEvidenceStatus,
        required: Bool = true,
        phase: AppVerifyRuntimePhase,
        reason: String? = nil,
        facts: AppVerifyRuntimeFacts? = nil,
        artifacts: [AppVerifyRedactedArtifact] = []
    ) {
        self.name = name
        self.status = status
        self.required = required
        self.phase = phase
        self.reason = reason.map(AppVerifyEvidenceSanitizer.redact)
        self.facts = facts
        self.artifacts = Array(artifacts.prefix(16))
    }

    public static func pass(
        _ name: AppVerifyCheckName,
        phase: AppVerifyRuntimePhase,
        required: Bool = true,
        reason: String? = nil,
        facts: AppVerifyRuntimeFacts? = nil,
        artifacts: [AppVerifyRedactedArtifact] = []
    ) -> AppVerifyCheckRecord {
        AppVerifyCheckRecord(
            name: name,
            status: .pass,
            required: required,
            phase: phase,
            reason: reason,
            facts: facts,
            artifacts: artifacts
        )
    }

    public static func fail(
        _ name: AppVerifyCheckName,
        phase: AppVerifyRuntimePhase,
        required: Bool = true,
        reason: String,
        facts: AppVerifyRuntimeFacts? = nil,
        artifacts: [AppVerifyRedactedArtifact] = []
    ) -> AppVerifyCheckRecord {
        AppVerifyCheckRecord(
            name: name,
            status: .fail,
            required: required,
            phase: phase,
            reason: reason,
            facts: facts,
            artifacts: artifacts
        )
    }

    public static func warn(
        _ name: AppVerifyCheckName,
        phase: AppVerifyRuntimePhase,
        required: Bool = false,
        reason: String,
        facts: AppVerifyRuntimeFacts? = nil,
        artifacts: [AppVerifyRedactedArtifact] = []
    ) -> AppVerifyCheckRecord {
        AppVerifyCheckRecord(
            name: name,
            status: .warn,
            required: required,
            phase: phase,
            reason: reason,
            facts: facts,
            artifacts: artifacts
        )
    }
}

public struct AppVerifyEvidenceSummary: Codable, Equatable, Sendable {
    public var status: AppVerifyEvidenceStatus
    public var requiredCheckCount: Int
    public var failedRequiredCheckCount: Int
    public var warningCheckCount: Int
    public var message: String

    public init(
        status: AppVerifyEvidenceStatus,
        requiredCheckCount: Int,
        failedRequiredCheckCount: Int,
        warningCheckCount: Int,
        message: String
    ) {
        self.status = status
        self.requiredCheckCount = max(0, requiredCheckCount)
        self.failedRequiredCheckCount = max(0, failedRequiredCheckCount)
        self.warningCheckCount = max(0, warningCheckCount)
        self.message = AppVerifyEvidenceSanitizer.redact(message)
    }

    public static func aggregate(_ checks: [AppVerifyCheckRecord]) -> AppVerifyEvidenceSummary {
        guard !checks.isEmpty else {
            return AppVerifyEvidenceSummary(
                status: .fail,
                requiredCheckCount: 0,
                failedRequiredCheckCount: 1,
                warningCheckCount: 0,
                message: "App verification recorded no checks."
            )
        }

        let required = checks.filter(\.required)
        let failedRequired = required.filter { $0.status == .fail }
        let warnings = checks.filter { $0.status == .warn }
        if !failedRequired.isEmpty {
            return AppVerifyEvidenceSummary(
                status: .fail,
                requiredCheckCount: required.count,
                failedRequiredCheckCount: failedRequired.count,
                warningCheckCount: warnings.count,
                message: "App verification failed required checks."
            )
        }
        if !warnings.isEmpty {
            return AppVerifyEvidenceSummary(
                status: .warn,
                requiredCheckCount: required.count,
                failedRequiredCheckCount: 0,
                warningCheckCount: warnings.count,
                message: "App verification passed with warnings."
            )
        }
        return AppVerifyEvidenceSummary(
            status: .pass,
            requiredCheckCount: required.count,
            failedRequiredCheckCount: 0,
            warningCheckCount: 0,
            message: "App verification passed."
        )
    }
}

public struct AppVerifyEvidence: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generatedAt: String
    public var runID: String
    public var summary: AppVerifyEvidenceSummary
    public var checks: [AppVerifyCheckRecord]
    public var runtimeFacts: AppVerifyRuntimeFacts?
    public var artifacts: [AppVerifyRedactedArtifact]
    public var metadata: [String: String]

    public init(
        schemaVersion: Int = AppVerifyEvidence.currentSchemaVersion,
        generatedAt: String,
        runID: String,
        checks: [AppVerifyCheckRecord],
        runtimeFacts: AppVerifyRuntimeFacts? = nil,
        artifacts: [AppVerifyRedactedArtifact] = [],
        metadata: [String: String] = [:],
        summary: AppVerifyEvidenceSummary? = nil
    ) {
        let boundedChecks = Array(checks.prefix(64))
        self.schemaVersion = max(0, schemaVersion)
        self.generatedAt = AppVerifyEvidenceSanitizer.redact(generatedAt)
        self.runID = AppVerifyEvidenceSanitizer.redact(runID)
        self.checks = boundedChecks
        self.runtimeFacts = runtimeFacts
        self.artifacts = Array(artifacts.prefix(32))
        self.metadata = metadata.reduce(into: [:]) { partial, pair in
            partial[AppVerifyEvidenceSanitizer.redact(pair.key)] = AppVerifyEvidenceSanitizer.redact(pair.value)
        }
        self.summary = summary ?? AppVerifyEvidenceSummary.aggregate(boundedChecks)
    }

    public func jsonData() throws -> Data {
        try AppVerifyEvidence.stableJSONEncoder().encode(self)
    }

    public static func stableJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public enum AppVerifyCheckEvaluator {
    public static func decodeCompleted(processedChunks: Int, decodedChunks: Int, diagnosticEvents: [String] = []) -> AppVerifyCheckRecord {
        let facts = AppVerifyRuntimeFacts(
            phase: .decode,
            processedChunks: processedChunks,
            decodedChunks: decodedChunks,
            diagnosticCount: diagnosticEvents.count,
            recentDiagnosticEvents: diagnosticEvents
        )
        guard processedChunks > 0, decodedChunks > 0 else {
            return .fail(
                .decodeCompleted,
                phase: .decode,
                reason: "Decode proof requires processedChunks and decodedChunks greater than zero.",
                facts: facts
            )
        }
        return .pass(.decodeCompleted, phase: .decode, facts: facts)
    }

    public static func playbackScheduled(scheduledBuffers: Int, diagnosticEvents: [String] = []) -> AppVerifyCheckRecord {
        let facts = AppVerifyRuntimeFacts(
            phase: .playback,
            scheduledBuffers: scheduledBuffers,
            diagnosticCount: diagnosticEvents.count,
            recentDiagnosticEvents: diagnosticEvents
        )
        guard scheduledBuffers > 0 else {
            return .fail(
                .avfoundationPlaybackScheduled,
                phase: .playback,
                reason: "Playback proof requires at least one scheduled AVFoundation buffer.",
                facts: facts
            )
        }
        return .pass(.avfoundationPlaybackScheduled, phase: .playback, facts: facts)
    }
}

enum AppVerifyEvidenceSanitizer {
    static func redact(_ value: String) -> String {
        scrubSecretKeyNames(IngestRedaction.redact(value))
    }

    static func sourceDescription(_ value: String) -> String {
        scrubSecretKeyNames(IngestRedaction.sourceDescription(value))
    }

    static func artifactPath(_ value: String) -> String {
        let redacted = redact(value)
        if redacted.contains("[redacted-path]") {
            return "[redacted-path]"
        }
        return redacted
    }

    private static func scrubSecretKeyNames(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"(?i)\b(?:token|access_token|api[_-]?key|secret|password|passwd|pwd|key)=\[redacted\]"#,
            with: "[redacted-secret]",
            options: .regularExpression
        )
    }
}
