import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Orchestrates HLS manifest parsing, manifest-level marker conversion, sequential segment loading,
/// and segment-level SCTE-35 extraction.
public struct HLSMonitorAdapter {
    private let manifestSource: String
    private let manifestText: String?
    private let segmentLoader: HLSSegmentLoading
    private let segmentExtractor: HLSSegmentSCTE35Extracting

    public init(
        manifestSource: String,
        manifestText: String? = nil,
        segmentLoader: HLSSegmentLoading = HLSSegmentLoader(),
        segmentExtractor: HLSSegmentSCTE35Extracting = HLSSegmentSCTE35Extractor()
    ) {
        self.manifestSource = manifestSource
        self.manifestText = manifestText
        self.segmentLoader = segmentLoader
        self.segmentExtractor = segmentExtractor
    }

    public func markers() async throws -> [AdMarker] {
        let manifest = try await openManifestText()
        let segments = HLSManifestParser.parseMediaSegments(manifest)
        var markers = [AdMarker]()

        for segment in segments {
            markers.append(contentsOf: try HLSManifestMarkerExtractor.extractMarkers(
                from: [segment],
                source: manifestSource
            ))

            let segmentData: Data
            do {
                segmentData = try await segmentLoader.loadSegment(uri: segment.uri, relativeTo: manifestSource)
            } catch {
                throw operationError(
                    phase: .ingest,
                    segment: segment,
                    sourceClass: "hls_segment",
                    tag: nil,
                    reason: sanitizedReason(for: error)
                )
            }

            do {
                markers.append(contentsOf: try segmentExtractor.extractMarkers(
                    from: segmentData,
                    mediaSequence: segment.mediaSequence,
                    segmentURI: segment.uri
                ))
            } catch {
                throw operationError(
                    phase: .decode,
                    segment: segment,
                    sourceClass: "hls_segment",
                    tag: "mpegts_scte35_section",
                    reason: sanitizedReason(for: error)
                )
            }
        }

        return markers
    }

    private func openManifestText() async throws -> String {
        if let manifestText {
            return manifestText
        }

        do {
            let data = try await loadManifestData(from: manifestSource)
            guard let text = String(data: data, encoding: .utf8) else {
                throw HLSMonitorAdapterError.invalidManifestTextEncoding
            }
            return text
        } catch {
            throw MonitorError.operationFailed(
                phase: .sourceOpen,
                source: manifestSource,
                streamType: .hls,
                context: ["sourceClass": "hls_manifest"],
                reason: sanitizedReason(for: error)
            )
        }
    }

    private func loadManifestData(from source: String) async throws -> Data {
        if let url = URL(string: source), url.scheme == "http" || url.scheme == "https" {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw HLSMonitorAdapterError.invalidManifestResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw HLSMonitorAdapterError.httpStatus(httpResponse.statusCode)
            }
            return data
        }

        if let url = URL(string: source), url.scheme != nil {
            return try Data(contentsOf: url)
        }

        return try Data(contentsOf: URL(fileURLWithPath: source))
    }

    private func operationError(
        phase: MonitorPhase,
        segment: HLSManifestMediaSegment,
        sourceClass: String,
        tag: String?,
        reason: String
    ) -> MonitorError {
        var context = [
            "sourceClass": sourceClass,
            "segmentURI": MonitorError.redactedSourceDescription(segment.uri),
            "mediaSequence": segment.mediaSequence
        ]
        if let tag {
            context["tag"] = tag
        }

        return MonitorError.operationFailed(
            phase: phase,
            source: manifestSource,
            streamType: .hls,
            context: context,
            reason: reason
        )
    }

    private func sanitizedReason(for error: Error) -> String {
        if let described = error as? CustomStringConvertible {
            return MonitorError.redactedSourceDescription(described.description)
        }
        return String(describing: type(of: error))
    }
}

private enum HLSMonitorAdapterError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidManifestTextEncoding
    case invalidManifestResponse
    case httpStatus(Int)

    var description: String {
        switch self {
        case .invalidManifestTextEncoding:
            return "HLS manifest open failed: manifest bytes are not UTF-8 text."
        case .invalidManifestResponse:
            return "HLS manifest open failed: invalid URL response."
        case let .httpStatus(statusCode):
            return "HLS manifest open failed: HTTP status \(statusCode)."
        }
    }
}
