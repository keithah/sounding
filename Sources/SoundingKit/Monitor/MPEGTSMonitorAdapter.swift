import Foundation
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif

public protocol MPEGTSByteLoading: Sendable {
    func loadBytes(from source: String) async throws -> Data
}

public protocol MPEGTSSectionExtracting: Sendable {
    func extractSections(from data: Data) throws -> [Data]
}

public struct MPEGTSByteLoader: MPEGTSByteLoading {
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func loadBytes(from source: String) async throws -> Data {
        if let url = URL(string: source), url.scheme == "http" || url.scheme == "https" {
            let (data, response) = try await HLSURLSessionDataLoader.data(from: url, using: urlSession)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MPEGTSMonitorAdapterError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw MPEGTSMonitorAdapterError.httpStatus(httpResponse.statusCode)
            }
            return data
        }

        if let url = URL(string: source), url.scheme != nil {
            return try Data(contentsOf: url)
        }

        return try Data(contentsOf: URL(fileURLWithPath: source))
    }
}

public struct MPEGTSStreamSectionExtractor: MPEGTSSectionExtracting {
    public init() {}

    public func extractSections(from data: Data) throws -> [Data] {
        var extractor = MPEGTSSectionExtractor()
        return try extractor.feed(data)
    }
}

public struct MPEGTSMonitorAdapter: Sendable {
    private static let sourceClass = "mpegts_stream"
    private static let markerSource = "mpegts"
    private static let markerTag = "mpegts_scte35_section"

    private let source: String
    private let byteLoader: MPEGTSByteLoading
    private let sectionExtractor: MPEGTSSectionExtracting

    public init(
        source: String,
        byteLoader: MPEGTSByteLoading = MPEGTSByteLoader(),
        sectionExtractor: MPEGTSSectionExtracting = MPEGTSStreamSectionExtractor()
    ) {
        self.source = source
        self.byteLoader = byteLoader
        self.sectionExtractor = sectionExtractor
    }

    public func markers() async throws -> [AdMarker] {
        let data: Data
        do {
            data = try await byteLoader.loadBytes(from: source)
        } catch {
            throw operationError(
                phase: .sourceOpen,
                context: baseContext(streamType: "mpegts"),
                reason: sanitizedReason(for: error)
            )
        }

        let sections: [Data]
        do {
            sections = try sectionExtractor.extractSections(from: data)
        } catch {
            throw operationError(
                phase: .ingest,
                context: baseContext(streamType: "mpegts").merging([
                    "byteCount": String(data.count),
                    "packetCount": String(data.count / MPEGTSPacket.size)
                ]) { _, new in new },
                reason: sanitizedReason(for: error)
            )
        }

        return try decodeMarkers(from: sections)
    }

    private func decodeMarkers(from sections: [Data]) throws -> [AdMarker] {
        var markers = [AdMarker]()
        for (index, section) in sections.enumerated() {
            do {
                var marker = try SCTE35Decoder.decodeMarker(
                    .data(section),
                    source: Self.markerSource,
                    tag: Self.markerTag
                )
                marker.tags.merge([
                    "SourceClass": .string(Self.sourceClass),
                    "StreamType": .string("mpegts"),
                    "SectionIndex": .string(String(index))
                ]) { _, new in new }
                markers.append(marker)
            } catch {
                throw operationError(
                    phase: .decode,
                    context: baseContext(streamType: "mpegts").merging([
                        "sectionCount": String(sections.count),
                        "sectionIndex": String(index),
                        "tag": Self.markerTag
                    ]) { _, new in new },
                    reason: sanitizedReason(for: error)
                )
            }
        }
        return markers
    }

    private func baseContext(streamType: String) -> [String: String] {
        [
            "sourceClass": Self.sourceClass,
            "streamType": streamType
        ]
    }

    private func operationError(phase: MonitorPhase, context: [String: String], reason: String) -> MonitorError {
        MonitorError.operationFailed(
            phase: phase,
            source: source,
            streamType: .mpegts,
            context: context,
            reason: reason
        )
    }

    private func sanitizedReason(for error: Error) -> String {
        let description: String
        if let localized = error as? LocalizedError, let errorDescription = localized.errorDescription {
            description = errorDescription
        } else {
            description = String(describing: error)
        }
        return MonitorError.redactedSourceDescription(description)
    }
}

private enum MPEGTSMonitorAdapterError: Error, Equatable, CustomStringConvertible, LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(Int)

    var description: String {
        switch self {
        case .invalidResponse:
            return "MPEG-TS source open failed: invalid URL response."
        case let .httpStatus(statusCode):
            return "MPEG-TS source open failed: HTTP status \(statusCode)."
        }
    }

    var errorDescription: String? {
        description
    }
}
