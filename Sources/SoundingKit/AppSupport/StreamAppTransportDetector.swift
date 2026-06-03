import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct StreamAppTransportProbe: Equatable, Sendable {
    public var contentType: String?
    public var headers: [String: String]

    public init(contentType: String? = nil, headers: [String: String] = [:]) {
        self.contentType = contentType
        self.headers = headers
    }
}

public struct StreamAppTransportDetector: Sendable {
    public typealias Probe = @Sendable (URL) async throws -> StreamAppTransportProbe

    private let probe: Probe

    public init(probe: @escaping Probe) {
        self.probe = probe
    }

    public init() {
        self.probe = { url in try await StreamAppTransportDetector.liveProbe(url: url) }
    }

    public func detect(source: String) async throws -> StreamAppTransport? {
        if let local = Self.localTransport(source: source) {
            return local
        }
        guard let url = URL(string: source) else {
            return nil
        }
        return Self.transport(from: try await probe(url))
    }

    public static func localTransport(source: String) -> StreamAppTransport? {
        let path = sourcePath(source)
        if path.hasSuffix(".m3u8") {
            return .hls
        }
        if path.hasSuffix(".mp3")
            || path.hasSuffix(".aac")
            || path.hasSuffix(".m4a")
            || path.hasSuffix(".pls")
            || path.hasSuffix(".m3u")
        {
            return .icecast
        }
        return nil
    }

    public static func transport(from probe: StreamAppTransportProbe) -> StreamAppTransport? {
        let headers = Dictionary(
            uniqueKeysWithValues: probe.headers.map { ($0.key.lowercased(), $0.value.lowercased()) })
        if headers.keys.contains(where: { $0.hasPrefix("icy-") }) {
            return .icecast
        }

        let contentType = (probe.contentType ?? headers["content-type"] ?? "").lowercased()
        if contentType.contains("mpegurl")
            || contentType.contains("vnd.apple.mpegurl")
            || contentType.contains("x-mpegurl")
        {
            return .hls
        }
        if contentType.contains("audio/mpeg")
            || contentType.contains("audio/aac")
            || contentType.contains("audio/aacp")
            || contentType.contains("audio/mp4")
        {
            return .icecast
        }
        return nil
    }

    static func liveProbe(url: URL) async throws -> StreamAppTransportProbe {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        let (_, response) = try await HLSURLSessionDataLoader.data(for: request, using: .shared)
        guard let httpResponse = response as? HTTPURLResponse else {
            return StreamAppTransportProbe()
        }
        let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key] = String(describing: entry.value)
        }
        return StreamAppTransportProbe(
            contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
            headers: headers
        )
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
}
