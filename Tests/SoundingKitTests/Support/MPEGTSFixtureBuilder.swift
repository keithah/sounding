import Foundation

enum MPEGTSFixtureBuilder {
    static let packetSize = 188
    static let datagramPacketCount = 7
    static let pmtPID: UInt16 = 0x0100
    static let scte35PID: UInt16 = 0x0101
    static let ignoredPID: UInt16 = 0x0102

    static var spliceNullSection: Data {
        var section = Data([
            0xFC,
            0x30, 0x00, // patched section_length
            0x00, // protocol_version
            0x00, 0x00, 0x00, 0x00, 0x00, // encrypted_packet=false, encryption_algorithm=0, pts_adjustment=0
            0x00, // cw_index
            0xFF, // tier high bits
            0xF0, 0x00, // tier low bits + splice_command_length=0
            0x00, // splice_null()
            0x00, 0x00, // descriptor_loop_length=0
            0x00, 0x00, 0x00, 0x00 // CRC placeholder; M001 does not validate CRC
        ])
        patchSectionLength(in: &section)
        return section
    }

    static func transportStream(
        section: Data = spliceNullSection,
        includePAT: Bool = true,
        includePMT: Bool = true,
        sctePID: UInt16 = scte35PID,
        includeAdaptationField: Bool = false
    ) -> Data {
        var data = Data()
        if includePAT {
            data.append(patPacket(pmtPID: pmtPID))
        }
        if includePMT {
            data.append(pmtPacket(sctePID: sctePID))
        }
        data.append(scte35Packet(section: section, pid: sctePID, includeAdaptationField: includeAdaptationField))
        return data
    }

    static func patPacket(pmtPID: UInt16 = pmtPID, continuityCounter: UInt8 = 0) -> Data {
        packet(pid: 0x0000, payloadUnitStart: true, continuityCounter: continuityCounter, payload: pointerSection(patSection(pmtPID: pmtPID)))
    }

    static func pmtPacket(
        sctePID: UInt16 = scte35PID,
        streamType: UInt8 = 0x86,
        continuityCounter: UInt8 = 0
    ) -> Data {
        packet(pid: pmtPID, payloadUnitStart: true, continuityCounter: continuityCounter, payload: pointerSection(pmtSection(sctePID: sctePID, streamType: streamType)))
    }

    static func pmtPacket(
        streams: [(streamType: UInt8, elementaryPID: UInt16)],
        continuityCounter: UInt8 = 0
    ) -> Data {
        packet(pid: pmtPID, payloadUnitStart: true, continuityCounter: continuityCounter, payload: pointerSection(pmtSection(streams: streams)))
    }

    static func scte35Packet(
        section: Data = spliceNullSection,
        pid: UInt16 = scte35PID,
        continuityCounter: UInt8 = 0,
        includeAdaptationField: Bool = false
    ) -> Data {
        packet(
            pid: pid,
            payloadUnitStart: true,
            continuityCounter: continuityCounter,
            payload: pointerSection(section),
            adaptationField: includeAdaptationField ? Data([0x00]) : nil
        )
    }

    static func splitSCTE35SectionPackets(
        section: Data = spliceNullSection,
        pid: UInt16 = scte35PID,
        firstPayloadByteCount: Int
    ) -> [Data] {
        precondition(firstPayloadByteCount > 0)
        precondition(firstPayloadByteCount < section.count)
        let first = Data(section.prefix(firstPayloadByteCount))
        let second = Data(section.dropFirst(firstPayloadByteCount))
        return [
            packet(pid: pid, payloadUnitStart: true, continuityCounter: 0, payload: pointerSection(first)),
            packet(pid: pid, payloadUnitStart: false, continuityCounter: 1, payload: second)
        ]
    }

    static func chunkedBytes(_ data: Data, sizes: [Int]) -> [Data] {
        precondition(!sizes.isEmpty)
        var chunks = [Data]()
        var offset = data.startIndex
        var sizeIndex = 0
        while offset < data.endIndex {
            let size = sizes[sizeIndex % sizes.count]
            precondition(size > 0)
            let end = data.index(offset, offsetBy: min(size, data.distance(from: offset, to: data.endIndex)))
            chunks.append(data[offset..<end])
            offset = end
            sizeIndex += 1
        }
        return chunks
    }

    static func datagrams(from packets: Data, packetsPerDatagram: Int = datagramPacketCount) -> [Data] {
        precondition(packetsPerDatagram > 0)
        let datagramSize = packetSize * packetsPerDatagram
        return chunkedBytes(packets, sizes: [datagramSize])
    }

    static func packet(
        pid: UInt16,
        payloadUnitStart: Bool,
        continuityCounter: UInt8,
        payload: Data,
        adaptationField: Data? = nil
    ) -> Data {
        precondition(pid <= 0x1FFF)
        let hasAdaptation = adaptationField != nil
        let adaptationLength = adaptationField?.count ?? 0
        let availablePayloadBytes = packetSize - 4 - (hasAdaptation ? 1 + adaptationLength : 0)
        precondition(payload.count <= availablePayloadBytes)

        var packet = Data()
        packet.append(0x47)
        packet.append((payloadUnitStart ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F))
        packet.append(UInt8(pid & 0xFF))
        let adaptationFieldControl: UInt8 = hasAdaptation ? 0x30 : 0x10
        packet.append(adaptationFieldControl | (continuityCounter & 0x0F))
        if let adaptationField {
            packet.append(UInt8(adaptationField.count))
            packet.append(adaptationField)
        }
        packet.append(payload)
        packet.append(contentsOf: repeatElement(UInt8(0xFF), count: packetSize - packet.count))
        precondition(packet.count == packetSize)
        return packet
    }

    static func malformedAdaptationFieldPacket(pid: UInt16 = scte35PID) -> Data {
        var packet = Data(repeating: 0xFF, count: packetSize)
        packet[0] = 0x47
        packet[1] = UInt8((pid >> 8) & 0x1F)
        packet[2] = UInt8(pid & 0xFF)
        packet[3] = 0x30
        packet[4] = 184 // one byte larger than the maximum valid adaptation field in this packet shape
        return packet
    }

    static func patSection(pmtPID: UInt16 = pmtPID) -> Data {
        patSection(programs: [(programNumber: 0x0001, pmtPID: pmtPID)])
    }

    static func patSection(programs: [(programNumber: UInt16, pmtPID: UInt16)]) -> Data {
        var section = Data([
            0x00, 0xB0, 0x00, // patched section_length
            0x00, 0x01,
            0xC1,
            0x00,
            0x00
        ])
        for program in programs {
            section.append(UInt8((program.programNumber >> 8) & 0xFF))
            section.append(UInt8(program.programNumber & 0xFF))
            section.append(0xE0 | UInt8((program.pmtPID >> 8) & 0x1F))
            section.append(UInt8(program.pmtPID & 0xFF))
        }
        section.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        patchSectionLength(in: &section)
        return section
    }

    static func pmtSection(sctePID: UInt16 = scte35PID, streamType: UInt8 = 0x86) -> Data {
        pmtSection(streams: [(streamType: streamType, elementaryPID: sctePID)])
    }

    static func pmtSection(streams: [(streamType: UInt8, elementaryPID: UInt16)]) -> Data {
        let pcrPID = streams.first?.elementaryPID ?? scte35PID
        var section = Data([
            0x02, 0xB0, 0x00, // patched section_length
            0x00, 0x01,
            0xC1,
            0x00,
            0x00,
            0xE0 | UInt8((pcrPID >> 8) & 0x1F), UInt8(pcrPID & 0xFF),
            0xF0, 0x00
        ])
        for stream in streams {
            section.append(stream.streamType)
            section.append(0xE0 | UInt8((stream.elementaryPID >> 8) & 0x1F))
            section.append(UInt8(stream.elementaryPID & 0xFF))
            section.append(0xF0)
            section.append(0x00)
        }
        section.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        patchSectionLength(in: &section)
        return section
    }

    private static func pointerSection(_ section: Data, pointerField: UInt8 = 0) -> Data {
        Data([pointerField]) + section
    }

    private static func patchSectionLength(in section: inout Data) {
        let sectionLength = section.count - 3
        section[1] = 0x30 | UInt8((sectionLength >> 8) & 0x0F)
        section[2] = UInt8(sectionLength & 0xFF)
    }
}
