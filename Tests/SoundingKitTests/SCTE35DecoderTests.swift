import Foundation
import XCTest
@testable import SoundingKit

final class SCTE35DecoderTests: XCTestCase {
    private let spliceNull = "/DARAAAAAAAAAP/wAAAAAHpPGuQ="
    private let spliceNullHex = "0xFC301100000000000000FFF0000000007A4F1AE4"

    func testSpliceNullDecodesHeaderAndCommandFields() throws {
        let cue = try SCTE35Decoder.decode(.base64(spliceNull))

        XCTAssertEqual(cue.commandName, "Splice Null")
        XCTAssertNil(cue.ptsTime)
        XCTAssertNil(cue.breakDuration)
        XCTAssertNil(cue.spliceEventID)
        XCTAssertNil(cue.outOfNetworkIndicator)
        XCTAssertEqual(cue.descriptors, [])
        XCTAssertEqual(cue.rawBase64, spliceNull)
        XCTAssertEqual(cue.spliceCommandType, 0x00)
        XCTAssertEqual(cue.sectionLength, 17)
    }

    func testSpliceNullHexDecodesToSameCanonicalRawBase64() throws {
        let cue = try SCTE35Decoder.decode(.hex(spliceNullHex))

        XCTAssertEqual(cue.commandName, "Splice Null")
        XCTAssertEqual(cue.rawBase64, spliceNull)
    }

    func testSpliceInsertWithProgramSpliceAndBreakDurationDecodesFixtureCriticalFields() throws {
        let section = makeSpliceInsertSection(
            eventID: 1_207_959_710,
            ptsTicks: 8_100_000,
            breakDurationTicks: 5_426_421
        )

        let cue = try SCTE35Decoder.decode(.data(section))

        XCTAssertEqual(cue.commandName, "Splice Insert")
        XCTAssertEqual(cue.spliceCommandType, 0x05)
        XCTAssertEqual(cue.spliceEventID, 1_207_959_710)
        XCTAssertEqual(cue.outOfNetworkIndicator, true)
        XCTAssertEqual(cue.ptsTime!, 90.0, accuracy: 0.000_001)
        XCTAssertEqual(cue.breakDuration!, 60.293567, accuracy: 0.000_001)
        XCTAssertEqual(cue.descriptors, [])
        XCTAssertEqual(cue.rawBase64, section.base64EncodedString())
    }

    func testDescriptorRecordsAreBoundedByDescriptorLoopLength() throws {
        var section = makeSpliceInsertSection(eventID: 1_207_959_710, ptsTicks: 90_000, breakDurationTicks: 180_000)
        section.insert(contentsOf: [0x02, 0x03, 0xAA, 0xBB, 0xCC], at: section.count - 4)
        patchDescriptorLoopLength(5, in: &section)
        patchSectionLength(in: &section)

        let cue = try SCTE35Decoder.decode(.data(section))

        XCTAssertEqual(cue.descriptors, [SCTE35Descriptor(tag: 0x02, length: 0x03, bytes: [0xAA, 0xBB, 0xCC])])
    }

    func testMalformedSectionsThrowSanitizedErrors() throws {
        let malformedCases: [(String, SCTE35PayloadInput, SCTE35DecodeError, String)] = [
            ("truncated", .data(Data(Data(base64Encoded: spliceNull)!.dropLast())), .malformedSection, spliceNull),
            ("invalid table id", .data(mutateSpliceNull { $0[0] = 0x00 }), .malformedSection, "FC301100"),
            ("command length overrun", .data(mutateSpliceNull { $0[11] = 0x01 }), .malformedSection, "FC301100"),
            ("descriptor loop overrun", .data(mutateSpliceNull { $0[14] = 0x00; $0[15] = 0x01 }), .malformedSection, "FC301100")
        ]

        for (name, input, expectedError, forbiddenLiteral) in malformedCases {
            do {
                _ = try SCTE35Decoder.decode(input)
                XCTFail("Expected \(name) to fail")
            } catch let error as SCTE35DecodeError {
                XCTAssertEqual(error, expectedError, name)
                assertSanitized(error.description, forbiddenLiteral: forbiddenLiteral)
                assertSanitized(error.description, forbiddenLiteral: spliceNull)
            }
        }
    }

    func testUnsupportedAndEncryptedSectionsThrowSanitizedErrors() throws {
        let unsupported = mutateSpliceNull { $0[13] = 0x07 }
        let encrypted = mutateSpliceNull { $0[4] = 0x80 }

        XCTAssertThrowsError(try SCTE35Decoder.decode(.data(unsupported))) { error in
            guard let decodeError = error as? SCTE35DecodeError else {
                return XCTFail("Expected SCTE35DecodeError, got \(error)")
            }
            XCTAssertEqual(decodeError, .unsupportedCommand)
            assertSanitized(decodeError.description, forbiddenLiteral: unsupported.base64EncodedString())
        }

        XCTAssertThrowsError(try SCTE35Decoder.decode(.data(encrypted))) { error in
            guard let decodeError = error as? SCTE35DecodeError else {
                return XCTFail("Expected SCTE35DecodeError, got \(error)")
            }
            XCTAssertEqual(decodeError, .encryptedSection)
            assertSanitized(decodeError.description, forbiddenLiteral: encrypted.base64EncodedString())
        }
    }

    func testWidePtsAndDurationConvertWithoutIntOverflow() throws {
        let max33Bit = (UInt64(1) << 33) - 1
        let section = makeSpliceInsertSection(
            eventID: 1_207_959_710,
            ptsTicks: max33Bit,
            breakDurationTicks: max33Bit
        )

        let cue = try SCTE35Decoder.decode(.data(section))

        XCTAssertEqual(cue.ptsTime!, Double(max33Bit) / 90_000.0, accuracy: 0.000_001)
        XCTAssertEqual(cue.breakDuration!, Double(max33Bit) / 90_000.0, accuracy: 0.000_001)
    }

    private func mutateSpliceNull(_ mutate: (inout Data) -> Void) -> Data {
        var data = Data(base64Encoded: spliceNull)!
        mutate(&data)
        return data
    }

    private func makeSpliceInsertSection(eventID: UInt32, ptsTicks: UInt64, breakDurationTicks: UInt64) -> Data {
        var command = BitWriter()
        command.write(UInt64(eventID), bits: 32)
        command.write(0, bits: 1) // splice_event_cancel_indicator
        command.write(0x7F, bits: 7) // reserved
        command.write(1, bits: 1) // out_of_network_indicator
        command.write(1, bits: 1) // program_splice_flag
        command.write(1, bits: 1) // duration_flag
        command.write(0, bits: 1) // splice_immediate_flag
        command.write(0x0F, bits: 4) // reserved
        command.write(1, bits: 1) // time_specified_flag
        command.write(0x3F, bits: 6) // reserved
        command.write(ptsTicks, bits: 33)
        command.write(1, bits: 1) // auto_return
        command.write(0x3F, bits: 6) // reserved
        command.write(breakDurationTicks, bits: 33)
        command.write(1, bits: 16) // unique_program_id
        command.write(1, bits: 8) // avail_num
        command.write(1, bits: 8) // avails_expected

        let commandBytes = command.bytes()
        var section = Data()
        section.append(0xFC)
        section.append(0x30)
        section.append(0x00) // patched after body is complete
        section.append(0x00) // protocol_version
        section.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00]) // encrypted=false, algorithm=0, pts_adjustment=0
        section.append(0x00) // cw_index
        section.append(0xFF)
        section.append(0xF0 | UInt8((commandBytes.count >> 8) & 0x0F))
        section.append(UInt8(commandBytes.count & 0xFF))
        section.append(0x05) // splice_insert
        section.append(contentsOf: commandBytes)
        section.append(0x00)
        section.append(0x00) // descriptor_loop_length
        section.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // CRC placeholder; parser validates placement only in this slice
        patchSectionLength(in: &section)
        return section
    }

    private func patchDescriptorLoopLength(_ length: Int, in section: inout Data) {
        let descriptorLengthOffset = section.count - 4 - length - 2
        section[descriptorLengthOffset] = UInt8((length >> 8) & 0xFF)
        section[descriptorLengthOffset + 1] = UInt8(length & 0xFF)
    }

    private func patchSectionLength(in section: inout Data) {
        let sectionLength = section.count - 3
        section[1] = 0x30 | UInt8((sectionLength >> 8) & 0x0F)
        section[2] = UInt8(sectionLength & 0xFF)
    }

    private func assertSanitized(_ description: String, forbiddenLiteral: String, file: StaticString = #filePath, line: UInt = #line) {
        guard !forbiddenLiteral.isEmpty else { return }
        XCTAssertFalse(
            description.contains(forbiddenLiteral),
            "Error description leaked forbidden literal: \(description)",
            file: file,
            line: line
        )
    }
}

private struct BitWriter {
    private var storage = [UInt8]()
    private var bitOffset = 0

    mutating func write(_ value: UInt64, bits bitCount: Int) {
        precondition(bitCount >= 0 && bitCount <= 64)
        for shift in stride(from: bitCount - 1, through: 0, by: -1) {
            if bitOffset.isMultiple(of: 8) {
                storage.append(0)
            }
            let bit = UInt8((value >> UInt64(shift)) & 1)
            let byteIndex = bitOffset / 8
            let bitIndex = 7 - (bitOffset % 8)
            storage[byteIndex] |= bit << UInt8(bitIndex)
            bitOffset += 1
        }
    }

    func bytes() -> [UInt8] {
        storage
    }
}
