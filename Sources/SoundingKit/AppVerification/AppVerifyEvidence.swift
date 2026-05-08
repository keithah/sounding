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
    case playbackControl = "playback_control"
    case runtimeStop = "runtime_stop"
    case runtimeRestart = "runtime_restart"
    case diagnostics
    case liveConfig = "live_config"
    case liveRegistration = "live_registration"
    case liveRuntimeStart = "live_runtime_start"
    case liveDecode = "live_decode"
    case livePlayback = "live_playback"
    case liveStop = "live_stop"
    case liveDiagnostics = "live_diagnostics"
    case liveTranscript = "live_transcript"
    case liveMetadata = "live_metadata"
    case transcriptPersistence = "transcript_persistence"
    case transcriptTimelineProjection = "transcript_timeline_projection"
    case transcriptSearchProjection = "transcript_search_projection"
    case songMetadataProjection = "song_metadata_projection"
    case adMetadataProjection = "ad_metadata_projection"
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
    case playbackMuted = "playback_muted"
    case playbackUnmuted = "playback_unmuted"
    case playbackVolumeChanged = "playback_volume_changed"
    case runtimeStopObserved = "runtime_stop_observed"
    case runtimeRestartObserved = "runtime_restart_observed"
    case transcriptPersistence = "transcript_persistence"
    case transcriptTimelineProjection = "transcript_timeline_projection"
    case transcriptSearchProjection = "transcript_search_projection"
    case songMetadataProjection = "song_metadata_projection"
    case adMetadataProjection = "ad_metadata_projection"
    case liveConfigValidated = "live_config_validated"
    case liveStreamRegistered = "live_stream_registered"
    case liveRuntimeStarted = "live_runtime_started"
    case liveDecodeOpened = "live_decode_opened"
    case livePlaybackScheduled = "live_playback_scheduled"
    case liveRuntimeStopped = "live_runtime_stopped"
    case liveDiagnosticsWritten = "live_diagnostics_written"
    case liveTranscriptObserved = "live_transcript_observed"
    case liveMetadataObserved = "live_metadata_observed"

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

    public static let s02ControlRequired: [AppVerifyCheckName] = [
        .playbackMuted,
        .playbackUnmuted,
        .playbackVolumeChanged,
        .runtimeStopObserved,
        .runtimeRestartObserved,
    ]

    public static let s03ProjectionRequired: [AppVerifyCheckName] = [
        .transcriptPersistence,
        .transcriptTimelineProjection,
        .transcriptSearchProjection,
        .songMetadataProjection,
        .adMetadataProjection,
    ]

    public static let fixtureRequired: [AppVerifyCheckName] = s01Required + s02ControlRequired + s03ProjectionRequired
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

public struct AppVerifyParsedDiagnosticEntry: Codable, Equatable, Sendable {
    public var event: String
    public var phase: String?
    public var streamID: Int64?
    public var message: String?
    public var fields: [String: String]

    public init(
        event: String,
        phase: String? = nil,
        streamID: Int64? = nil,
        message: String? = nil,
        fields: [String: String] = [:]
    ) {
        self.event = AppVerifyEvidenceSanitizer.redact(event)
        self.phase = phase.map(AppVerifyEvidenceSanitizer.redact)
        self.streamID = streamID
        self.message = message.map(AppVerifyEvidenceSanitizer.redact)
        self.fields = fields.prefix(16).reduce(into: [:]) { partial, pair in
            partial[AppVerifyEvidenceSanitizer.fieldKey(pair.key)] =
                AppVerifyEvidenceSanitizer.fieldValue(pair.value, key: pair.key)
        }
    }
}

public struct AppVerifyControlObservationFacts: Codable, Equatable, Sendable {
    public var requestedAction: String
    public var observedRuntimePhase: AppVerifyRuntimePhase
    public var timelineState: String?
    public var volume: Double?
    public var muted: Bool?
    public var effectiveVolume: Double?
    public var diagnosticEventNames: [String]
    public var diagnostics: [AppVerifyParsedDiagnosticEntry]
    public var beforeMarker: String?
    public var afterMarker: String?

    public init(
        requestedAction: String,
        observedRuntimePhase: AppVerifyRuntimePhase,
        timelineState: String? = nil,
        volume: Double? = nil,
        muted: Bool? = nil,
        effectiveVolume: Double? = nil,
        diagnosticEventNames: [String] = [],
        diagnostics: [AppVerifyParsedDiagnosticEntry] = [],
        beforeMarker: String? = nil,
        afterMarker: String? = nil
    ) {
        self.requestedAction = AppVerifyEvidenceSanitizer.redact(requestedAction)
        self.observedRuntimePhase = observedRuntimePhase
        self.timelineState = timelineState.map(AppVerifyEvidenceSanitizer.redact)
        self.volume = volume.map(Self.finiteUnitInterval)
        self.muted = muted
        self.effectiveVolume = effectiveVolume.map(Self.finiteUnitInterval)
        self.diagnosticEventNames = Array(diagnosticEventNames.prefix(16)).map(AppVerifyEvidenceSanitizer.redact)
        self.diagnostics = Array(diagnostics.prefix(16))
        self.beforeMarker = beforeMarker.map(AppVerifyEvidenceSanitizer.redact)
        self.afterMarker = afterMarker.map(AppVerifyEvidenceSanitizer.redact)
    }

    private static func finiteUnitInterval(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}


public struct AppVerifyProjectionFacts: Codable, Equatable, Sendable {
    public var surface: String
    public var rowCount: Int
    public var projectionCount: Int
    public var metadataCount: Int
    public var sampleFields: [String: String]
    public var recentDiagnosticEvents: [String]

    public init(
        surface: String,
        rowCount: Int = 0,
        projectionCount: Int = 0,
        metadataCount: Int = 0,
        sampleFields: [String: String] = [:],
        recentDiagnosticEvents: [String] = []
    ) {
        self.surface = AppVerifyEvidenceSanitizer.redact(surface)
        self.rowCount = max(0, rowCount)
        self.projectionCount = max(0, projectionCount)
        self.metadataCount = max(0, metadataCount)
        self.sampleFields = sampleFields.prefix(12).reduce(into: [:]) { partial, pair in
            partial[AppVerifyEvidenceSanitizer.redact(pair.key)] = AppVerifyEvidenceSanitizer.redact(pair.value)
        }
        self.recentDiagnosticEvents = Array(recentDiagnosticEvents.prefix(16)).map(AppVerifyEvidenceSanitizer.redact)
    }
}

public struct AppVerifyLiveStreamFacts: Codable, Equatable, Sendable {
    public var streamID: String
    public var streamType: StreamType
    public var resolvedStreamType: StreamType
    public var redactedSource: String
    public var timeoutSeconds: Double
    public var maxChunks: Int
    public var required: Bool
    public var transcriptExpectation: AppVerifyLiveExpectation
    public var metadataExpectation: AppVerifyLiveExpectation
    public var registeredStreamID: Int64?
    public var processedChunks: Int
    public var decodedChunks: Int
    public var scheduledBuffers: Int
    public var transcriptCount: Int
    public var metadataCount: Int
    public var diagnosticCount: Int
    public var recentDiagnosticEvents: [String]
    public var fields: [String: String]

    public init(
        streamID: String,
        streamType: StreamType,
        resolvedStreamType: StreamType,
        source: String,
        timeoutSeconds: Double,
        maxChunks: Int,
        required: Bool,
        transcriptExpectation: AppVerifyLiveExpectation = .warn,
        metadataExpectation: AppVerifyLiveExpectation = .warn,
        registeredStreamID: Int64? = nil,
        processedChunks: Int = 0,
        decodedChunks: Int = 0,
        scheduledBuffers: Int = 0,
        transcriptCount: Int = 0,
        metadataCount: Int = 0,
        diagnosticCount: Int = 0,
        recentDiagnosticEvents: [String] = [],
        fields: [String: String] = [:]
    ) {
        self.streamID = AppVerifyEvidenceSanitizer.redact(streamID)
        self.streamType = streamType
        self.resolvedStreamType = resolvedStreamType
        self.redactedSource = AppVerifyEvidenceSanitizer.sourceDescription(source)
        self.timeoutSeconds = timeoutSeconds.isFinite ? max(0, timeoutSeconds) : 0
        self.maxChunks = max(0, maxChunks)
        self.required = required
        self.transcriptExpectation = transcriptExpectation
        self.metadataExpectation = metadataExpectation
        self.registeredStreamID = registeredStreamID
        self.processedChunks = max(0, processedChunks)
        self.decodedChunks = max(0, decodedChunks)
        self.scheduledBuffers = max(0, scheduledBuffers)
        self.transcriptCount = max(0, transcriptCount)
        self.metadataCount = max(0, metadataCount)
        self.diagnosticCount = max(0, diagnosticCount)
        self.recentDiagnosticEvents = Array(recentDiagnosticEvents.prefix(32)).map(AppVerifyEvidenceSanitizer.redact)
        self.fields = fields.prefix(16).reduce(into: [:]) { partial, pair in
            partial[Self.redactedFieldKey(pair.key)] = Self.redactedFieldValue(pair.value, key: pair.key)
        }
    }

    private static func redactedFieldKey(_ key: String) -> String {
        let redacted = AppVerifyEvidenceSanitizer.redact(key)
        if isPathLikeKey(redacted) {
            return "[redacted-path-key]"
        }
        return redacted
    }

    private static func redactedFieldValue(_ value: String, key: String) -> String {
        if isPathLikeKey(key) {
            return AppVerifyEvidenceSanitizer.artifactPath(value)
        }
        return AppVerifyEvidenceSanitizer.redact(value)
    }

    private static func isPathLikeKey(_ key: String) -> Bool {
        key.range(of: "path", options: [.caseInsensitive]) != nil
            || key.range(of: "directory", options: [.caseInsensitive]) != nil
    }
}

public struct AppVerifyCheckRecord: Codable, Equatable, Sendable {
    public var name: AppVerifyCheckName
    public var status: AppVerifyEvidenceStatus
    public var required: Bool
    public var phase: AppVerifyRuntimePhase
    public var reason: String?
    public var facts: AppVerifyRuntimeFacts?
    public var controlFacts: AppVerifyControlObservationFacts?
    public var projectionFacts: AppVerifyProjectionFacts?
    public var liveFacts: AppVerifyLiveStreamFacts?
    public var artifacts: [AppVerifyRedactedArtifact]

    public init(
        name: AppVerifyCheckName,
        status: AppVerifyEvidenceStatus,
        required: Bool = true,
        phase: AppVerifyRuntimePhase,
        reason: String? = nil,
        facts: AppVerifyRuntimeFacts? = nil,
        controlFacts: AppVerifyControlObservationFacts? = nil,
        projectionFacts: AppVerifyProjectionFacts? = nil,
        liveFacts: AppVerifyLiveStreamFacts? = nil,
        artifacts: [AppVerifyRedactedArtifact] = []
    ) {
        self.name = name
        self.status = status
        self.required = required
        self.phase = phase
        self.reason = reason.map(AppVerifyEvidenceSanitizer.redact)
        self.facts = facts
        self.controlFacts = controlFacts
        self.projectionFacts = projectionFacts
        self.liveFacts = liveFacts
        self.artifacts = Array(artifacts.prefix(16))
    }

    public static func pass(
        _ name: AppVerifyCheckName,
        phase: AppVerifyRuntimePhase,
        required: Bool = true,
        reason: String? = nil,
        facts: AppVerifyRuntimeFacts? = nil,
        controlFacts: AppVerifyControlObservationFacts? = nil,
        projectionFacts: AppVerifyProjectionFacts? = nil,
        liveFacts: AppVerifyLiveStreamFacts? = nil,
        artifacts: [AppVerifyRedactedArtifact] = []
    ) -> AppVerifyCheckRecord {
        AppVerifyCheckRecord(
            name: name,
            status: .pass,
            required: required,
            phase: phase,
            reason: reason,
            facts: facts,
            controlFacts: controlFacts,
            projectionFacts: projectionFacts,
            liveFacts: liveFacts,
            artifacts: artifacts
        )
    }

    public static func fail(
        _ name: AppVerifyCheckName,
        phase: AppVerifyRuntimePhase,
        required: Bool = true,
        reason: String,
        facts: AppVerifyRuntimeFacts? = nil,
        controlFacts: AppVerifyControlObservationFacts? = nil,
        projectionFacts: AppVerifyProjectionFacts? = nil,
        liveFacts: AppVerifyLiveStreamFacts? = nil,
        artifacts: [AppVerifyRedactedArtifact] = []
    ) -> AppVerifyCheckRecord {
        AppVerifyCheckRecord(
            name: name,
            status: .fail,
            required: required,
            phase: phase,
            reason: reason,
            facts: facts,
            controlFacts: controlFacts,
            projectionFacts: projectionFacts,
            liveFacts: liveFacts,
            artifacts: artifacts
        )
    }

    public static func warn(
        _ name: AppVerifyCheckName,
        phase: AppVerifyRuntimePhase,
        required: Bool = false,
        reason: String,
        facts: AppVerifyRuntimeFacts? = nil,
        controlFacts: AppVerifyControlObservationFacts? = nil,
        projectionFacts: AppVerifyProjectionFacts? = nil,
        liveFacts: AppVerifyLiveStreamFacts? = nil,
        artifacts: [AppVerifyRedactedArtifact] = []
    ) -> AppVerifyCheckRecord {
        AppVerifyCheckRecord(
            name: name,
            status: .warn,
            required: required,
            phase: phase,
            reason: reason,
            facts: facts,
            controlFacts: controlFacts,
            projectionFacts: projectionFacts,
            liveFacts: liveFacts,
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
            partial[AppVerifyEvidenceSanitizer.fieldKey(pair.key)] =
                AppVerifyEvidenceSanitizer.fieldValue(pair.value, key: pair.key)
        }
        self.summary = summary ?? AppVerifyEvidenceSummary.aggregate(boundedChecks)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, runID, summary, checks, runtimeFacts, artifacts, metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedChecks = try container.decode([AppVerifyCheckRecord].self, forKey: .checks)
        let boundedChecks = Array(decodedChecks.prefix(64))
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        generatedAt = AppVerifyEvidenceSanitizer.redact(
            try container.decodeIfPresent(String.self, forKey: .generatedAt) ?? "unknown")
        runID = AppVerifyEvidenceSanitizer.redact(
            try container.decodeIfPresent(String.self, forKey: .runID) ?? "unknown")
        checks = boundedChecks
        runtimeFacts = try container.decodeIfPresent(AppVerifyRuntimeFacts.self, forKey: .runtimeFacts)
        artifacts = Array(
            try container.decodeIfPresent([AppVerifyRedactedArtifact].self, forKey: .artifacts) ?? []
        ).prefix(32).map { $0 }
        let decodedMetadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        metadata = decodedMetadata.reduce(into: [:]) { partial, pair in
            partial[AppVerifyEvidenceSanitizer.fieldKey(pair.key)] =
                AppVerifyEvidenceSanitizer.fieldValue(pair.value, key: pair.key)
        }
        summary = try container.decodeIfPresent(AppVerifyEvidenceSummary.self, forKey: .summary)
            ?? AppVerifyEvidenceSummary.aggregate(boundedChecks)
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

    public static func controlObserved(
        _ name: AppVerifyCheckName,
        requestedAction: String,
        observedRuntimePhase: AppVerifyRuntimePhase,
        timelineState: String? = nil,
        volume: Double? = nil,
        muted: Bool? = nil,
        effectiveVolume: Double? = nil,
        diagnostics: [AppVerifyParsedDiagnosticEntry] = [],
        requiredDiagnosticEvents: [String],
        beforeMarker: String? = nil,
        afterMarker: String? = nil,
        artifacts: [AppVerifyRedactedArtifact] = []
    ) -> AppVerifyCheckRecord {
        let diagnosticNames = diagnostics.map(\.event)
        let controlFacts = AppVerifyControlObservationFacts(
            requestedAction: requestedAction,
            observedRuntimePhase: observedRuntimePhase,
            timelineState: timelineState,
            volume: volume,
            muted: muted,
            effectiveVolume: effectiveVolume,
            diagnosticEventNames: diagnosticNames,
            diagnostics: diagnostics,
            beforeMarker: beforeMarker,
            afterMarker: afterMarker
        )
        let missing = requiredDiagnosticEvents.filter { !diagnosticNames.contains($0) }
        let missingState = timelineState == nil && volume == nil && muted == nil && effectiveVolume == nil
        let phase = controlPhase(for: name)
        guard missing.isEmpty, !missingState else {
            var reasons: [String] = []
            if !missing.isEmpty {
                reasons.append("missing diagnostic events: \(missing.joined(separator: ","))")
            }
            if missingState {
                reasons.append("missing observed control state")
            }
            return .fail(
                name,
                phase: phase,
                reason: "Control observation for \(requestedAction) failed: \(reasons.joined(separator: "; ")).",
                controlFacts: controlFacts,
                artifacts: artifacts
            )
        }
        return .pass(name, phase: phase, controlFacts: controlFacts, artifacts: artifacts)
    }



    public static func projectionPopulated(
        _ name: AppVerifyCheckName,
        surface: String,
        rowCount: Int = 0,
        projectionCount: Int = 0,
        metadataCount: Int = 0,
        sampleFields: [String: String] = [:],
        diagnosticEvents: [String] = []
    ) -> AppVerifyCheckRecord {
        let facts = AppVerifyProjectionFacts(
            surface: surface,
            rowCount: rowCount,
            projectionCount: projectionCount,
            metadataCount: metadataCount,
            sampleFields: sampleFields,
            recentDiagnosticEvents: diagnosticEvents
        )
        let phase = projectionPhase(for: name)
        let hasEvidence: Bool
        switch name {
        case .transcriptPersistence:
            hasEvidence = rowCount > 0
        case .transcriptTimelineProjection, .transcriptSearchProjection:
            hasEvidence = projectionCount > 0
        case .songMetadataProjection, .adMetadataProjection:
            hasEvidence = metadataCount > 0
        default:
            hasEvidence = rowCount > 0 || projectionCount > 0 || metadataCount > 0
        }
        guard hasEvidence else {
            return .fail(
                name,
                phase: phase,
                reason: "Projection proof for \(surface) requires a non-zero sanitized count.",
                projectionFacts: facts
            )
        }
        return .pass(name, phase: phase, projectionFacts: facts)
    }

    public static func liveTranscriptExpectation(
        observedCount: Int,
        expectation: AppVerifyLiveExpectation,
        required: Bool,
        streamID: String,
        source: String,
        facts: AppVerifyLiveStreamFacts? = nil
    ) -> AppVerifyCheckRecord {
        liveExpectation(
            .liveTranscriptObserved,
            phase: .liveTranscript,
            observedCount: observedCount,
            expectation: expectation,
            required: required,
            streamID: streamID,
            source: source,
            facts: facts
        )
    }

    public static func liveMetadataExpectation(
        observedCount: Int,
        expectation: AppVerifyLiveExpectation,
        required: Bool,
        streamID: String,
        source: String,
        facts: AppVerifyLiveStreamFacts? = nil
    ) -> AppVerifyCheckRecord {
        liveExpectation(
            .liveMetadataObserved,
            phase: .liveMetadata,
            observedCount: observedCount,
            expectation: expectation,
            required: required,
            streamID: streamID,
            source: source,
            facts: facts
        )
    }

    private static func liveExpectation(
        _ name: AppVerifyCheckName,
        phase: AppVerifyRuntimePhase,
        observedCount: Int,
        expectation: AppVerifyLiveExpectation,
        required: Bool,
        streamID: String,
        source: String,
        facts: AppVerifyLiveStreamFacts?
    ) -> AppVerifyCheckRecord {
        let redactedID = AppVerifyEvidenceSanitizer.redact(streamID)
        let redactedSource = AppVerifyEvidenceSanitizer.sourceDescription(source)
        let observed = max(0, observedCount)
        guard expectation != .disabled else {
            return .pass(
                name,
                phase: phase,
                required: false,
                reason: "Live \(phase.rawValue) expectation disabled for stream \(redactedID).",
                liveFacts: facts
            )
        }
        guard observed > 0 else {
            let reason = "Live \(phase.rawValue) expectation for stream \(redactedID) observed zero records from \(redactedSource)."
            if expectation == .strict {
                return .fail(name, phase: phase, required: required, reason: reason, liveFacts: facts)
            }
            return .warn(name, phase: phase, required: false, reason: reason, liveFacts: facts)
        }
        return .pass(
            name,
            phase: phase,
            required: required && expectation == .strict,
            reason: "Live \(phase.rawValue) observed \(observed) record(s) for stream \(redactedID).",
            liveFacts: facts
        )
    }

    private static func controlPhase(for name: AppVerifyCheckName) -> AppVerifyRuntimePhase {
        switch name {
        case .runtimeStopObserved:
            return .runtimeStop
        case .runtimeRestartObserved:
            return .runtimeRestart
        default:
            return .playbackControl
        }
    }

    private static func projectionPhase(for name: AppVerifyCheckName) -> AppVerifyRuntimePhase {
        switch name {
        case .transcriptPersistence:
            return .transcriptPersistence
        case .transcriptTimelineProjection:
            return .transcriptTimelineProjection
        case .transcriptSearchProjection:
            return .transcriptSearchProjection
        case .songMetadataProjection:
            return .songMetadataProjection
        case .adMetadataProjection:
            return .adMetadataProjection
        default:
            return .output
        }
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

    static func fieldKey(_ key: String) -> String {
        if isSecretLikeKey(key) {
            return "[redacted-secret-key]"
        }
        return redact(key)
    }

    static func fieldValue(_ value: String, key: String) -> String {
        if isSecretLikeKey(key) {
            return "[redacted-secret]"
        }
        if isPathLikeKey(key) {
            return artifactPath(value)
        }
        return redact(value)
    }

    private static func isSecretLikeKey(_ key: String) -> Bool {
        key.range(
            of: #"(?i)\b(token|access[_-]?token|api[_-]?key|secret|password|passwd|pwd|credential|authorization)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func isPathLikeKey(_ key: String) -> Bool {
        key.range(of: "path", options: [.caseInsensitive]) != nil
            || key.range(of: "directory", options: [.caseInsensitive]) != nil
    }

    private static func scrubSecretKeyNames(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"(?i)\b(?:token|access_token|api[_-]?key|secret|password|passwd|pwd|key)=\[redacted\]"#,
            with: "[redacted-secret]",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"\[redacted-\[redacted-secret\]\]"#,
            with: "[redacted-secret]",
            options: .regularExpression
        )
    }
}
