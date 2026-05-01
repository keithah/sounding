import Foundation

/// Stateful native MPEG-TS PSI/SCTE-35 section extractor.
public struct MPEGTSSectionExtractor: Sendable {
    private var bytes = Data()
    private var assemblers: [UInt16: MPEGTSSectionAssembler] = [:]
    private var pmtPIDs = Set<UInt16>()
    private var scte35PIDs = Set<UInt16>()

    public init() {}

    public mutating func feed(_ chunk: Data) throws -> [Data] {
        guard !chunk.isEmpty else { return [] }
        bytes.append(chunk)

        var sections = [Data]()
        while true {
            guard resynchronize() else { return sections }
            guard bytes.count >= MPEGTSPacket.size else { return sections }

            let packetBytes = bytes.prefix(MPEGTSPacket.size)
            bytes.removeFirst(MPEGTSPacket.size)

            let packet = try MPEGTSPacket(Data(packetBytes))
            sections.append(contentsOf: try process(packet))
        }
    }

    /// Validates that no incomplete transport packet remains for datagram replay.
    /// Raw stream callers can omit this to keep buffering across future feeds.
    public mutating func finishDatagramReplay() throws {
        guard !bytes.isEmpty else { return }
        defer { bytes.removeAll(keepingCapacity: true) }
        if bytes.first == MPEGTSPacket.syncByte {
            throw MPEGTSExtractionError.truncatedDatagram
        }
    }

    private mutating func process(_ packet: MPEGTSPacket) throws -> [Data] {
        guard packet.pid == 0x0000 || pmtPIDs.contains(packet.pid) || scte35PIDs.contains(packet.pid) else {
            return []
        }

        var assembler = assemblers[packet.pid] ?? MPEGTSSectionAssembler()
        let psiSections = try assembler.feed(packet)
        assemblers[packet.pid] = assembler

        var scteSections = [Data]()
        for section in psiSections {
            if packet.pid == 0x0000 {
                pmtPIDs.formUnion(try MPEGTSProgramMap.pmtPIDs(inPATSection: section))
            } else if pmtPIDs.contains(packet.pid) {
                scte35PIDs.formUnion(try MPEGTSProgramMap.scte35PIDs(inPMTSection: section))
            } else if scte35PIDs.contains(packet.pid), section.first == 0xFC {
                scteSections.append(section)
            }
        }
        return scteSections
    }

    private mutating func resynchronize() -> Bool {
        guard !bytes.isEmpty else { return false }

        if bytes.first == MPEGTSPacket.syncByte, isLikelyPacketBoundary(at: bytes.startIndex) {
            return true
        }

        var candidate = bytes.index(after: bytes.startIndex)
        while candidate < bytes.endIndex {
            if bytes[candidate] == MPEGTSPacket.syncByte, isLikelyPacketBoundary(at: candidate) {
                bytes.removeSubrange(bytes.startIndex..<candidate)
                return true
            }
            candidate = bytes.index(after: candidate)
        }

        bytes.removeAll(keepingCapacity: true)
        return false
    }

    private func isLikelyPacketBoundary(at index: Data.Index) -> Bool {
        let nextPacketIndex = bytes.index(index, offsetBy: MPEGTSPacket.size, limitedBy: bytes.endIndex)
        guard let nextPacketIndex, nextPacketIndex < bytes.endIndex else {
            return true
        }
        if bytes[nextPacketIndex] == MPEGTSPacket.syncByte {
            return true
        }
        return bytes[nextPacketIndex] == 0xFF && bytes[nextPacketIndex..<bytes.endIndex].allSatisfy({ $0 == 0xFF })
    }
}
