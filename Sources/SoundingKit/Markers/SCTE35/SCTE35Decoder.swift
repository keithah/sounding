import Foundation

/// Bounded native SCTE-35 `splice_info_section` decoder.
public enum SCTE35Decoder {
    private static let tableID: UInt8 = 0xFC
    private static let fixedHeaderLength = 14
    private static let crcLength = 4
    private static let ptsTimescale = 90_000.0
    private static let ptsMask = (UInt64(1) << 33) - 1

    public static func decode(_ input: SCTE35PayloadInput) throws -> SCTE35Cue {
        try decode(SCTE35Payload(input: input))
    }

    public static func decode(_ payload: SCTE35Payload) throws -> SCTE35Cue {
        let bytes = payload.bytes
        guard bytes.count >= fixedHeaderLength + 2 + crcLength else {
            throw SCTE35DecodeError.malformedSection
        }

        guard bytes[0] == tableID else {
            throw SCTE35DecodeError.malformedSection
        }

        let sectionLength = (Int(bytes[1] & 0x0F) << 8) | Int(bytes[2])
        let sectionEnd = 3 + sectionLength
        guard sectionLength >= fixedHeaderLength + 2 + crcLength - 3,
              sectionEnd == bytes.count else {
            throw SCTE35DecodeError.malformedSection
        }

        guard (bytes[4] & 0x80) == 0 else {
            throw SCTE35DecodeError.encryptedSection
        }

        let ptsAdjustment = (((UInt64(bytes[4]) & 0x01) << 32)
            | (UInt64(bytes[5]) << 24)
            | (UInt64(bytes[6]) << 16)
            | (UInt64(bytes[7]) << 8)
            | UInt64(bytes[8]))
        let tier = UInt16(bytes[10]) << 4 | UInt16(bytes[11] >> 4)
        let spliceCommandLength = (Int(bytes[11] & 0x0F) << 8) | Int(bytes[12])
        let spliceCommandType = bytes[13]
        let commandStart = fixedHeaderLength
        let commandEnd = commandStart + spliceCommandLength

        guard commandEnd <= sectionEnd - 2 - crcLength else {
            throw SCTE35DecodeError.malformedSection
        }

        let descriptorLoopLength = (Int(bytes[commandEnd]) << 8) | Int(bytes[commandEnd + 1])
        let descriptorStart = commandEnd + 2
        let descriptorEnd = descriptorStart + descriptorLoopLength
        guard descriptorEnd == sectionEnd - crcLength else {
            throw SCTE35DecodeError.malformedSection
        }

        let commandBytes = Array(bytes[commandStart..<commandEnd])
        let command = try parseCommand(
            type: spliceCommandType,
            bytes: commandBytes,
            ptsAdjustment: ptsAdjustment
        )
        let descriptors = try parseDescriptors(Array(bytes[descriptorStart..<descriptorEnd]))

        return SCTE35Cue(
            commandName: command.name,
            spliceCommandType: spliceCommandType,
            sectionLength: sectionLength,
            ptsAdjustment: ptsAdjustment,
            tier: tier,
            rawBase64: payload.rawBase64,
            ptsTime: command.ptsTime,
            breakDuration: command.breakDuration,
            spliceEventID: command.spliceEventID,
            outOfNetworkIndicator: command.outOfNetworkIndicator,
            descriptors: descriptors
        )
    }

    private static func parseCommand(
        type: UInt8,
        bytes: [UInt8],
        ptsAdjustment: UInt64
    ) throws -> ParsedCommand {
        switch type {
        case 0x00:
            guard bytes.isEmpty else {
                throw SCTE35DecodeError.malformedSection
            }
            return ParsedCommand(
                name: "Splice Null",
                ptsTime: nil,
                breakDuration: nil,
                spliceEventID: nil,
                outOfNetworkIndicator: nil
            )
        case 0x05:
            return try parseSpliceInsert(bytes: bytes, ptsAdjustment: ptsAdjustment)
        case 0x06:
            return try parseTimeSignal(bytes: bytes, ptsAdjustment: ptsAdjustment)
        default:
            throw SCTE35DecodeError.unsupportedCommand
        }
    }

    private static func parseSpliceInsert(bytes: [UInt8], ptsAdjustment: UInt64) throws -> ParsedCommand {
        var reader = BitReader(bytes: bytes)
        let eventID = UInt32(try reader.readBits(32))
        let cancelIndicator = try reader.readBits(1) == 1
        _ = try reader.readBits(7) // reserved

        guard !cancelIndicator else {
            guard reader.remainingBits == 0 else {
                throw SCTE35DecodeError.malformedSection
            }
            return ParsedCommand(
                name: "Splice Insert",
                ptsTime: nil,
                breakDuration: nil,
                spliceEventID: eventID,
                outOfNetworkIndicator: nil
            )
        }

        let outOfNetworkIndicator = try reader.readBits(1) == 1
        let programSpliceFlag = try reader.readBits(1) == 1
        let durationFlag = try reader.readBits(1) == 1
        let spliceImmediateFlag = try reader.readBits(1) == 1
        _ = try reader.readBits(4) // reserved

        guard programSpliceFlag else {
            throw SCTE35DecodeError.unsupportedCommand
        }

        let ptsTime: Double?
        if spliceImmediateFlag {
            ptsTime = nil
        } else {
            ptsTime = try parseSpliceTime(reader: &reader, ptsAdjustment: ptsAdjustment)
        }

        let breakDuration: Double?
        if durationFlag {
            breakDuration = try parseBreakDuration(reader: &reader)
        } else {
            breakDuration = nil
        }

        _ = try reader.readBits(16) // unique_program_id
        _ = try reader.readBits(8) // avail_num
        _ = try reader.readBits(8) // avails_expected
        guard reader.remainingBits == 0 else {
            throw SCTE35DecodeError.malformedSection
        }

        return ParsedCommand(
            name: "Splice Insert",
            ptsTime: ptsTime,
            breakDuration: breakDuration,
            spliceEventID: eventID,
            outOfNetworkIndicator: outOfNetworkIndicator
        )
    }

    private static func parseTimeSignal(bytes: [UInt8], ptsAdjustment: UInt64) throws -> ParsedCommand {
        var reader = BitReader(bytes: bytes)
        let ptsTime = try parseSpliceTime(reader: &reader, ptsAdjustment: ptsAdjustment)
        guard reader.remainingBits == 0 else {
            throw SCTE35DecodeError.malformedSection
        }
        return ParsedCommand(
            name: "Time Signal",
            ptsTime: ptsTime,
            breakDuration: nil,
            spliceEventID: nil,
            outOfNetworkIndicator: nil
        )
    }

    private static func parseSpliceTime(reader: inout BitReader, ptsAdjustment: UInt64) throws -> Double? {
        let timeSpecified = try reader.readBits(1) == 1
        if timeSpecified {
            _ = try reader.readBits(6) // reserved
            let ptsTime = try reader.readBits(33)
            return seconds(from: (ptsTime + ptsAdjustment) & ptsMask)
        } else {
            _ = try reader.readBits(7) // reserved
            return nil
        }
    }

    private static func parseBreakDuration(reader: inout BitReader) throws -> Double {
        _ = try reader.readBits(1) // auto_return
        _ = try reader.readBits(6) // reserved
        let duration = try reader.readBits(33)
        return seconds(from: duration)
    }

    private static func parseDescriptors(_ bytes: [UInt8]) throws -> [SCTE35Descriptor] {
        var descriptors = [SCTE35Descriptor]()
        var offset = 0
        while offset < bytes.count {
            guard offset + 2 <= bytes.count else {
                throw SCTE35DecodeError.malformedSection
            }
            let tag = bytes[offset]
            let length = Int(bytes[offset + 1])
            let payloadStart = offset + 2
            let payloadEnd = payloadStart + length
            guard payloadEnd <= bytes.count else {
                throw SCTE35DecodeError.malformedSection
            }
            descriptors.append(SCTE35Descriptor(
                tag: tag,
                length: UInt8(length),
                bytes: Array(bytes[payloadStart..<payloadEnd])
            ))
            offset = payloadEnd
        }
        return descriptors
    }

    private static func seconds(from ticks: UInt64) -> Double {
        Double(ticks) / ptsTimescale
    }
}

private struct ParsedCommand {
    let name: String
    let ptsTime: Double?
    let breakDuration: Double?
    let spliceEventID: UInt32?
    let outOfNetworkIndicator: Bool?
}
