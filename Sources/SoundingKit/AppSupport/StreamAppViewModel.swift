import Foundation

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
    public private(set) var runtimeStatuses: [Int64: AppStreamRuntimeStatusSnapshot]
    public private(set) var runtimeEventMessages: [Int64: String]
    public private(set) var timelineSnapshots: [Int64: StreamAppTimelineSnapshot]
    public private(set) var timelineRefreshErrors: [Int64: String]
    public private(set) var speakerEditErrors: [Int64: String]
    public private(set) var volumeDrafts: [Int64: Double]
    public private(set) var mutedStreamIDs: Set<Int64>
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
        runtimeStatuses: [Int64: AppStreamRuntimeStatusSnapshot] = [:],
        runtimeEventMessages: [Int64: String] = [:],
        timelineSnapshots: [Int64: StreamAppTimelineSnapshot] = [:],
        timelineRefreshErrors: [Int64: String] = [:],
        speakerEditErrors: [Int64: String] = [:],
        volumeDrafts: [Int64: Double] = [:],
        mutedStreamIDs: Set<Int64> = [],
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
        self.runtimeStatuses = runtimeStatuses
        self.runtimeEventMessages = runtimeEventMessages.mapValues(IngestRedaction.redact)
        self.timelineSnapshots = timelineSnapshots
        self.timelineRefreshErrors = timelineRefreshErrors.mapValues(IngestRedaction.redact)
        self.speakerEditErrors = speakerEditErrors.mapValues(IngestRedaction.redact)
        self.volumeDrafts = volumeDrafts.mapValues { min(max($0, 0), 1) }
        self.mutedStreamIDs = mutedStreamIDs
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
            runtimeStatus: runtimeStatuses[selectedStreamID],
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
        runtimeStatuses = runtimeStatuses.filter { activeIDs.contains($0.key) }
        runtimeEventMessages = runtimeEventMessages.filter { activeIDs.contains($0.key) }
        timelineSnapshots = timelineSnapshots.filter { activeIDs.contains($0.key) }
        timelineRefreshErrors = timelineRefreshErrors.filter { activeIDs.contains($0.key) }
        speakerEditErrors = speakerEditErrors.filter { activeIDs.contains($0.key) }
        volumeDrafts = volumeDrafts.filter { activeIDs.contains($0.key) }
        mutedStreamIDs = mutedStreamIDs.filter { activeIDs.contains($0) }
        lastLifecycleMessage =
            streams.isEmpty
            ? "Add an HLS or Icecast/ICY stream to begin."
            : "Loaded \(streams.count) saved stream\(streams.count == 1 ? "" : "s")."
    }

    public func volume(for streamID: Int64) -> Double {
        volumeDrafts[streamID] ?? 1.0
    }

    public func isMuted(streamID: Int64) -> Bool {
        mutedStreamIDs.contains(streamID)
    }

    public mutating func updateVolume(streamID: Int64, volume: Double) {
        volumeDrafts[streamID] = min(max(volume, 0), 1)
    }

    public mutating func updateMuted(streamID: Int64, isMuted: Bool) {
        if isMuted {
            mutedStreamIDs.insert(streamID)
        } else {
            mutedStreamIDs.remove(streamID)
        }
    }

    @discardableResult
    public mutating func updateAudioArchive(
        streamID: Int64,
        isEnabled: Bool,
        using registry: StreamRegistry
    ) throws -> StreamAppListItem {
        let result = try registry.updateAudioArchive(streamID: streamID, isEnabled: isEnabled)
        return replaceStream(result.record)
    }

    @discardableResult
    public mutating func updateTranscriptionPolicy(
        streamID: Int64,
        policy: StreamTranscriptionPolicy,
        using registry: StreamRegistry
    ) throws -> StreamAppListItem {
        let result = try registry.updateTranscriptionPolicy(streamID: streamID, policy: policy)
        return replaceStream(result.record)
    }

    @discardableResult
    public mutating func addStream(using registry: StreamRegistry) throws -> StreamAppListItem {
        do {
            let request = try Self.validateAddDraft(addDraft)
            return try addStream(using: registry, request: request)
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

    @discardableResult
    public mutating func addStream(
        using registry: StreamRegistry,
        detector: StreamAppTransportDetector
    ) async throws -> StreamAppListItem {
        do {
            let request = try await Self.validateAddDraft(addDraft, detector: detector)
            return try addStream(using: registry, request: request)
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

    @discardableResult
    public mutating func addStream(
        using registry: StreamRegistry,
        request: ValidatedStreamAppAddRequest
    ) throws -> StreamAppListItem {
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
        let resolvedTransport = try Self.resolveTransport(draft.transport, source: source)
        return ValidatedStreamAppAddRequest(
            name: name,
            source: source,
            transport: draft.transport,
            resolvedTransport: resolvedTransport,
            redactedSourceDescription: redacted
        )
    }

    public static func validateAddDraft(
        _ draft: StreamAppAddDraft,
        detector: StreamAppTransportDetector
    ) async throws -> ValidatedStreamAppAddRequest {
        do {
            return try validateAddDraft(draft)
        } catch StreamAppValidationError.unsupportedTransport("auto") {
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = draft.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = try await detector.detect(source: source)
            guard let resolved else {
                throw StreamAppValidationError.unsupportedTransport("auto")
            }
            return ValidatedStreamAppAddRequest(
                name: name,
                source: source,
                transport: draft.transport,
                resolvedTransport: resolved,
                redactedSourceDescription: IngestRedaction.sourceDescription(source)
            )
        }
    }

    private static func resolveTransport(
        _ transport: StreamAppTransport,
        source: String
    ) throws -> StreamAppTransport {
        guard transport == .auto else { return transport }
        if sourceLooksLikeHLS(source) {
            return .hls
        }
        if sourceLooksLikeIcecast(source) {
            return .icecast
        }
        throw StreamAppValidationError.unsupportedTransport("auto")
    }

    private static func sourceLooksLikeHLS(_ source: String) -> Bool {
        sourcePath(source).hasSuffix(".m3u8")
    }

    private static func sourceLooksLikeIcecast(_ source: String) -> Bool {
        let path = sourcePath(source)
        return path.hasSuffix(".mp3")
            || path.hasSuffix(".aac")
            || path.hasSuffix(".m4a")
            || path.hasSuffix(".pls")
            || path.hasSuffix(".m3u")
    }

    private static func sourcePath(_ source: String) -> String {
        if let components = URLComponents(string: source),
           let path = components.path.removingPercentEncoding {
            return path.lowercased()
        }
        return source.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .lowercased() ?? source.lowercased()
    }

    public mutating func applyRuntimeEvent(_ event: AppStreamRuntimeEvent) {
        if event.kind != .playerTelemetry {
            for index in streams.indices where streams[index].id == event.streamID {
                streams[index].status = event.phase.appStatus
                streams[index].runtimeStatusDetail = event.message
            }
        }
        runtimeEventMessages[event.streamID] = event.message
        if let playerTimeline = event.result?.playerTimeline {
            playerTimelines[event.streamID] = playerTimeline
            refreshSearchSeekability()
        }
        lastLifecycleMessage = event.message
    }

    public mutating func applyRuntimeStatus(_ snapshot: AppStreamRuntimeStatusSnapshot) {
        guard let index = streams.firstIndex(where: { $0.id == snapshot.streamID }) else {
            runtimeStatuses[snapshot.streamID] = nil
            runtimeEventMessages[snapshot.streamID] = nil
            return
        }
        runtimeStatuses[snapshot.streamID] = snapshot
        streams[index].status = StreamAppSelectedStream.status(from: snapshot)
        streams[index].runtimeStatusDetail = StreamAppSelectedStream.runtimeStatusDetail(
            for: snapshot)
    }

    public mutating func applyRuntimeStatuses(_ snapshots: [AppStreamRuntimeStatusSnapshot]) {
        let activeIDs = Set(streams.map(\.id))
        runtimeStatuses = Dictionary(
            uniqueKeysWithValues:
                snapshots
                .filter { activeIDs.contains($0.streamID) }
                .map { ($0.streamID, $0) }
        )
        for index in streams.indices {
            if let snapshot = runtimeStatuses[streams[index].id] {
                streams[index].status = StreamAppSelectedStream.status(from: snapshot)
                streams[index].runtimeStatusDetail = StreamAppSelectedStream.runtimeStatusDetail(
                    for: snapshot)
            } else {
                streams[index].runtimeStatusDetail = nil
            }
        }
        runtimeEventMessages = runtimeEventMessages.filter { activeIDs.contains($0.key) }
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
            let policy = streams.first(where: { $0.id == streamID })?.transcriptionPolicy ?? .defaultValue
            let snapshot = try store.snapshot(
                request: StreamAppTimelineRequest(
                    streamID: streamID,
                    player: playerTimelines[streamID],
                    hideDeterministicUnknownSongs: true,
                    transcriptionPolicy: policy,
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
                    hideDeterministicUnknownSongs: true,
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

    @discardableResult
    private mutating func replaceStream(_ record: StreamRecord) -> StreamAppListItem {
        var item = StreamAppListItem(record: record)
        if let index = streams.firstIndex(where: { $0.id == record.id }) {
            item.status = streams[index].status
            item.runtimeStatusDetail = streams[index].runtimeStatusDetail
            streams[index] = item
        } else {
            streams.append(item)
            streams.sort { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
        return item
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
                    false,
                    "Result is outside the current playback buffer (available range \(start)-\(end)s)."
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

    public static func validateRegistryStreamType(_ streamType: String) throws -> StreamAppTransport
    {
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
