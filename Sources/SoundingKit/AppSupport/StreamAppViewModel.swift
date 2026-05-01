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

public struct StreamAppSelectedStream: Equatable, Sendable {
    public var item: StreamAppListItem
    public var playerStateTitle: String
    public var playerStateDetail: String
    public var bufferedRangeTitle: String
    public var controlsEnabled: Bool
    public var canStartRuntime: Bool
    public var canPauseRuntime: Bool
    public var canResumeRuntime: Bool
    public var canStopRuntime: Bool

    public init(item: StreamAppListItem) {
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
        bufferedRangeTitle = "Rolling buffer pending playback wiring"
    }
}

public struct StreamAppViewModel: Equatable, Sendable {
    public private(set) var streams: [StreamAppListItem]
    public var selectedStreamID: Int64?
    public var addDraft: StreamAppAddDraft
    public private(set) var addError: StreamAppValidationError?
    public private(set) var lastLifecycleMessage: String

    public init(
        streams: [StreamAppListItem] = [],
        selectedStreamID: Int64? = nil,
        addDraft: StreamAppAddDraft = StreamAppAddDraft(),
        addError: StreamAppValidationError? = nil,
        lastLifecycleMessage: String = "Add an HLS or Icecast/ICY stream to begin."
    ) {
        self.streams = streams
        self.selectedStreamID = selectedStreamID
        self.addDraft = addDraft
        self.addError = addError
        self.lastLifecycleMessage = lastLifecycleMessage
    }

    public var selectedStream: StreamAppSelectedStream? {
        guard let selectedStreamID,
            let item = streams.first(where: { $0.id == selectedStreamID })
        else { return nil }
        return StreamAppSelectedStream(item: item)
    }

    public var emptyStateTitle: String {
        streams.isEmpty ? "No streams yet" : "Select a stream"
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
        lastLifecycleMessage = event.message
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
