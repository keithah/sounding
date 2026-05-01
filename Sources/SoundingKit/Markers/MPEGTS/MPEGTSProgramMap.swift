import Foundation

/// Parses MPEG-TS PSI program-map metadata needed to discover SCTE-35 PIDs.
///
/// M001 trusts the bounded PSI section lengths already enforced by
/// `MPEGTSSectionAssembler` and intentionally does not validate CRC values.
/// Returned identifiers come only from PAT table `0x00` PMT entries and PMT
/// table `0x02` elementary streams with SCTE-35 stream type `0x86`.
public enum MPEGTSProgramMap {
    private static let patTableID: UInt8 = 0x00
    private static let pmtTableID: UInt8 = 0x02
    private static let scte35StreamType: UInt8 = 0x86
    private static let crcLength = 4

    public static func pmtPIDs(inPATSection section: Data) throws -> Set<UInt16> {
        let bytes = [UInt8](section)
        guard bytes.first == patTableID else { return [] }
        let sectionEnd = try validatedSectionEnd(in: bytes, minimumHeaderLength: 8)
        let programEnd = sectionEnd - crcLength
        guard programEnd >= 8 else { throw MPEGTSExtractionError.invalidSectionLength }

        var pids = Set<UInt16>()
        var offset = 8
        while offset + 4 <= programEnd {
            let programNumber = readUInt16(bytes, at: offset)
            let pid = readPID(bytes, at: offset + 2)
            if programNumber != 0 {
                pids.insert(pid)
            }
            offset += 4
        }

        guard offset == programEnd else { throw MPEGTSExtractionError.invalidSectionLength }
        return pids
    }

    public static func scte35PIDs(inPMTSection section: Data) throws -> Set<UInt16> {
        let bytes = [UInt8](section)
        guard bytes.first == pmtTableID else { return [] }
        let sectionEnd = try validatedSectionEnd(in: bytes, minimumHeaderLength: 12)
        let streamEnd = sectionEnd - crcLength
        guard streamEnd >= 12 else { throw MPEGTSExtractionError.invalidSectionLength }

        let programInfoLength = (Int(bytes[10] & 0x0F) << 8) | Int(bytes[11])
        var offset = 12 + programInfoLength
        guard offset <= streamEnd else { throw MPEGTSExtractionError.invalidSectionLength }

        var pids = Set<UInt16>()
        while offset + 5 <= streamEnd {
            let streamType = bytes[offset]
            let elementaryPID = readPID(bytes, at: offset + 1)
            let esInfoLength = (Int(bytes[offset + 3] & 0x0F) << 8) | Int(bytes[offset + 4])
            if streamType == scte35StreamType {
                pids.insert(elementaryPID)
            }
            offset += 5 + esInfoLength
            guard offset <= streamEnd else { throw MPEGTSExtractionError.invalidSectionLength }
        }

        guard offset == streamEnd else { throw MPEGTSExtractionError.invalidSectionLength }
        return pids
    }

    private static func validatedSectionEnd(in bytes: [UInt8], minimumHeaderLength: Int) throws -> Int {
        guard bytes.count >= 3 else { throw MPEGTSExtractionError.invalidSectionLength }
        let sectionLength = (Int(bytes[1] & 0x0F) << 8) | Int(bytes[2])
        let sectionEnd = 3 + sectionLength
        guard sectionLength >= crcLength,
              sectionEnd <= bytes.count,
              sectionEnd >= minimumHeaderLength + crcLength else {
            throw MPEGTSExtractionError.invalidSectionLength
        }
        return sectionEnd
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readPID(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset] & 0x1F) << 8) | UInt16(bytes[offset + 1])
    }
}
