import Foundation

/// Stateless monitor execution seam for source adapters.
public enum MonitorPipeline: Sendable {
    typealias ICYAdapterFactory = @Sendable (_ source: String, _ streamType: StreamType) -> ICYMonitorAdapter

    static let defaultICYAdapterFactory: ICYAdapterFactory = { source, streamType in
        ICYMonitorAdapter(source: source, streamType: streamType)
    }

    nonisolated(unsafe) static var icyAdapterFactory: ICYAdapterFactory = defaultICYAdapterFactory

    public static func run(options: MonitorOptions) async throws -> [AdMarker] {
        let streamType = resolvedStreamType(for: options.source, requested: options.streamType)
        var classifier = MarkerClassifier()

        let markers = try await runAdapter(options: options, resolvedStreamType: streamType) {
            switch streamType {
            case .hls:
                return try await HLSMonitorAdapter(manifestSource: options.source).markers()
            case .icecast, .icy:
                return try await icyAdapterFactory(options.source, streamType).markers()
            case .mpegts:
                return try await MPEGTSMonitorAdapter(source: options.source).markers()
            case .udp:
                return try await UDPMonitorAdapter(source: options.source).markers()
            case .auto:
                throw MonitorError.notImplemented(
                    phase: .sourceOpen,
                    source: options.source,
                    streamType: options.streamType
                )
            }
        }

        return classifyAndFilter(markers, filter: options.filter, classifier: &classifier)
    }

    private static func runAdapter(
        options: MonitorOptions,
        resolvedStreamType streamType: StreamType,
        operation: @escaping @Sendable () async throws -> [AdMarker]
    ) async throws -> [AdMarker] {
        guard let timeoutSeconds = options.timeoutSeconds else {
            return try await operation()
        }

        return try await withThrowingTaskGroup(of: [AdMarker].self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds(for: timeoutSeconds))
                throw timeoutError(options: options, streamType: streamType, timeoutSeconds: timeoutSeconds)
            }

            defer { group.cancelAll() }

            guard let result = try await group.next() else {
                throw timeoutError(options: options, streamType: streamType, timeoutSeconds: timeoutSeconds)
            }
            return result
        }
    }

    private static func timeoutNanoseconds(for timeoutSeconds: Double) -> UInt64 {
        guard timeoutSeconds.isFinite else {
            return UInt64.max
        }

        let seconds = max(timeoutSeconds, 0)
        let nanoseconds = (seconds * 1_000_000_000).rounded(.up)
        guard nanoseconds < Double(UInt64.max) else {
            return UInt64.max
        }
        return UInt64(nanoseconds)
    }

    private static func timeoutError(
        options: MonitorOptions,
        streamType: StreamType,
        timeoutSeconds: Double
    ) -> MonitorError {
        MonitorError.operationFailed(
            phase: .ingest,
            source: options.source,
            streamType: streamType,
            context: [
                "sourceClass": sourceClass(for: streamType),
                "streamType": streamType.rawValue,
                "timeoutSeconds": String(timeoutSeconds)
            ],
            reason: "Monitor operation timed out."
        )
    }

    private static func sourceClass(for streamType: StreamType) -> String {
        switch streamType {
        case .hls:
            return "hls_manifest"
        case .icecast, .icy:
            return "icy_stream"
        case .mpegts:
            return "mpegts_stream"
        case .udp:
            return "udp_datagram_replay"
        case .auto:
            return "auto_stream"
        }
    }

    private static func classifyAndFilter(
        _ markers: [AdMarker],
        filter: MonitorFilter,
        classifier: inout MarkerClassifier
    ) -> [AdMarker] {
        markers
            .map { classifier.classify($0) }
            .filter { filter.includes($0) }
    }

    static func resolvedStreamType(for source: String, requested streamType: StreamType) -> StreamType {
        guard streamType == .auto else {
            return streamType
        }

        if isHLSManifestSource(source) {
            return .hls
        }
        if isUDPSource(source) {
            return .udp
        }
        if isMPEGTransportStreamSource(source) {
            return .mpegts
        }
        return .auto
    }

    private static func isHLSManifestSource(_ source: String) -> Bool {
        sourcePath(source).hasSuffix(".m3u8")
    }

    private static func isUDPSource(_ source: String) -> Bool {
        URLComponents(string: source)?.scheme?.lowercased() == "udp"
    }

    private static func isMPEGTransportStreamSource(_ source: String) -> Bool {
        let path = sourcePath(source)
        return path.hasSuffix(".ts") || path.hasSuffix(".m2ts")
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
            .lowercased() ?? ""
    }
}
