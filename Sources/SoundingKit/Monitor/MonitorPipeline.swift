/// Stateless monitor execution seam for future source adapters.
public enum MonitorPipeline: Sendable {
    public static func run(options: MonitorOptions) async throws -> [AdMarker] {
        throw MonitorError.notImplemented(
            phase: .sourceOpen,
            source: options.source,
            streamType: options.streamType
        )
    }
}
