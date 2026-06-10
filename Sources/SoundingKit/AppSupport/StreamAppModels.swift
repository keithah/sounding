import Foundation

public enum StreamAppTransport: String, CaseIterable, Equatable, Sendable, Identifiable {
    case auto
    case hls
    case icecast

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto:
            return "Auto"
        case .hls:
            return "HLS"
        case .icecast:
            return "Icecast / ICY"
        }
    }

    public var registryStreamType: String {
        switch self {
        case .auto:
            return "auto"
        case .hls:
            return "hls"
        case .icecast:
            return "icy"
        }
    }

    public static func fromRegistryStreamType(_ streamType: String) -> StreamAppTransport? {
        switch streamType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auto":
            return .auto
        case "hls":
            return .hls
        case "icecast", "icy":
            return .icecast
        default:
            return nil
        }
    }
}

public extension StreamTranscriptionPolicy {
    var displayName: String {
        switch self {
        case .always:
            return "Show all transcripts"
        case .nonSongs:
            return "Show non-song transcripts"
        case .hidden:
            return "Hide transcripts"
        }
    }

    var statusDetail: String {
        switch self {
        case .always:
            return "Transcripts are shown for speech and songs."
        case .nonSongs:
            return "Song lyric transcripts are hidden when music metadata identifies the song."
        case .hidden:
            return "Transcript rows are hidden for this stream."
        }
    }
}

public enum StreamAppValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyName
    case emptySource
    case invalidURL
    case unsupportedScheme(String)
    case unsupportedTransport(String)
    case duplicateName
    case registry(String)

    public var description: String {
        switch self {
        case .emptyName:
            return "Enter a stream name."
        case .emptySource:
            return "Enter a stream URL."
        case .invalidURL:
            return "Enter a valid HTTP or HTTPS stream URL."
        case .unsupportedScheme(let scheme):
            return
                "Unsupported URL scheme \(scheme). Use HTTP or HTTPS for HLS and Icecast/ICY streams."
        case .unsupportedTransport(let transport):
            return
                "Unsupported stream type \(transport). Sounding.app currently supports HLS and Icecast/ICY streams."
        case .duplicateName:
            return "A stream with this name already exists."
        case .registry:
            return "The stream could not be saved."
        }
    }

    public var recoverySuggestion: String {
        switch self {
        case .emptyName:
            return "Give the stream a short unique label."
        case .emptySource:
            return "Paste an authorized HLS or Icecast/ICY URL."
        case .invalidURL, .unsupportedScheme:
            return "Use an http:// or https:// URL for this first app workflow."
        case .unsupportedTransport:
            return "MPEG-TS, UDP, file, and advanced transports remain CLI/library-first for now."
        case .duplicateName:
            return "Choose another name or remove the existing stream first."
        case .registry(let reason):
            return IngestRedaction.redact(reason)
        }
    }
}

public struct StreamAppAddDraft: Equatable, Sendable {
    public var name: String
    public var source: String
    public var transport: StreamAppTransport

    public init(name: String = "", source: String = "", transport: StreamAppTransport = .auto) {
        self.name = name
        self.source = source
        self.transport = transport
    }
}

public struct ValidatedStreamAppAddRequest: Equatable, Sendable {
    public var name: String
    public var source: String
    public var transport: StreamAppTransport
    public var resolvedTransport: StreamAppTransport
    public var redactedSourceDescription: String

    public var registryStreamType: String { resolvedTransport.registryStreamType }
}

public enum StreamAppStatus: Equatable, Sendable {
    case ready
    case connecting
    case running
    case paused
    case suspended
    case recovering
    case reconnecting(nextRetrySeconds: Int?)
    case stopped
    case removed
    case error(message: String)

    public static func fromRegistryStatus(_ status: StreamStatus) -> StreamAppStatus {
        switch status {
        case .active:
            return .ready
        case .paused:
            return .paused
        case .removed:
            return .removed
        }
    }

    public var title: String {
        switch self {
        case .ready:
            return "Ready"
        case .connecting:
            return "Connecting"
        case .running:
            return "Running"
        case .paused:
            return "Paused"
        case .suspended:
            return "Suspended"
        case .recovering:
            return "Recovering"
        case .reconnecting:
            return "Reconnecting"
        case .stopped:
            return "Stopped"
        case .removed:
            return "Removed"
        case .error:
            return "Error"
        }
    }

    public var detail: String {
        switch self {
        case .ready:
            return "Saved and ready to start."
        case .connecting:
            return "Opening the stream source."
        case .running:
            return "Live ingest and playback are active."
        case .paused:
            return "The stream is paused."
        case .suspended:
            return "The stream is suspended for system sleep."
        case .recovering:
            return "The stream is recovering after system wake."
        case .reconnecting(let seconds):
            if let seconds {
                return "Retrying in \(seconds) seconds."
            }
            return "Retrying with backoff."
        case .stopped:
            return "The stream is stopped."
        case .removed:
            return "This stream was removed."
        case .error(let message):
            return IngestRedaction.redact(message)
        }
    }

    public var isFailure: Bool {
        if case .error = self { return true }
        return false
    }

    public var canStart: Bool {
        switch self {
        case .ready, .stopped:
            return true
        case .connecting, .running, .paused, .suspended, .recovering, .reconnecting, .removed, .error:
            return false
        }
    }
}

public struct StreamAppListItem: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var name: String
    public var transportLabel: String
    public var sourceDescription: String
    public var status: StreamAppStatus
    public var diarizationEnabled: Bool
    public var audioArchiveEnabled: Bool
    public var transcriptionPolicy: StreamTranscriptionPolicy
    public var runtimeStatusDetail: String?

    public init(record: StreamRecord) {
        id = record.id
        name = record.name
        transportLabel =
            StreamAppTransport.fromRegistryStreamType(record.streamType)?.displayName
            ?? record.streamType.uppercased()
        sourceDescription = record.sourceDescription
        status = .fromRegistryStatus(record.status)
        diarizationEnabled = record.diarizationEnabled
        audioArchiveEnabled = record.audioArchiveEnabled
        transcriptionPolicy = record.transcriptionPolicy
        runtimeStatusDetail = nil
    }
}

public enum StreamAppViewModelTimelineError: Error, Equatable, Sendable, CustomStringConvertible {
    case noSelectedStream
    case selectedStreamUnavailable
    case unknownSpeakerLabel(String)
    case searchResultNotFound(String)
    case searchResultWrongStream
    case searchResultNotSeekable
    case invalidSearchSeekTarget

    public var description: String {
        switch self {
        case .noSelectedStream:
            return "Select a stream before refreshing its timeline."
        case .selectedStreamUnavailable:
            return "The selected stream is no longer available."
        case .unknownSpeakerLabel:
            return "Choose an existing speaker before editing its display label."
        case .searchResultNotFound:
            return "Search result is no longer available."
        case .searchResultWrongStream:
            return "Search result belongs to a different stream."
        case .searchResultNotSeekable:
            return "Search result is outside the current playback buffer."
        case .invalidSearchSeekTarget:
            return "Search result has an invalid playback target."
        }
    }
}

public struct StreamAppSearchDraft: Equatable, Sendable {
    public var phrase: String
    public var scopeToSelectedStream: Bool
    public var speakerLabels: [String]
    public var runStartedAtFrom: String?
    public var runStartedAtThrough: String?
    public var limit: Int
    public var contextSegments: Int

    public init(
        phrase: String = "",
        scopeToSelectedStream: Bool = true,
        speakerLabels: [String] = [],
        runStartedAtFrom: String? = nil,
        runStartedAtThrough: String? = nil,
        limit: Int = 20,
        contextSegments: Int = 1
    ) {
        self.phrase = phrase
        self.scopeToSelectedStream = scopeToSelectedStream
        self.speakerLabels = speakerLabels
        self.runStartedAtFrom = runStartedAtFrom
        self.runStartedAtThrough = runStartedAtThrough
        self.limit = limit
        self.contextSegments = contextSegments
    }

    public var normalizedSpeakerLabels: [String]? {
        let labels = speakerLabels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return labels.isEmpty ? nil : labels
    }
}

public struct StreamAppSearchSelectionAction: Equatable, Sendable {
    public var shouldSeek: Bool
    public var seekSeconds: Double?
    public var message: String?

    public init(shouldSeek: Bool, seekSeconds: Double? = nil, message: String? = nil) {
        self.shouldSeek = shouldSeek
        self.seekSeconds = seekSeconds
        self.message = message.map(IngestRedaction.redact)
    }
}

public struct StreamAppVisibleIssue: Equatable, Sendable, Identifiable {
    public var id: String
    public var severity: SoundingAppIssueSeverity
    public var message: String
    public var actionLabel: String

    public init(
        id: String,
        severity: SoundingAppIssueSeverity,
        message: String,
        actionLabel: String
    ) {
        self.id = id
        self.severity = severity
        self.message = IngestRedaction.redact(message)
        self.actionLabel = IngestRedaction.redact(actionLabel)
    }
}

public struct StreamAppSelectedStream: Equatable, Sendable {
    public var item: StreamAppListItem
    public var playerStateTitle: String
    public var playerStateDetail: String
    public var runtimeStatusDetail: String
    public var runtimeRetryDetail: String?
    public var runtimeUpdatedAtDetail: String?
    public var runtimeRecentFailureDetail: String?
    public var runtimeIssue: StreamAppVisibleIssue?
    public var playerIssue: StreamAppVisibleIssue?
    public var bufferIssue: StreamAppVisibleIssue?
    public var bufferedRangeTitle: String
    public var controlsEnabled: Bool
    public var canStartRuntime: Bool
    public var canPauseRuntime: Bool
    public var canResumeRuntime: Bool
    public var canStopRuntime: Bool
    public var canSeekToLive: Bool
    public var canScrubBufferedRange: Bool
    public var scrubPositionFraction: Double
    public var recentTranscriptParagraphs: [StreamAppTranscriptParagraph]
    public var speakerDisplays: [StreamAppSpeakerDisplay]
    public var currentMetadata: StreamAppMetadataItem?
    public var recentMetadata: [StreamAppMetadataItem]
    public var timelineItems: [StreamAppTimelineItem]
    public var timelineRail: StreamAppTimelineRailSnapshot
    public var timelineDiagnostics: StreamAppTimelineDiagnostics?
    public var timelineFreshnessMessage: String
    public var timelineLagMessage: String?
    public var bufferedSeekUnavailableMessage: String?
    public var hasSeekableTimelineItems: Bool
    public var timelineRefreshErrorMessage: String?
    public var speakerEditErrorMessage: String?
    public var searchDraft: StreamAppSearchDraft
    public var searchSnapshot: StreamAppSearchSnapshot?
    public var searchResults: [StreamAppSearchResult]
    public var searchDiagnostics: StreamAppSearchDiagnostics?
    public var selectedSearchResultID: String?
    public var selectedSearchSegmentID: Int64?
    public var transcriptScrollTargetSegmentID: Int64?
    public var transcriptScrollTargetID: String?
    public var searchErrorMessage: String?
    public var searchJumpMessage: String?

    public init(
        item: StreamAppListItem,
        runtimeStatus: AppStreamRuntimeStatusSnapshot? = nil,
        timeline: AppPlayerTimelineSnapshot? = nil,
        runtimeEventMessage: String? = nil,
        snapshot: StreamAppTimelineSnapshot? = nil,
        timelineRefreshErrorMessage: String? = nil,
        speakerEditErrorMessage: String? = nil,
        searchDraft: StreamAppSearchDraft = StreamAppSearchDraft(),
        searchSnapshot: StreamAppSearchSnapshot? = nil,
        selectedSearchResultID: String? = nil,
        selectedSearchSegmentID: Int64? = nil,
        transcriptScrollTargetSegmentID: Int64? = nil,
        searchErrorMessage: String? = nil,
        searchJumpMessage: String? = nil
    ) {
        var projectedItem = item
        if let runtimeStatus {
            if runtimeStatus.phase == .stopped && timeline?.hasActivePlayback == true {
                projectedItem.status = .running
                projectedItem.runtimeStatusDetail = timeline?.lastMessage ?? "Playback is active."
            } else {
                projectedItem.status = Self.status(from: runtimeStatus)
                projectedItem.runtimeStatusDetail = Self.runtimeStatusDetail(for: runtimeStatus)
            }
        }
        self.item = projectedItem
        runtimeStatusDetail = projectedItem.runtimeStatusDetail ?? projectedItem.status.detail
        runtimeRetryDetail = runtimeStatus.flatMap(Self.runtimeRetryDetail(for:))
        runtimeUpdatedAtDetail = runtimeStatus.map { "Updated \($0.updatedAt)" }
        runtimeRecentFailureDetail = runtimeStatus?.recentFailure.map {
            "Recent failure (\($0.occurredAt)): \($0.message)"
        }
        switch projectedItem.status {
        case .running:
            playerStateTitle = "Runtime running"
            playerStateDetail = "The in-process SoundingKit runtime is active for this stream."
            controlsEnabled = true
            canStartRuntime = false
            canPauseRuntime = true
            canResumeRuntime = false
            canStopRuntime = true
        case .paused:
            playerStateTitle = "Runtime paused"
            playerStateDetail = "Resume to continue the app-hosted runtime."
            controlsEnabled = true
            canStartRuntime = false
            canPauseRuntime = false
            canResumeRuntime = true
            canStopRuntime = true
        case .connecting, .reconnecting:
            playerStateTitle = "Runtime connecting"
            playerStateDetail = runtimeStatusDetail
            controlsEnabled = true
            canStartRuntime = false
            canPauseRuntime = false
            canResumeRuntime = false
            canStopRuntime = true
        case .suspended:
            playerStateTitle = "Runtime suspended"
            playerStateDetail = runtimeStatusDetail
            controlsEnabled = true
            canStartRuntime = false
            canPauseRuntime = false
            canResumeRuntime = false
            canStopRuntime = true
        case .recovering:
            playerStateTitle = "Runtime recovering"
            playerStateDetail = runtimeStatusDetail
            controlsEnabled = true
            canStartRuntime = false
            canPauseRuntime = false
            canResumeRuntime = false
            canStopRuntime = true
        case .ready, .stopped:
            playerStateTitle = "Runtime ready"
            playerStateDetail = "Start this stream through the in-process SoundingKit runtime."
            controlsEnabled = true
            canStartRuntime = true
            canPauseRuntime = false
            canResumeRuntime = false
            canStopRuntime = false
        case .error:
            playerStateTitle = "Runtime error"
            playerStateDetail = item.status.detail
            controlsEnabled = true
            canStartRuntime = true
            canPauseRuntime = false
            canResumeRuntime = false
            canStopRuntime = true
        case .removed:
            playerStateTitle = "Runtime unavailable"
            playerStateDetail = "Removed streams cannot be started."
            controlsEnabled = false
            canStartRuntime = false
            canPauseRuntime = false
            canResumeRuntime = false
            canStopRuntime = false
        }

        runtimeIssue = Self.runtimeIssue(
            for: projectedItem.status,
            eventMessage: runtimeStatus?.recentFailure?.message
                ?? runtimeEventMessage
                ?? projectedItem.runtimeStatusDetail
        )
        playerIssue = nil
        bufferIssue = nil

        if let timeline {
            playerStateTitle = timeline.state.title
            playerStateDetail = timeline.unavailableRangeMessage ?? timeline.lastMessage
            switch timeline.state {
            case .buffering, .playing:
                controlsEnabled = true
                canStartRuntime = false
                canPauseRuntime = true
                canResumeRuntime = false
                canStopRuntime = true
            case .paused:
                controlsEnabled = true
                canStartRuntime = false
                canPauseRuntime = false
                canResumeRuntime = true
                canStopRuntime = true
            case .failed:
                controlsEnabled = true
                canStartRuntime = true
                canPauseRuntime = false
                canResumeRuntime = false
                canStopRuntime = true
            case .idle, .stopped:
                break
            }
            if let range = timeline.rollingBuffer?.bufferedRange {
                bufferedRangeTitle = String(
                    format: "Buffered %.0f–%.0fs (live %.0fs, drift %.0fs)",
                    range.startSeconds,
                    range.endSeconds,
                    timeline.liveEdgeSeconds,
                    timeline.driftSeconds
                )
                let span = max(1, range.endSeconds - range.startSeconds)
                scrubPositionFraction = min(
                    1,
                    max(0, (timeline.positionSeconds - range.startSeconds) / span)
                )
                canSeekToLive = Self.canSeekToLive(timeline.state)
                canScrubBufferedRange = range.durationSeconds > 0 && controlsEnabled
            } else {
                bufferedRangeTitle = "Rolling buffer warming up"
                scrubPositionFraction = 1
                canSeekToLive = false
                canScrubBufferedRange = false
            }
            playerIssue = Self.playerIssue(for: timeline)
            bufferIssue = Self.bufferIssue(for: timeline)
        } else {
            bufferedRangeTitle = "Rolling buffer waiting for decoded PCM"
            scrubPositionFraction = 1
            canSeekToLive = false
            canScrubBufferedRange = false
        }

        recentTranscriptParagraphs = snapshot?.transcriptParagraphs ?? []
        speakerDisplays = snapshot?.speakers ?? []
        currentMetadata = snapshot?.currentMetadata
        recentMetadata = snapshot?.recentMetadata ?? []
        timelineItems = snapshot?.timelineItems ?? []
        timelineRail = snapshot?.timelineRail ?? StreamAppTimelineRailSnapshot(
            visibleStartSeconds: 0,
            visibleEndSeconds: 0
        )
        timelineDiagnostics = snapshot?.diagnostics
        timelineFreshnessMessage =
            snapshot.map { "Timeline refreshed \($0.diagnostics.refreshedAt)." }
            ?? "Timeline waiting for first refresh."
        if let lagSeconds = snapshot?.diagnostics.lagSeconds {
            timelineLagMessage = String(format: "Transcript lag %.0fs.", lagSeconds)
        } else {
            timelineLagMessage = nil
        }
        bufferedSeekUnavailableMessage =
            snapshot?.diagnostics.bufferedSeekUnavailableMessage
            ?? timeline?.unavailableRangeMessage
        hasSeekableTimelineItems = timelineItems.contains { $0.isSeekable }
        self.timelineRefreshErrorMessage = timelineRefreshErrorMessage.map(IngestRedaction.redact)
        self.speakerEditErrorMessage = speakerEditErrorMessage.map(IngestRedaction.redact)
        self.searchDraft = searchDraft
        self.searchSnapshot = searchSnapshot
        self.searchResults = searchSnapshot?.results ?? []
        self.searchDiagnostics = searchSnapshot?.diagnostics
        self.selectedSearchResultID = selectedSearchResultID
        self.selectedSearchSegmentID = selectedSearchSegmentID
        self.transcriptScrollTargetSegmentID = transcriptScrollTargetSegmentID
        self.transcriptScrollTargetID = transcriptScrollTargetSegmentID.map { "transcript:\($0)" }
        self.searchErrorMessage = searchErrorMessage.map(IngestRedaction.redact)
        self.searchJumpMessage = searchJumpMessage.map(IngestRedaction.redact)
    }

    private static func canSeekToLive(_ state: AppPlayerState) -> Bool {
        switch state {
        case .buffering, .playing, .paused:
            return true
        case .idle, .stopped, .failed:
            return false
        }
    }

    static func status(from runtimeStatus: AppStreamRuntimeStatusSnapshot)
        -> StreamAppStatus
    {
        switch runtimeStatus.phase {
        case .connecting:
            return .connecting
        case .running:
            return .running
        case .paused:
            return .paused
        case .suspended:
            return .suspended
        case .recovering:
            return .recovering
        case .reconnecting:
            return .reconnecting(nextRetrySeconds: runtimeStatus.nextRetrySeconds)
        case .stopped:
            return .stopped
        case .error:
            return .error(
                message: runtimeStatus.recentFailure?.message ?? "Runtime status reported an error."
            )
        }
    }

    static func runtimeStatusDetail(for runtimeStatus: AppStreamRuntimeStatusSnapshot)
        -> String
    {
        switch runtimeStatus.phase {
        case .connecting:
            return "Opening the stream source."
        case .running:
            return lifecycleDetail(
                for: runtimeStatus.lifecycleEvidence,
                base: "Live ingest and playback are active.",
                includeReason: false
            )
        case .paused:
            return "The stream is paused."
        case .suspended:
            return lifecycleDetail(
                for: runtimeStatus.lifecycleEvidence,
                base: "The stream is suspended for system sleep.",
                includeReason: true
            )
        case .recovering:
            return lifecycleDetail(
                for: runtimeStatus.lifecycleEvidence,
                base: "The stream is recovering after system wake.",
                includeReason: true
            )
        case .reconnecting:
            var detail = "Retrying"
            if runtimeStatus.maxAttempts > 0 {
                detail += " attempt \(runtimeStatus.attempt) of \(runtimeStatus.maxAttempts)"
            } else if runtimeStatus.attempt > 0 {
                detail += " attempt \(runtimeStatus.attempt)"
            }
            if let seconds = runtimeStatus.nextRetrySeconds {
                detail += " in \(seconds) seconds"
            } else {
                detail += " with backoff"
            }
            if let nextRetryAt = runtimeStatus.nextRetryAt {
                detail += " (next retry \(nextRetryAt))"
            }
            return detail + "."
        case .stopped:
            return "The stream is stopped."
        case .error:
            return runtimeStatus.recentFailure?.message ?? "Runtime status reported an error."
        }
    }

    private static func runtimeRetryDetail(for runtimeStatus: AppStreamRuntimeStatusSnapshot)
        -> String?
    {
        var parts: [String] = []
        if runtimeStatus.maxAttempts > 0 {
            parts.append("Attempt \(runtimeStatus.attempt) of \(runtimeStatus.maxAttempts)")
        } else if runtimeStatus.attempt > 0 {
            parts.append("Attempt \(runtimeStatus.attempt)")
        }
        if let seconds = runtimeStatus.nextRetrySeconds {
            parts.append("next retry in \(seconds)s")
        }
        if let nextRetryAt = runtimeStatus.nextRetryAt {
            parts.append("at \(nextRetryAt)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private static func runtimeIssue(
        for status: StreamAppStatus,
        eventMessage: String?
    ) -> StreamAppVisibleIssue? {
        switch status {
        case .error:
            return StreamAppVisibleIssue(
                id: "runtime.error",
                severity: .blocking,
                message: eventMessage ?? status.detail,
                actionLabel: "Check stream access and retry Start"
            )
        case .reconnecting:
            return StreamAppVisibleIssue(
                id: "runtime.reconnecting",
                severity: .warning,
                message: eventMessage ?? status.detail,
                actionLabel: "Wait for reconnect or stop the stream"
            )
        case .suspended:
            return StreamAppVisibleIssue(
                id: "runtime.suspended",
                severity: .info,
                message: eventMessage ?? status.detail,
                actionLabel: "Wait for system wake or stop the stream"
            )
        case .recovering:
            return StreamAppVisibleIssue(
                id: "runtime.recovering",
                severity: .warning,
                message: eventMessage ?? status.detail,
                actionLabel: "Wait for recovery or stop the stream"
            )
        case .ready, .connecting, .running, .paused, .stopped, .removed:
            return nil
        }
    }

    private static func lifecycleDetail(
        for evidence: AppStreamRuntimeLifecycleEvidence?,
        base: String,
        includeReason: Bool
    ) -> String {
        guard let evidence else { return base }
        var parts: [String] = []
        if includeReason {
            let reason = IngestRedaction.redact(evidence.reason)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !reason.isEmpty {
                parts.append("reason: \(reason)")
            }
        }
        if let suspendedAt = evidence.suspendedAt {
            parts.append("suspended at \(IngestRedaction.redact(suspendedAt))")
        }
        if let recoveryStartedAt = evidence.recoveryStartedAt {
            parts.append("recovery started at \(IngestRedaction.redact(recoveryStartedAt))")
        }
        if let recoveredAt = evidence.recoveredAt {
            parts.append("recovered at \(IngestRedaction.redact(recoveredAt))")
        }
        if let latency = evidence.recoveryLatencySeconds {
            parts.append(String(format: "recovery latency %.3fs", latency))
        }
        guard !parts.isEmpty else { return base }
        return "\(base) \(parts.joined(separator: "; "))."
    }

    private static func playerIssue(for timeline: AppPlayerTimelineSnapshot)
        -> StreamAppVisibleIssue?
    {
        switch timeline.state {
        case .failed(let message):
            return StreamAppVisibleIssue(
                id: "player.failed",
                severity: .warning,
                message: message.isEmpty ? timeline.lastMessage : message,
                actionLabel: "Check audio output and restart playback"
            )
        case .idle, .buffering, .playing, .paused, .stopped:
            return nil
        }
    }

    private static func bufferIssue(for timeline: AppPlayerTimelineSnapshot)
        -> StreamAppVisibleIssue?
    {
        if let message = timeline.unavailableRangeMessage {
            return StreamAppVisibleIssue(
                id: "buffer.seek-unavailable",
                severity: .warning,
                message: message,
                actionLabel: "Choose a buffered time or return to Live"
            )
        }
        guard timeline.rollingBuffer?.memoryOnlyFallback == true else { return nil }
        return StreamAppVisibleIssue(
            id: "buffer.memory-only-fallback",
            severity: .warning,
            message: timeline.rollingBuffer?.lastMessage
                ?? "Rolling buffer is using memory-only fallback; spill storage is unavailable.",
            actionLabel: "Choose a writable buffer location or reduce duration"
        )
    }
}
