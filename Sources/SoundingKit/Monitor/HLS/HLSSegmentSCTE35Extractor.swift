import Foundation

/// Extracts SCTE-35 splice sections from bounded HLS MPEG-TS segment bytes.
///
/// This is intentionally a narrow S04 seam: it recognizes fixture-capable MPEG-TS packet
/// payload-unit-start sections and raw deterministic section bytes, then delegates all SCTE-35
/// semantics to the shared decoder. S07 can harden broader transport handling behind this API.
public protocol HLSSegmentSCTE35Extracting: Sendable {
    func extractMarkers(
        from data: Data,
        mediaSequence: String,
        segmentURI: String
    ) throws -> [AdMarker]
}

public struct HLSSegmentSCTE35Extractor: HLSSegmentSCTE35Extracting {
    private static let packetSize = 188
    private static let syncByte: UInt8 = 0x47
    private static let scte35TableID: UInt8 = 0xFC
    private static let markerTag = "mpegts_scte35_section"

    public init() {}

    public func extractMarkers(
        from data: Data,
        mediaSequence: String,
        segmentURI: String
    ) throws -> [AdMarker] {
        guard !data.isEmpty else { return [] }

        if data.first == Self.scte35TableID {
            return [try marker(from: data, mediaSequence: mediaSequence, segmentURI: segmentURI)]
        }

        var markers = [AdMarker]()
        var sawCandidate = false
        var sawTransportPackets = false

        for packetOffset in packetOffsets(in: data) {
            sawTransportPackets = true
            guard let payloadOffset = payloadOffset(in: data, packetOffset: packetOffset) else { continue }
            let payloadUnitStart = (data[packetOffset + 1] & 0x40) != 0
            guard payloadUnitStart, payloadOffset < packetOffset + Self.packetSize else { continue }

            let pointerField = Int(data[payloadOffset])
            let sectionOffset = payloadOffset + 1 + pointerField
            guard sectionOffset < packetOffset + Self.packetSize else { continue }
            guard data[sectionOffset] == Self.scte35TableID else { continue }

            sawCandidate = true
            let section = try sectionData(from: data, startingAt: sectionOffset)
            markers.append(try marker(from: section, mediaSequence: mediaSequence, segmentURI: segmentURI))
        }

        if markers.isEmpty, !sawTransportPackets, !sawCandidate, let candidateOffset = data.firstIndex(of: Self.scte35TableID) {
            sawCandidate = true
            let section = try sectionData(from: data, startingAt: candidateOffset)
            markers.append(try marker(from: section, mediaSequence: mediaSequence, segmentURI: segmentURI))
        }

        return markers
    }

    private func packetOffsets(in data: Data) -> [Int] {
        var offsets = [Int]()
        var offset = 0
        while offset + Self.packetSize <= data.count {
            if data[offset] == Self.syncByte {
                offsets.append(offset)
                offset += Self.packetSize
            } else {
                offset += 1
            }
        }
        return offsets
    }

    private func payloadOffset(in data: Data, packetOffset: Int) -> Int? {
        let adaptationFieldControl = (data[packetOffset + 3] >> 4) & 0x03
        switch adaptationFieldControl {
        case 0x01:
            return packetOffset + 4
        case 0x03:
            let adaptationLengthOffset = packetOffset + 4
            let adaptationLength = Int(data[adaptationLengthOffset])
            let payloadOffset = adaptationLengthOffset + 1 + adaptationLength
            return payloadOffset < packetOffset + Self.packetSize ? payloadOffset : nil
        default:
            return nil
        }
    }

    private func sectionData(from data: Data, startingAt sectionOffset: Int) throws -> Data {
        guard sectionOffset + 3 <= data.count else {
            throw SCTE35DecodeError.malformedSection
        }

        let sectionLength = (Int(data[sectionOffset + 1] & 0x0F) << 8) | Int(data[sectionOffset + 2])
        let sectionEnd = sectionOffset + 3 + sectionLength
        guard sectionEnd <= data.count else {
            throw SCTE35DecodeError.malformedSection
        }

        return data[sectionOffset..<sectionEnd]
    }

    private func marker(from section: Data, mediaSequence: String, segmentURI: String) throws -> AdMarker {
        var marker = try SCTE35Decoder.decodeMarker(
            .data(section),
            source: "hls_segment",
            tag: Self.markerTag,
            segment: mediaSequence
        )
        marker.tags.merge([
            "SegmentURI": .string(MonitorError.redactedSourceDescription(segmentURI)),
            "MediaSequence": .string(mediaSequence),
            "SourceClass": .string("hls_segment")
        ]) { _, new in new }
        return marker
    }
}
