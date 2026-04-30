import Foundation

/// Stateless monitor execution seam for source adapters.
public enum MonitorPipeline: Sendable {
    public static func run(options: MonitorOptions) async throws -> [AdMarker] {
        let streamType = resolvedStreamType(for: options.source, requested: options.streamType)

        switch streamType {
        case .hls:
            let markers = try await HLSMonitorAdapter(manifestSource: options.source).markers()
            return markers.filter { options.filter.includes($0) }
        case .auto, .icecast, .icy, .mpegts, .udp:
            throw MonitorError.notImplemented(
                phase: .sourceOpen,
                source: options.source,
                streamType: options.streamType
            )
        }
    }

    static func resolvedStreamType(for source: String, requested streamType: StreamType) -> StreamType {
        guard streamType == .auto else {
            return streamType
        }

        return isHLSManifestSource(source) ? .hls : .auto
    }

    private static func isHLSManifestSource(_ source: String) -> Bool {
        if let components = URLComponents(string: source),
           let path = components.path.removingPercentEncoding {
            return path.lowercased().hasSuffix(".m3u8")
        }

        return source.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .lowercased()
            .hasSuffix(".m3u8") == true
    }
}
