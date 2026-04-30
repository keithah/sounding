import Foundation

/// Converts parsed HLS manifest SCTE-35 cue tags into semantic ad markers.
public enum HLSManifestMarkerExtractor {
    public static func extractMarkers(
        from segments: [HLSManifestMediaSegment],
        source: String
    ) throws -> [AdMarker] {
        var markers = [AdMarker]()

        for segment in segments {
            for tag in segment.scte35Tags {
                markers.append(try marker(from: tag, segment: segment, source: source))
            }
        }

        return markers
    }

    private static func marker(
        from tag: HLSManifestSCTE35Tag,
        segment: HLSManifestMediaSegment,
        source: String
    ) throws -> AdMarker {
        if let payload = tag.payload, let encodingHint = tag.payloadEncodingHint {
            return try decodeBinaryMarker(
                payload: payload,
                encodingHint: encodingHint,
                tag: tag,
                segment: segment,
                source: source
            )
        }

        return directMarker(from: tag, segment: segment, source: source)
    }

    private static func decodeBinaryMarker(
        payload: String,
        encodingHint: HLSManifestSCTE35Tag.PayloadEncodingHint,
        tag: HLSManifestSCTE35Tag,
        segment: HLSManifestMediaSegment,
        source: String
    ) throws -> AdMarker {
        let input: SCTE35PayloadInput
        switch encodingHint {
        case .base64:
            input = .base64(payload)
        case .hex:
            input = .hex(payload)
        }

        do {
            var marker = try SCTE35Decoder.decodeMarker(
                input,
                source: "hls_manifest",
                tag: tag.rawTagName,
                segment: segment.mediaSequence
            )
            marker.tags.merge(safeTags(for: segment, source: source, tag: tag)) { _, new in new }
            return marker
        } catch {
            throw MonitorError.operationFailed(
                phase: .decode,
                source: source,
                streamType: .hls,
                context: safeErrorContext(for: segment, tag: tag),
                reason: "\(type(of: error))"
            )
        }
    }

    private static func directMarker(
        from tag: HLSManifestSCTE35Tag,
        segment: HLSManifestMediaSegment,
        source: String
    ) -> AdMarker {
        AdMarker(
            type: "SCTE35",
            classification: .unknown,
            source: "hls_manifest",
            tag: tag.rawTagName,
            segment: segment.mediaSequence,
            rawBase64: nil,
            tags: safeTags(for: segment, source: source, tag: tag),
            fields: tag.fields
        )
    }

    private static func safeTags(
        for segment: HLSManifestMediaSegment,
        source: String,
        tag: HLSManifestSCTE35Tag
    ) -> [String: JSONValue] {
        var tags: [String: JSONValue] = [
            "ManifestSource": .string(MonitorError.redactedSourceDescription(source)),
            "SegmentURI": .string(MonitorError.redactedSourceDescription(segment.uri)),
            "ManifestTag": .string(tag.sanitizedTagIdentity),
            "MediaSequence": .string(segment.mediaSequence)
        ]

        if let duration = segment.duration {
            tags["EXTINFDuration"] = .string(duration)
        }

        return tags
    }

    private static func safeErrorContext(
        for segment: HLSManifestMediaSegment,
        tag: HLSManifestSCTE35Tag
    ) -> [String: String] {
        var context = [
            "sourceClass": "hls_manifest",
            "tag": tag.sanitizedTagIdentity,
            "mediaSequence": segment.mediaSequence,
            "segmentURI": MonitorError.redactedSourceDescription(segment.uri)
        ]

        if let duration = segment.duration {
            context["extinfDuration"] = duration
        }

        return context
    }
}
