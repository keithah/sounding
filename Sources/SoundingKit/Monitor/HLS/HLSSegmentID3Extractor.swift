import Foundation

/// Extracts safe ID3 marker metadata from bounded HLS media segment bytes.
public protocol HLSSegmentID3Extracting {
    func extractMarkers(
        from data: Data,
        mediaSequence: String,
        segmentURI: String
    ) throws -> [AdMarker]
}

public struct HLSSegmentID3Extractor: HLSSegmentID3Extracting {
    public init() {}

    public func extractMarkers(
        from data: Data,
        mediaSequence: String,
        segmentURI: String
    ) throws -> [AdMarker] {
        var markers = try ID3MarkerDecoder.decodeMarkers(
            fromSegmentBytes: data,
            source: "hls_segment",
            tag: "ID3",
            segment: mediaSequence
        )

        guard !markers.isEmpty else { return [] }

        let context: [String: JSONValue] = [
            "SegmentURI": .string(MonitorError.redactedSourceDescription(segmentURI)),
            "MediaSequence": .string(mediaSequence),
            "SourceClass": .string("hls_segment")
        ]

        for index in markers.indices {
            markers[index].fields.merge(context) { _, new in new }
        }

        return markers
    }
}
