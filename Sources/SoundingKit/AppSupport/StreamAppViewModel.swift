import Foundation

public enum StreamAppTransport: String, CaseIterable, Equatable, Sendable, Identifiable {
  case hls
  case icecast

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .hls:
      return "HLS"
    case .icecast:
      return "Icecast / ICY"
    }
  }

  public var registryStreamType: String {
    switch self {
    case .hls:
      return "hls"
    case .icecast:
      return "icy"
    }
  }

  public static func fromRegistryStreamType(_ streamType: String) -> StreamAppTransport? {
    switch streamType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "hls":
      return .hls
    case "icecast", "icy":
      return .icecast
    default:
      return nil
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

  public init(name: String = "", source: String = "", transport: StreamAppTransport = .hls) {
    self.name = name
    self.source = source
    self.transport = transport
  }
}

public struct ValidatedStreamAppAddRequest: Equatable, Sendable {
  public var name: String
  public var source: String
  public var transport: StreamAppTransport
  public var redactedSourceDescription: String

  public var registryStreamType: String { transport.registryStreamType }
}

public enum StreamAppStatus: Equatable, Sendable {
  case ready
  case connecting
  case running
  case paused
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
    case .connecting, .running, .paused, .reconnecting, .removed, .error:
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

  public init(record: StreamRecord) {
    id = record.id
    name = record.name
    transportLabel =
      StreamAppTransport.fromRegistryStreamType(record.streamType)?.displayName
      ?? record.streamType.uppercased()
    sourceDescription = record.sourceDescription
    status = .fromRegistryStatus(record.status)
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
    self.item = item
    switch item.status {
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
      playerStateDetail = item.status.detail
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

    runtimeIssue = Self.runtimeIssue(for: item.status, eventMessage: runtimeEventMessage)
    playerIssue = nil
    bufferIssue = nil

    if let timeline {
      playerStateTitle = timeline.state.title
      playerStateDetail = timeline.unavailableRangeMessage ?? timeline.lastMessage
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
        canSeekToLive = item.status == .running || item.status == .paused
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
    case .ready, .connecting, .running, .paused, .stopped, .removed:
      return nil
    }
  }

  private static func playerIssue(for timeline: AppPlayerTimelineSnapshot) -> StreamAppVisibleIssue? {
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

  private static func bufferIssue(for timeline: AppPlayerTimelineSnapshot) -> StreamAppVisibleIssue? {
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

public struct StreamAppViewModel: Equatable, Sendable {
  public private(set) var streams: [StreamAppListItem]
  public var selectedStreamID: Int64? {
    didSet {
      if oldValue != selectedStreamID {
        clearSelectedSearchResult()
      }
    }
  }
  public private(set) var playerTimelines: [Int64: AppPlayerTimelineSnapshot]
  public private(set) var runtimeEventMessages: [Int64: String]
  public private(set) var timelineSnapshots: [Int64: StreamAppTimelineSnapshot]
  public private(set) var timelineRefreshErrors: [Int64: String]
  public private(set) var speakerEditErrors: [Int64: String]
  public var searchDraft: StreamAppSearchDraft
  public private(set) var searchSnapshot: StreamAppSearchSnapshot?
  public private(set) var selectedSearchResultID: String?
  public private(set) var selectedSearchSegmentID: Int64?
  public private(set) var transcriptScrollTargetSegmentID: Int64?
  public private(set) var searchErrorMessage: String?
  public private(set) var searchJumpMessage: String?
  public private(set) var configurationIssues: [SoundingAppConfigurationIssue]
  public var addDraft: StreamAppAddDraft
  public private(set) var addError: StreamAppValidationError?
  public private(set) var lastLifecycleMessage: String

  public init(
    streams: [StreamAppListItem] = [],
    selectedStreamID: Int64? = nil,
    playerTimelines: [Int64: AppPlayerTimelineSnapshot] = [:],
    runtimeEventMessages: [Int64: String] = [:],
    timelineSnapshots: [Int64: StreamAppTimelineSnapshot] = [:],
    timelineRefreshErrors: [Int64: String] = [:],
    speakerEditErrors: [Int64: String] = [:],
    searchDraft: StreamAppSearchDraft = StreamAppSearchDraft(),
    searchSnapshot: StreamAppSearchSnapshot? = nil,
    selectedSearchResultID: String? = nil,
    selectedSearchSegmentID: Int64? = nil,
    transcriptScrollTargetSegmentID: Int64? = nil,
    searchErrorMessage: String? = nil,
    searchJumpMessage: String? = nil,
    configurationIssues: [SoundingAppConfigurationIssue] = [],
    addDraft: StreamAppAddDraft = StreamAppAddDraft(),
    addError: StreamAppValidationError? = nil,
    lastLifecycleMessage: String = "Add an HLS or Icecast/ICY stream to begin."
  ) {
    self.streams = streams
    self.selectedStreamID = selectedStreamID
    self.playerTimelines = playerTimelines
    self.runtimeEventMessages = runtimeEventMessages.mapValues(IngestRedaction.redact)
    self.timelineSnapshots = timelineSnapshots
    self.timelineRefreshErrors = timelineRefreshErrors.mapValues(IngestRedaction.redact)
    self.speakerEditErrors = speakerEditErrors.mapValues(IngestRedaction.redact)
    self.searchDraft = searchDraft
    self.searchSnapshot = searchSnapshot
    self.selectedSearchResultID = selectedSearchResultID
    self.selectedSearchSegmentID = selectedSearchSegmentID
    self.transcriptScrollTargetSegmentID = transcriptScrollTargetSegmentID
    self.searchErrorMessage = searchErrorMessage.map(IngestRedaction.redact)
    self.searchJumpMessage = searchJumpMessage.map(IngestRedaction.redact)
    self.configurationIssues = configurationIssues
    self.addDraft = addDraft
    self.addError = addError
    self.lastLifecycleMessage = lastLifecycleMessage
  }

  public var selectedStream: StreamAppSelectedStream? {
    guard let selectedStreamID,
      let item = streams.first(where: { $0.id == selectedStreamID })
    else { return nil }
    return StreamAppSelectedStream(
      item: item,
      timeline: playerTimelines[selectedStreamID],
      runtimeEventMessage: runtimeEventMessages[selectedStreamID],
      snapshot: timelineSnapshots[selectedStreamID],
      timelineRefreshErrorMessage: timelineRefreshErrors[selectedStreamID],
      speakerEditErrorMessage: speakerEditErrors[selectedStreamID],
      searchDraft: searchDraft,
      searchSnapshot: searchSnapshot,
      selectedSearchResultID: selectedSearchResultID,
      selectedSearchSegmentID: selectedSearchSegmentID,
      transcriptScrollTargetSegmentID: transcriptScrollTargetSegmentID,
      searchErrorMessage: searchErrorMessage,
      searchJumpMessage: searchJumpMessage
    )
  }

  public var emptyStateTitle: String {
    streams.isEmpty ? "No streams yet" : "Select a stream"
  }

  public var blockingConfigurationIssues: [SoundingAppConfigurationIssue] {
    configurationIssues.filter(\.blocksRuntime)
  }

  public mutating func applyConfiguration(_ configuration: SoundingAppConfiguration) {
    configurationIssues = configuration.issues
    if let blocking = configuration.issues.first(where: { $0.blocksRuntime }) {
      lastLifecycleMessage = blocking.message
    }
  }

  public static func makePreview() -> StreamAppViewModel {
    let item = StreamAppListItem(
      record: StreamRecord(
        id: 1,
        name: "Fixture HLS",
        streamType: "hls",
        sourceDescription: "https://example.test/live.m3u8",
        status: .active,
        createdAt: "2026-05-01T10:00:00Z",
        updatedAt: "2026-05-01T10:00:00Z",
        pausedAt: nil,
        resumedAt: nil,
        removedAt: nil
      )
    )
    return StreamAppViewModel(streams: [item], selectedStreamID: item.id)
  }

  public mutating func reload(from registry: StreamRegistry) throws {
    streams = try registry.list().map(StreamAppListItem.init(record:))
    if let selectedStreamID, !streams.contains(where: { $0.id == selectedStreamID }) {
      self.selectedStreamID = streams.first?.id
    } else if selectedStreamID == nil {
      selectedStreamID = streams.first?.id
    }
    let activeIDs = Set(streams.map(\.id))
    if let selectedSearchSegmentID,
      !(searchSnapshot?.results.contains {
        $0.segmentID == selectedSearchSegmentID && activeIDs.contains($0.streamID)
      } ?? false)
    {
      clearSelectedSearchResult()
    }
    playerTimelines = playerTimelines.filter { activeIDs.contains($0.key) }
    runtimeEventMessages = runtimeEventMessages.filter { activeIDs.contains($0.key) }
    timelineSnapshots = timelineSnapshots.filter { activeIDs.contains($0.key) }
    timelineRefreshErrors = timelineRefreshErrors.filter { activeIDs.contains($0.key) }
    speakerEditErrors = speakerEditErrors.filter { activeIDs.contains($0.key) }
    lastLifecycleMessage =
      streams.isEmpty
      ? "Add an HLS or Icecast/ICY stream to begin."
      : "Loaded \(streams.count) saved stream\(streams.count == 1 ? "" : "s")."
  }

  @discardableResult
  public mutating func addStream(using registry: StreamRegistry) throws -> StreamAppListItem {
    do {
      let request = try Self.validateAddDraft(addDraft)
      let record = try registry.add(
        name: request.name,
        streamType: request.registryStreamType,
        source: request.source
      )
      let item = StreamAppListItem(record: record)
      try reload(from: registry)
      selectedStreamID = item.id
      addDraft = StreamAppAddDraft(transport: addDraft.transport)
      addError = nil
      lastLifecycleMessage = "Added \(item.name) (\(item.transportLabel))."
      return item
    } catch let error as StreamAppValidationError {
      addError = error
      lastLifecycleMessage = error.description
      throw error
    } catch let error as StreamRegistryError {
      let appError = Self.mapRegistryError(error)
      addError = appError
      lastLifecycleMessage = appError.description
      throw appError
    } catch {
      let appError = StreamAppValidationError.registry(String(describing: error))
      addError = appError
      lastLifecycleMessage = appError.description
      throw appError
    }
  }

  public static func validateAddDraft(_ draft: StreamAppAddDraft) throws
    -> ValidatedStreamAppAddRequest
  {
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = draft.source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw StreamAppValidationError.emptyName }
    guard !source.isEmpty else { throw StreamAppValidationError.emptySource }
    guard let components = URLComponents(string: source),
      let scheme = components.scheme?.lowercased(),
      components.host != nil
    else {
      throw StreamAppValidationError.invalidURL
    }
    guard ["http", "https"].contains(scheme) else {
      throw StreamAppValidationError.unsupportedScheme(scheme)
    }
    let redacted = IngestRedaction.sourceDescription(source)
    return ValidatedStreamAppAddRequest(
      name: name,
      source: source,
      transport: draft.transport,
      redactedSourceDescription: redacted
    )
  }

  public mutating func applyRuntimeEvent(_ event: AppStreamRuntimeEvent) {
    for index in streams.indices where streams[index].id == event.streamID {
      streams[index].status = event.phase.appStatus
    }
    runtimeEventMessages[event.streamID] = event.message
    if let playerTimeline = event.result?.playerTimeline {
      playerTimelines[event.streamID] = playerTimeline
      refreshSearchSeekability()
    }
    lastLifecycleMessage = event.message
  }

  @discardableResult
  public mutating func refreshSelectedTimeline(
    using store: StreamAppTimelineStore,
    refreshedAt: String? = nil
  ) throws -> StreamAppTimelineSnapshot {
    let streamID = try requireSelectedStreamID()
    guard streams.contains(where: { $0.id == streamID }) else {
      let error = StreamAppViewModelTimelineError.selectedStreamUnavailable
      timelineRefreshErrors[streamID] = error.description
      throw error
    }

    do {
      let snapshot = try store.snapshot(
        request: StreamAppTimelineRequest(
          streamID: streamID,
          player: playerTimelines[streamID],
          refreshedAt: refreshedAt
        )
      )
      guard streams.contains(where: { $0.id == streamID }) else {
        let error = StreamAppViewModelTimelineError.selectedStreamUnavailable
        timelineRefreshErrors[streamID] = error.description
        throw error
      }
      timelineSnapshots[streamID] = snapshot
      timelineRefreshErrors[streamID] = nil
      lastLifecycleMessage = "Timeline refreshed for selected stream."
      return snapshot
    } catch {
      timelineRefreshErrors[streamID] = Self.redactedTimelineMessage(error)
      lastLifecycleMessage = timelineRefreshErrors[streamID] ?? "Timeline refresh failed."
      throw error
    }
  }

  public mutating func updateSearchDraft(_ draft: StreamAppSearchDraft) {
    searchDraft = draft
    searchErrorMessage = nil
  }

  public mutating func clearSearch() {
    searchSnapshot = nil
    searchErrorMessage = nil
    searchJumpMessage = nil
    clearSelectedSearchResult()
  }

  @discardableResult
  public mutating func runSearch(
    using store: StreamAppSearchStore,
    refreshedAt: String? = nil
  ) throws -> StreamAppSearchSnapshot {
    let streamID = selectedStreamID
    if searchDraft.scopeToSelectedStream {
      _ = try requireSelectedStreamID()
    }
    let request = StreamAppSearchRequest(
      phrase: searchDraft.phrase,
      streamIDs: searchDraft.scopeToSelectedStream ? streamID.map { [$0] } : nil,
      speakerLabels: searchDraft.normalizedSpeakerLabels,
      runStartedAtFrom: searchDraft.runStartedAtFrom,
      runStartedAtThrough: searchDraft.runStartedAtThrough,
      limit: searchDraft.limit,
      contextSegments: searchDraft.contextSegments,
      player: streamID.flatMap { playerTimelines[$0] },
      refreshedAt: refreshedAt
    )
    do {
      var snapshot = try store.snapshot(request: request)
      snapshot = snapshotWithCurrentSeekability(snapshot)
      searchSnapshot = snapshot
      searchErrorMessage = nil
      searchJumpMessage = nil
      clearSelectedSearchResult()
      lastLifecycleMessage = snapshot.diagnostics.statusMessage
      return snapshot
    } catch {
      searchErrorMessage = Self.redactedSearchMessage(error)
      lastLifecycleMessage = searchErrorMessage ?? "Search failed."
      throw error
    }
  }

  public mutating func refreshSearchSeekability() {
    guard let snapshot = searchSnapshot else { return }
    searchSnapshot = snapshotWithCurrentSeekability(snapshot)
  }

  @discardableResult
  public mutating func selectSearchResult(
    id resultID: String,
    using store: StreamAppTimelineStore,
    refreshedAt: String? = nil
  ) throws -> StreamAppSearchSelectionAction {
    let streamID = try requireSelectedStreamID()
    guard streams.contains(where: { $0.id == streamID }) else {
      let error = StreamAppViewModelTimelineError.selectedStreamUnavailable
      searchJumpMessage = error.description
      throw error
    }
    guard let result = searchSnapshot?.results.first(where: { $0.id == resultID }) else {
      let error = StreamAppViewModelTimelineError.searchResultNotFound(resultID)
      searchJumpMessage = error.description
      throw error
    }
    guard result.streamID == streamID else {
      let error = StreamAppViewModelTimelineError.searchResultWrongStream
      searchJumpMessage = error.description
      throw error
    }
    guard result.startSeconds.isFinite && result.startSeconds >= 0 else {
      let error = StreamAppViewModelTimelineError.invalidSearchSeekTarget
      searchJumpMessage = error.description
      throw error
    }

    do {
      let snapshot = try store.snapshot(
        request: StreamAppTimelineRequest(
          streamID: streamID,
          player: playerTimelines[streamID],
          focusedSegmentID: result.segmentID,
          refreshedAt: refreshedAt
        )
      )
      timelineSnapshots[streamID] = snapshot
      timelineRefreshErrors[streamID] = nil
      selectedSearchResultID = result.id
      selectedSearchSegmentID = result.segmentID
      transcriptScrollTargetSegmentID = result.segmentID
      searchJumpMessage =
        result.isSeekable
        ? "Search result selected at \(Self.secondsLabel(result.startSeconds))."
        : (result.seekUnavailableMessage
          ?? StreamAppViewModelTimelineError.searchResultNotSeekable.description)
      lastLifecycleMessage = searchJumpMessage ?? "Search result selected."
      return StreamAppSearchSelectionAction(
        shouldSeek: result.isSeekable,
        seekSeconds: result.isSeekable ? result.startSeconds : nil,
        message: searchJumpMessage
      )
    } catch {
      searchJumpMessage = Self.redactedTimelineMessage(error)
      lastLifecycleMessage = searchJumpMessage ?? "Search jump failed."
      throw error
    }
  }

  public mutating func updateSelectedSpeakerDisplay(
    rawLabel: String,
    displayLabel: String,
    colorToken: String? = nil,
    using store: StreamAppTimelineStore,
    refreshedAt: String? = nil
  ) throws {
    let streamID = try requireSelectedStreamID()
    guard streams.contains(where: { $0.id == streamID }) else {
      let error = StreamAppViewModelTimelineError.selectedStreamUnavailable
      speakerEditErrors[streamID] = error.description
      throw error
    }
    if let snapshot = timelineSnapshots[streamID] {
      let trimmedRawLabel = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
      guard snapshot.speakers.contains(where: { $0.rawLabel == trimmedRawLabel }) else {
        let error = StreamAppViewModelTimelineError.unknownSpeakerLabel(trimmedRawLabel)
        speakerEditErrors[streamID] = error.description
        throw error
      }
    }

    do {
      try store.updateSpeakerDisplay(
        streamID: streamID,
        rawLabel: rawLabel,
        displayLabel: displayLabel,
        colorToken: colorToken
      )
      speakerEditErrors[streamID] = nil
      try refreshSelectedTimeline(using: store, refreshedAt: refreshedAt)
      lastLifecycleMessage = "Updated speaker display for selected stream."
    } catch {
      speakerEditErrors[streamID] = Self.redactedTimelineMessage(error)
      lastLifecycleMessage = speakerEditErrors[streamID] ?? "Speaker display update failed."
      throw error
    }
  }

  private mutating func clearSelectedSearchResult() {
    selectedSearchResultID = nil
    selectedSearchSegmentID = nil
    transcriptScrollTargetSegmentID = nil
  }

  private func snapshotWithCurrentSeekability(_ snapshot: StreamAppSearchSnapshot)
    -> StreamAppSearchSnapshot
  {
    let results = snapshot.results.map { result -> StreamAppSearchResult in
      var updated = result
      let seek = searchSeekability(seconds: result.startSeconds, streamID: result.streamID)
      updated.isSeekable = seek.isSeekable
      updated.seekUnavailableMessage = seek.message
      return updated
    }
    let messages = results.compactMap(\.seekUnavailableMessage)
    let diagnostics = StreamAppSearchDiagnostics(
      status: results.isEmpty ? .empty : .results,
      statusMessage: results.isEmpty
        ? "No transcript results found."
        : "Found \(results.count) transcript result(s).",
      resultCount: results.count,
      refreshedAt: snapshot.diagnostics.refreshedAt,
      validationErrors: snapshot.diagnostics.validationErrors,
      databaseErrorMessage: snapshot.diagnostics.databaseErrorMessage,
      unseekableResultCount: results.filter { !$0.isSeekable }.count,
      bufferedSeekUnavailableMessages: messages
    )
    return StreamAppSearchSnapshot(
      request: snapshot.request, results: results, diagnostics: diagnostics)
  }

  private func searchSeekability(
    seconds: Double,
    streamID: Int64
  ) -> (isSeekable: Bool, message: String?) {
    guard seconds.isFinite && seconds >= 0 else {
      return (false, StreamAppViewModelTimelineError.invalidSearchSeekTarget.description)
    }
    guard let player = playerTimelines[streamID] else {
      return (false, "Result is unavailable because no playback buffer is active.")
    }
    guard player.streamID == streamID else {
      return (false, "Result is unavailable because it is not in the active playback stream.")
    }
    if let start = player.bufferedStartSeconds, let end = player.bufferedEndSeconds {
      guard seconds >= start && seconds <= end else {
        return (
          false, "Result is outside the current playback buffer (available range \(start)-\(end)s)."
        )
      }
      return (true, nil)
    }
    if let range = player.rollingBuffer?.bufferedRange {
      guard seconds >= range.startSeconds && seconds <= range.endSeconds else {
        return (
          false,
          "Result is outside the current playback buffer (available range \(range.startSeconds)-\(range.endSeconds)s)."
        )
      }
      return (true, nil)
    }
    return (false, "Result is unavailable because no playback buffer is active.")
  }

  private func requireSelectedStreamID() throws -> Int64 {
    guard let selectedStreamID else {
      throw StreamAppViewModelTimelineError.noSelectedStream
    }
    return selectedStreamID
  }

  public static func validateRegistryStreamType(_ streamType: String) throws -> StreamAppTransport {
    if let transport = StreamAppTransport.fromRegistryStreamType(streamType) {
      return transport
    }
    throw StreamAppValidationError.unsupportedTransport(
      streamType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "unknown" : streamType
    )
  }

  private static func redactedTimelineMessage(_ error: Error) -> String {
    IngestRedaction.redact(String(describing: error))
  }

  private static func redactedSearchMessage(_ error: Error) -> String {
    IngestRedaction.redact(String(describing: error))
  }

  private static func secondsLabel(_ seconds: Double) -> String {
    String(format: "%.0fs", seconds)
  }

  private static func mapRegistryError(_ error: StreamRegistryError) -> StreamAppValidationError {
    switch error {
    case .invalidName:
      return .emptyName
    case .invalidSource:
      return .emptySource
    case .invalidStreamType:
      return .unsupportedTransport("unknown")
    case .duplicateName:
      return .duplicateName
    case .invalidID, .invalidStatus, .streamNotFound, .streamRemoved,
      .databaseReadFailed, .databaseWriteFailed:
      return .registry(String(describing: error))
    }
  }
}
