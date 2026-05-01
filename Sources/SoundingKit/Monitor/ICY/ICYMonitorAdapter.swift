import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Opens and decodes ICY/Icecast metadata streams into raw ICY markers.
///
/// The adapter owns source opening and framed stream iteration only. Metadata parsing remains in
/// `ICYMetadataParser`, semantic ad-state classification remains in `MarkerClassifier`, and all
/// surfaced monitor failures carry structural context without raw stream/header payloads.
public struct ICYMonitorAdapter: Sendable {
    public struct OpenedStream: Sendable {
        public let responseHeaders: [String: String]
        public let streamBytes: Data

        public init(responseHeaders: [String: String], streamBytes: Data) {
            self.responseHeaders = responseHeaders
            self.streamBytes = streamBytes
        }
    }

    public typealias Opener = @Sendable (_ source: String, _ requestHeaders: [String: String]) async throws -> OpenedStream

    private let source: String
    private let streamType: StreamType
    private let opener: Opener

    public init(source: String, streamType: StreamType) {
        self.init(source: source, streamType: streamType) { source, headers in
            try await ICYMonitorAdapter.openStream(source: source, requestHeaders: headers)
        }
    }

    public init(
        source: String,
        streamType: StreamType,
        opener: @escaping Opener
    ) {
        self.source = source
        self.streamType = streamType
        self.opener = opener
    }

    public func markers() async throws -> [AdMarker] {
        let opened: OpenedStream
        do {
            opened = try await opener(source, ICYMetadataParser.requestHeaders)
        } catch {
            throw MonitorError.operationFailed(
                phase: .sourceOpen,
                source: source,
                streamType: streamType,
                context: ["sourceClass": "icy_stream"],
                reason: "ICY source open failed."
            )
        }

        let metaInt = try resolvedMetaInt(from: opened.responseHeaders)
        var cursor = DataCursor(opened.streamBytes)
        let reader = ICYMetadataStreamReader { requestedCount in
            cursor.read(upTo: requestedCount)
        }
        var parser = ICYMetadataParser()
        var markers = [AdMarker]()

        while !cursor.isAtEnd {
            let frame: ICYMetadataFrame
            do {
                frame = try reader.readFrame(metaInt: metaInt)
            } catch let error as ICYMetadataError {
                throw monitorError(for: error)
            } catch {
                throw MonitorError.operationFailed(
                    phase: .ingest,
                    source: source,
                    streamType: streamType,
                    context: ["sourceClass": "icy_stream", "metaInt": String(metaInt)],
                    reason: "ICY stream ingest failed."
                )
            }

            if let marker = parser.marker(fromMetadataBlock: frame.metadata) {
                markers.append(marker)
            }
        }

        return markers
    }

    private func resolvedMetaInt(from headers: [String: String]) throws -> Int {
        guard let rawValue = caseInsensitiveValue(for: "icy-metaint", in: headers) else {
            return ICYMetadataParser.defaultMetaInt
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ICYMetadataParser.defaultMetaInt
        }

        guard let value = Int(trimmed) else {
            throw MonitorError.operationFailed(
                phase: .configuration,
                source: source,
                streamType: streamType,
                context: ["sourceClass": "icy_stream", "metaInt": "invalid"],
                reason: "ICY metadata interval header is malformed."
            )
        }

        guard value > 0 else {
            throw MonitorError.operationFailed(
                phase: .configuration,
                source: source,
                streamType: streamType,
                context: ["sourceClass": "icy_stream", "metaInt": "nonPositive"],
                reason: "ICY metadata interval header must be positive."
            )
        }

        return value
    }

    private func caseInsensitiveValue(for key: String, in headers: [String: String]) -> String? {
        headers.first { candidate, _ in
            candidate.caseInsensitiveCompare(key) == .orderedSame
        }?.value
    }

    private func monitorError(for error: ICYMetadataError) -> MonitorError {
        var context = error.context
        context["sourceClass"] = "icy_stream"

        if case .invalidMetaInt = error {
            return MonitorError.operationFailed(
                phase: .configuration,
                source: source,
                streamType: streamType,
                context: context,
                reason: "ICY metadata interval is invalid."
            )
        }

        let monitorPhase: MonitorPhase
        if case let .incompleteRead(phase, _, _) = error, phase == .metadata {
            monitorPhase = .decode
        } else {
            monitorPhase = .ingest
        }

        return MonitorError.operationFailed(
            phase: monitorPhase,
            source: source,
            streamType: streamType,
            context: context,
            reason: "ICY metadata frame read failed."
        )
    }

    private static func openStream(source: String, requestHeaders: [String: String]) async throws -> OpenedStream {
        if let url = URL(string: source), url.scheme == "http" || url.scheme == "https" {
            var request = URLRequest(url: url)
            for (field, value) in requestHeaders {
                request.setValue(value, forHTTPHeaderField: field)
            }

            let (data, response) = try await loadHTTPData(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ICYMonitorAdapterError.invalidHTTPResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ICYMonitorAdapterError.httpStatus(httpResponse.statusCode)
            }

            let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                result[String(describing: pair.key)] = String(describing: pair.value)
            }
            return OpenedStream(responseHeaders: headers, streamBytes: data)
        }

        if let url = URL(string: source), url.scheme != nil {
            return OpenedStream(responseHeaders: [:], streamBytes: try Data(contentsOf: url))
        }

        return OpenedStream(responseHeaders: [:], streamBytes: try Data(contentsOf: URL(fileURLWithPath: source)))
    }
    private static func loadHTTPData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data, let response else {
                    continuation.resume(throwing: ICYMonitorAdapterError.missingHTTPResponse)
                    return
                }

                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }
}

private struct DataCursor {
    private let data: Data
    private var offset: Data.Index

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var isAtEnd: Bool {
        offset >= data.endIndex
    }

    mutating func read(upTo count: Int) -> Data {
        guard count > 0, !isAtEnd else { return Data() }

        let end = data.index(offset, offsetBy: count, limitedBy: data.endIndex) ?? data.endIndex
        let chunk = data[offset..<end]
        offset = end
        return Data(chunk)
    }
}

private enum ICYMonitorAdapterError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidHTTPResponse
    case missingHTTPResponse
    case httpStatus(Int)

    var description: String {
        switch self {
        case .invalidHTTPResponse:
            return "ICY source open failed: invalid URL response."
        case .missingHTTPResponse:
            return "ICY source open failed: missing URL response."
        case let .httpStatus(statusCode):
            return "ICY source open failed: HTTP status \(statusCode)."
        }
    }
}
