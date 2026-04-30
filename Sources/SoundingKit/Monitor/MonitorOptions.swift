/// Supported stream source type hints for monitor execution.
public enum StreamType: String, CaseIterable, Codable, Equatable, Sendable {
    case auto
    case hls
    case icecast
    case icy
    case mpegts
    case udp
}

/// Library-owned monitor options shared by CLI and future source adapters.
public struct MonitorOptions: Equatable, Sendable {
    public var source: String
    public var streamType: StreamType
    public var filter: MonitorFilter
    public var jsonOut: String?
    public var timeoutSeconds: Double?
    public var quiet: Bool
    public var emitJSON: Bool

    public init(
        source: String,
        streamType: StreamType = .auto,
        filter: String = "all",
        jsonOut: String? = nil,
        timeoutSeconds: Double? = nil,
        quiet: Bool = false,
        emitJSON: Bool = false
    ) throws {
        if let timeoutSeconds, timeoutSeconds < 0 {
            throw MonitorError.invalidTimeout(timeoutSeconds, source: source, streamType: streamType)
        }

        self.source = source
        self.streamType = streamType
        self.filter = try MonitorFilter(normalizing: filter)
        self.jsonOut = jsonOut
        self.timeoutSeconds = timeoutSeconds
        self.quiet = quiet
        self.emitJSON = emitJSON
    }
}
