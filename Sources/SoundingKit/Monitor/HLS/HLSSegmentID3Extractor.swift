import Foundation

/// Extracts safe ID3 marker metadata from bounded HLS media segment bytes.
public protocol HLSSegmentID3Extracting: Sendable {
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
        var markers = MPEGTimedID3Extractor.isLikelyTransportStream(data) ? [] : try rawID3Markers(
            from: data,
            mediaSequence: mediaSequence
        )
        let timedMarkers = try MPEGTimedID3Extractor.extractPayloads(from: data).flatMap { payload in
            var payloadMarkers = try rawID3Markers(
                from: payload.data,
                mediaSequence: mediaSequence
            )
            for index in payloadMarkers.indices {
                if payloadMarkers[index].pts == nil {
                    payloadMarkers[index].pts = payload.ptsSeconds
                }
                if let ptsSeconds = payload.ptsSeconds {
                    payloadMarkers[index].fields["PESTimestampSeconds"] = .number(ptsSeconds)
                }
                payloadMarkers[index].fields["MPEGTSMetadataPID"] = .number(Double(payload.pid))
                payloadMarkers[index].fields["SourceClass"] = .string("hls_timed_id3")
            }
            return payloadMarkers
        }
        markers.append(contentsOf: timedMarkers)

        guard !markers.isEmpty else { return [] }

        let context: [String: JSONValue] = [
            "SegmentURI": .string(MonitorError.redactedSourceDescription(segmentURI)),
            "MediaSequence": .string(mediaSequence)
        ]

        for index in markers.indices {
            markers[index].fields.merge(context) { _, new in new }
        }

        return markers
    }

    private func rawID3Markers(from data: Data, mediaSequence: String) throws -> [AdMarker] {
        var markers = try ID3MarkerDecoder.decodeMarkers(
            fromSegmentBytes: data,
            source: "hls_segment",
            tag: "ID3",
            segment: mediaSequence
        )

        for index in markers.indices {
            markers[index].fields["SourceClass"] = .string("hls_segment")
        }
        return markers
    }
}

private struct MPEGTimedID3Extractor {
    private static let packetSize = MPEGTSPacket.size

    static func extractPayloads(from data: Data) throws -> [TimedID3Payload] {
        guard data.count >= packetSize else { return [] }

        var psiAssemblers: [UInt16: MPEGTSSectionAssembler] = [:]
        var pesAssemblers: [UInt16: PESAssembler] = [:]
        var pmtPIDs = Set<UInt16>()
        var timedID3PIDs = Set<UInt16>()
        var payloads: [TimedID3Payload] = []

        for offset in packetOffsets(in: data) {
            let packet = try MPEGTSPacket(data.subdata(in: offset..<(offset + packetSize)))

            if packet.pid == 0x0000 || pmtPIDs.contains(packet.pid) {
                var assembler = psiAssemblers[packet.pid] ?? MPEGTSSectionAssembler()
                let sections = try assembler.feed(packet)
                psiAssemblers[packet.pid] = assembler

                for section in sections {
                    if packet.pid == 0x0000 {
                        pmtPIDs.formUnion(try MPEGTSProgramMap.pmtPIDs(inPATSection: section))
                    } else if pmtPIDs.contains(packet.pid) {
                        timedID3PIDs.formUnion(try MPEGTSProgramMap.timedID3PIDs(inPMTSection: section))
                    }
                }
            }

            guard timedID3PIDs.contains(packet.pid) else { continue }
            var assembler = pesAssemblers[packet.pid] ?? PESAssembler(pid: packet.pid)
            payloads.append(contentsOf: try assembler.feed(packet))
            pesAssemblers[packet.pid] = assembler
        }

        for assembler in pesAssemblers.values {
            payloads.append(contentsOf: try assembler.finish())
        }

        return payloads
    }

    static func isLikelyTransportStream(_ data: Data) -> Bool {
        guard data.count >= packetSize else { return false }
        return packetOffsets(in: data).count >= 2
    }

    private static func packetOffsets(in data: Data) -> [Int] {
        var offsets: [Int] = []
        var offset = 0
        while offset + packetSize <= data.count {
            if data[offset] == MPEGTSPacket.syncByte {
                offsets.append(offset)
                offset += packetSize
            } else {
                offset += 1
            }
        }
        return offsets
    }
}

private struct TimedID3Payload {
    var pid: UInt16
    var data: Data
    var ptsSeconds: Double?
}

private struct PESAssembler {
    private let pid: UInt16
    private var buffer = Data()
    private var expectedLength: Int?

    init(pid: UInt16) {
        self.pid = pid
    }

    mutating func feed(_ packet: MPEGTSPacket) throws -> [TimedID3Payload] {
        var payloads: [TimedID3Payload] = []

        if packet.payloadUnitStartIndicator {
            payloads.append(contentsOf: try flushComplete())
            buffer = Data()
            expectedLength = nil
        }

        guard !packet.payload.isEmpty else { return payloads }
        buffer.append(packet.payload)
        if expectedLength == nil {
            expectedLength = packetLength(from: buffer)
        }
        payloads.append(contentsOf: try flushComplete())
        return payloads
    }

    func finish() throws -> [TimedID3Payload] {
        guard !buffer.isEmpty else { return [] }
        guard let packet = try decodePES(buffer) else { return [] }
        return [packet]
    }

    private mutating func flushComplete() throws -> [TimedID3Payload] {
        guard let expectedLength, expectedLength > 0, buffer.count >= expectedLength else {
            return []
        }
        let pesBytes = buffer.prefix(expectedLength)
        buffer.removeFirst(expectedLength)
        self.expectedLength = packetLength(from: buffer)
        guard let packet = try decodePES(Data(pesBytes)) else { return [] }
        return [packet]
    }

    private func packetLength(from data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 6,
              bytes[0] == 0x00,
              bytes[1] == 0x00,
              bytes[2] == 0x01
        else { return nil }
        let pesPacketLength = (Int(bytes[4]) << 8) | Int(bytes[5])
        return pesPacketLength == 0 ? nil : 6 + pesPacketLength
    }

    private func decodePES(_ data: Data) throws -> TimedID3Payload? {
        let bytes = [UInt8](data)
        guard bytes.count >= 9,
              bytes[0] == 0x00,
              bytes[1] == 0x00,
              bytes[2] == 0x01
        else { return nil }

        let optionalHeaderLength = Int(bytes[8])
        let payloadOffset = 9 + optionalHeaderLength
        guard payloadOffset <= bytes.count else { return nil }

        let ptsSeconds = ptsSeconds(fromPESHeader: bytes)
        let payload = Data(bytes[payloadOffset..<bytes.count])
        guard !payload.isEmpty else { return nil }
        return TimedID3Payload(pid: pid, data: payload, ptsSeconds: ptsSeconds)
    }

    private func ptsSeconds(fromPESHeader bytes: [UInt8]) -> Double? {
        guard bytes.count >= 14 else { return nil }
        let ptsDTSFlags = (bytes[7] >> 6) & 0x03
        guard ptsDTSFlags == 0x02 || ptsDTSFlags == 0x03 else { return nil }

        let ptsBytes = Array(bytes[9..<14])
        let pts = (UInt64((ptsBytes[0] >> 1) & 0x07) << 30)
            | (UInt64(ptsBytes[1]) << 22)
            | (UInt64((ptsBytes[2] >> 1) & 0x7F) << 15)
            | (UInt64(ptsBytes[3]) << 7)
            | UInt64((ptsBytes[4] >> 1) & 0x7F)
        return Double(pts) / 90_000.0
    }
}
