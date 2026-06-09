import Foundation
import XCTest
@testable import SoundingKit

final class SCTE35FixtureTests: XCTestCase {
    private let sourceWithSecrets = "https://user:pass@example.test/live/manifest.m3u8?token=secret#frag"

    func testBase64HexAndBinaryFacadeDecodeEquivalentFixtureMarkerSemantics() throws {
        let section = makeSpliceInsertSection(
            eventID: 0x4800009E,
            ptsTicks: 8_100_000,
            breakDurationTicks: 5_426_421,
            descriptors: makeSegmentationDescriptor(
                eventID: 0x01020304,
                durationTicks: 2_700_000,
                upidType: 0x0C,
                upid: Array("asset-42".utf8),
                segmentationTypeID: 0x34,
                segmentNumber: 1,
                segmentsExpected: 2
            )
        )
        let base64 = section.base64EncodedString()
        let hex = Self.hexString(for: section)

        let base64Marker = try SCTE35Decoder.decodeMarker(
            .base64(base64),
            source: "hls://fixture",
            tag: "#EXT-OATCLS-SCTE35",
            segment: "seg-1.ts",
            timestamp: "2026-04-30T08:00:00Z"
        )
        let hexMarker = try SCTE35Decoder.decodeMarker(.hex(hex), source: "hls://fixture")
        let binaryMarker = try SCTE35Decoder.decodeMarker(.data(section), source: "udp://stream.example.test")
        let binaryCue = try SCTE35Decoder.decodeSection(section)

        XCTAssertEqual(binaryCue.commandName, "Splice Insert")
        XCTAssertEqual(binaryCue.spliceEventID, 0x4800009E)
        XCTAssertEqual(binaryCue.breakDuration!, 60.293567, accuracy: 0.000_001)
        XCTAssertEqual(binaryCue.rawBase64, base64)
        XCTAssertEqual(binaryCue.descriptors.count, 1)

        XCTAssertEqual(base64Marker.type, "SCTE35")
        XCTAssertEqual(base64Marker.source, "hls://fixture")
        XCTAssertEqual(base64Marker.tag, "#EXT-OATCLS-SCTE35")
        XCTAssertEqual(base64Marker.segment, "seg-1.ts")
        XCTAssertEqual(base64Marker.timestamp, "2026-04-30T08:00:00Z")
        XCTAssertEqual(base64Marker.rawBase64, base64)
        XCTAssertEqual(base64Marker.pts!, 90.0, accuracy: 0.000_001)
        XCTAssertEqual(base64Marker.breakDuration!, 60.293567, accuracy: 0.000_001)
        XCTAssertEqual(base64Marker.fields["CommandName"], "SPLICE_INSERT_OON_TRUE")
        XCTAssertEqual(base64Marker.fields["BreakDuration"], "60.294")
        XCTAssertEqual(base64Marker.fields["SpliceEventID"], "0x4800009e")
        XCTAssertEqual(base64Marker.fields["SegmentationEventID"], "0x01020304")
        XCTAssertEqual(base64Marker.fields["SegmentationTypeID"], "0x34")
        XCTAssertEqual(base64Marker.fields["SegmentationUPID"], "asset-42")
        let expectedCommand: JSONValue = [
            "Name": "Splice Insert",
            "Type": "0x05",
            "SpliceEventID": "0x4800009e",
            "OutOfNetworkIndicator": true,
            "PTS": 90.0,
            "BreakDuration": 60.293567
        ]
        XCTAssertEqual(base64Marker.command, expectedCommand)
        let descriptor = try XCTUnwrap(base64Marker.descriptors.first)
        let expectedDescriptor: JSONValue = [
            "Tag": "SegmentationDescriptor",
            "DescriptorTag": "0x02",
            "Identifier": "CUEI",
            "SegmentationEventID": "0x01020304",
            "SegmentationEventCancelIndicator": false,
            "ProgramSegmentationFlag": true,
            "SegmentationDurationFlag": true,
            "DeliveryNotRestrictedFlag": true,
            "SegmentationDuration": 30.0,
            "SegmentationUPIDType": "0x0c",
            "SegmentationUPID": "asset-42",
            "SegmentationTypeID": "0x34",
            "SegmentationTypeName": "Provider placement opportunity start",
            "SegmentNumber": 1,
            "SegmentsExpected": 2
        ]
        XCTAssertEqual(descriptor, expectedDescriptor)

        XCTAssertEqual(hexMarker.rawBase64, base64Marker.rawBase64)
        XCTAssertEqual(hexMarker.command, base64Marker.command)
        XCTAssertEqual(hexMarker.descriptors, base64Marker.descriptors)
        XCTAssertEqual(hexMarker.fields, base64Marker.fields)
        XCTAssertEqual(binaryMarker.rawBase64, base64Marker.rawBase64)
        XCTAssertEqual(binaryMarker.command, base64Marker.command)
        XCTAssertEqual(binaryMarker.descriptors, base64Marker.descriptors)
        XCTAssertEqual(binaryMarker.fields, base64Marker.fields)
    }

    func testFacadeErrorsAreSanitizedForMalformedStringPayloadsAndSecretSources() throws {
        let rawPayload = "not-base64://user:pass@example.test/path?token=secret#frag"

        XCTAssertThrowsError(try SCTE35Decoder.decodeMarker(.base64(rawPayload), source: sourceWithSecrets)) { error in
            guard let decodeError = error as? SCTE35DecodeError else {
                return XCTFail("Expected SCTE35DecodeError, got \(error)")
            }
            XCTAssertEqual(decodeError, .invalidBase64)
            assertSanitized(decodeError.description, forbiddenLiteral: rawPayload)
            assertSanitized(decodeError.description, forbiddenLiteral: sourceWithSecrets)
            assertSanitized(decodeError.description, forbiddenLiteral: "user:pass")
            assertSanitized(decodeError.description, forbiddenLiteral: "token=secret")
            assertSanitized(decodeError.description, forbiddenLiteral: "#frag")
        }
    }

    func testDecodeSectionRejectsTruncatedBinaryWithoutPayloadLeakage() throws {
        let section = makeSpliceInsertSection(eventID: 0x4800009E, ptsTicks: 8_100_000, breakDurationTicks: 5_426_421)
        let truncated = Data(section.dropLast())

        XCTAssertThrowsError(try SCTE35Decoder.decodeSection(truncated)) { error in
            guard let decodeError = error as? SCTE35DecodeError else {
                return XCTFail("Expected SCTE35DecodeError, got \(error)")
            }
            XCTAssertEqual(decodeError, .malformedSection)
            assertSanitized(decodeError.description, forbiddenLiteral: truncated.base64EncodedString())
            assertSanitized(decodeError.description, forbiddenLiteral: Self.hexString(for: truncated))
        }
    }

    private func makeSpliceInsertSection(
        eventID: UInt32,
        ptsTicks: UInt64,
        breakDurationTicks: UInt64,
        descriptors: [UInt8] = []
    ) -> Data {
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
        return makeSection(commandType: 0x05, commandBytes: command.bytes(), descriptors: descriptors)
    }

    private func makeSection(commandType: UInt8, commandBytes: [UInt8], descriptors: [UInt8]) -> Data {
        var section = Data()
        section.append(0xFC)
        section.append(0x30)
        section.append(0x00) // patched after body is complete
        section.append(0x00) // protocol_version
        section.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00])
        section.append(0x00) // cw_index
        section.append(0xFF)
        section.append(0xF0 | UInt8((commandBytes.count >> 8) & 0x0F))
        section.append(UInt8(commandBytes.count & 0xFF))
        section.append(commandType)
        section.append(contentsOf: commandBytes)
        section.append(UInt8((descriptors.count >> 8) & 0xFF))
        section.append(UInt8(descriptors.count & 0xFF))
        section.append(contentsOf: descriptors)
        section.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        patchSectionLength(in: &section)
        return section
    }

    private func makeSegmentationDescriptor(
        eventID: UInt32,
        durationTicks: UInt64,
        upidType: UInt8,
        upid: [UInt8],
        segmentationTypeID: UInt8,
        segmentNumber: UInt8,
        segmentsExpected: UInt8
    ) -> [UInt8] {
        var descriptor = [UInt8]()
        descriptor.append(0x02)
        descriptor.append(0x00) // patched length
        descriptor.append(contentsOf: Array("CUEI".utf8))
        descriptor.append(UInt8((eventID >> 24) & 0xFF))
        descriptor.append(UInt8((eventID >> 16) & 0xFF))
        descriptor.append(UInt8((eventID >> 8) & 0xFF))
        descriptor.append(UInt8(eventID & 0xFF))
        descriptor.append(0x7F) // cancel=false, reserved
        descriptor.append(0xE0) // program=true, duration=true, delivery_not_restricted=true, reserved
        descriptor.append(UInt8((durationTicks >> 32) & 0xFF))
        descriptor.append(UInt8((durationTicks >> 24) & 0xFF))
        descriptor.append(UInt8((durationTicks >> 16) & 0xFF))
        descriptor.append(UInt8((durationTicks >> 8) & 0xFF))
        descriptor.append(UInt8(durationTicks & 0xFF))
        descriptor.append(upidType)
        descriptor.append(UInt8(upid.count))
        descriptor.append(contentsOf: upid)
        descriptor.append(segmentationTypeID)
        descriptor.append(segmentNumber)
        descriptor.append(segmentsExpected)
        descriptor[1] = UInt8(descriptor.count - 2)
        return descriptor
    }

    private func patchSectionLength(in section: inout Data) {
        let sectionLength = section.count - 3
        section[1] = 0x30 | UInt8((sectionLength >> 8) & 0x0F)
        section[2] = UInt8(sectionLength & 0xFF)
    }

    private static func hexString(for data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
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
