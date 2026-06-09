import Foundation
import XCTest
@testable import SoundingKit

final class HLSManifestMarkerTests: XCTestCase {
    private let sourceWithSecrets = "https://user:pass@example.test/live/manifest.m3u8?token=secret#frag"

    func testBinaryManifestTagAttachesToMediaSequenceSegment() throws {
        let section = makeSpliceInsertSection(eventID: 0x4800009E, ptsTicks: 8_100_000, breakDurationTicks: 5_426_421)
        let manifest = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:7
        #EXT-OATCLS-SCTE35:\(section.base64EncodedString())
        #EXTINF:6.0,
        segment7.ts
        """

        let records = HLSManifestParser.parseMediaSegments(manifest)
        let markers = try HLSManifestMarkerExtractor.extractMarkers(from: records, source: "file:///tmp/fixture.m3u8")

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].uri, "segment7.ts")
        XCTAssertEqual(records[0].mediaSequence, "7")
        XCTAssertEqual(markers.count, 1)
        let marker = try XCTUnwrap(markers.first)
        XCTAssertEqual(marker.type, "SCTE35")
        XCTAssertEqual(marker.source, "hls_manifest")
        XCTAssertEqual(marker.tag, "#EXT-OATCLS-SCTE35")
        XCTAssertEqual(marker.segment, "7")
        XCTAssertEqual(marker.rawBase64, section.base64EncodedString())
        XCTAssertEqual(marker.fields["CommandName"], "SPLICE_INSERT_OON_TRUE")
        XCTAssertEqual(marker.tags["ManifestSource"], .string("file:///tmp/fixture.m3u8"))
        XCTAssertEqual(marker.tags["SegmentURI"], .string("segment7.ts"))
    }

    func testMultiplePendingTagsAttachToOneSegmentAndResetBeforeNextSegment() throws {
        let section = makeSpliceInsertSection(eventID: 0x4800009E, ptsTicks: 8_100_000, breakDurationTicks: 5_426_421)
        let manifest = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:10
        #EXT-X-CUE-OUT:30.0
        #EXT-OATCLS-SCTE35:\(section.base64EncodedString())
        #EXTINF:6.0,
        first.ts
        #EXTINF:6.0,
        second.ts
        """

        let records = HLSManifestParser.parseMediaSegments(manifest)
        let markers = try HLSManifestMarkerExtractor.extractMarkers(from: records, source: "fixture.m3u8")

        XCTAssertEqual(records.map(\.mediaSequence), ["10", "11"])
        XCTAssertEqual(records[0].scte35Tags.count, 2)
        XCTAssertEqual(records[1].scte35Tags.count, 0)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers.map(\.segment), ["10", "10"])
        XCTAssertEqual(markers[0].tag, "#EXT-X-CUE-OUT")
        XCTAssertNil(markers[0].rawBase64)
        XCTAssertEqual(markers[1].tag, "#EXT-OATCLS-SCTE35")
        XCTAssertNotNil(markers[1].rawBase64)
    }

    func testOrphanPendingTagsAreIgnoredWithoutMediaSegment() throws {
        let manifest = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:7
        #EXT-X-CUE-IN
        """

        let records = HLSManifestParser.parseMediaSegments(manifest)
        let markers = try HLSManifestMarkerExtractor.extractMarkers(from: records, source: "fixture.m3u8")

        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(markers.isEmpty)
    }

    func testMalformedAndNegativeMediaSequenceNormalizeToZero() {
        let malformed = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:not-a-number
        #EXT-X-CUE-IN
        malformed.ts
        """
        let negative = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:-3
        #EXT-X-CUE-IN
        negative.ts
        """

        XCTAssertEqual(HLSManifestParser.parseMediaSegments(malformed).map(\.mediaSequence), ["0"])
        XCTAssertEqual(HLSManifestParser.parseMediaSegments(negative).map(\.mediaSequence), ["0"])
    }

    func testDirectCueTagsEmitClassifiedManifestMarkersWithDisplayFields() throws {
        let manifest = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:7
        #EXT-X-CUE-OUT:DURATION=30.0,ID="break-7"
        #EXT-X-CUE-IN
        segment7.ts
        """

        let markers = try HLSManifestMarkerExtractor.extractMarkers(
            from: HLSManifestParser.parseMediaSegments(manifest),
            source: "fixture.m3u8"
        )

        XCTAssertEqual(markers.count, 2)
        XCTAssertTrue(markers.allSatisfy { $0.type == "SCTE35" })
        XCTAssertEqual(markers.map(\.classification), [.adStart, .adEnd])
        XCTAssertTrue(markers.allSatisfy { $0.source == "hls_manifest" })
        XCTAssertTrue(markers.allSatisfy { $0.rawBase64 == nil })
        XCTAssertEqual(markers[0].fields["cue"], .string("out"))
        XCTAssertEqual(markers[0].fields["Title"], .string("Ad break start"))
        XCTAssertEqual(markers[0].fields["Series"], .string("Duration 30.0s"))
        XCTAssertEqual(markers[0].fields["DURATION"], .string("30.0"))
        XCTAssertEqual(markers[0].fields["ID"], .string("break-7"))
        XCTAssertEqual(markers[1].fields["cue"], .string("in"))
        XCTAssertEqual(markers[1].fields["Title"], .string("Ad break end"))
        XCTAssertEqual(markers[0].tags["SegmentURI"], .string("segment7.ts"))
        XCTAssertEqual(markers[0].segment, "7")
    }

    func testMalformedBinaryPayloadThrowsRedactedDecodePhaseMonitorError() throws {
        let rawPayload = "not-base64://user:pass@example.test/path?token=secret#frag"
        let manifest = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:7
        #EXT-OATCLS-SCTE35:\(rawPayload)
        segment7.ts
        """

        XCTAssertThrowsError(try HLSManifestMarkerExtractor.extractMarkers(
            from: HLSManifestParser.parseMediaSegments(manifest),
            source: sourceWithSecrets
        )) { error in
            guard let monitorError = error as? MonitorError else {
                return XCTFail("Expected MonitorError, got \(error)")
            }

            let description = monitorError.description
            XCTAssertTrue(description.contains("decode"), description)
            XCTAssertTrue(description.contains("hls"), description)
            XCTAssertTrue(description.contains("https://example.test/live/manifest.m3u8"), description)
            XCTAssertTrue(description.contains("hls_manifest"), description)
            XCTAssertTrue(description.contains("#EXT-OATCLS-SCTE35"), description)
            XCTAssertTrue(description.contains("mediaSequence=7"), description)
            assertSanitized(description, forbiddenLiteral: rawPayload)
            assertSanitized(description, forbiddenLiteral: sourceWithSecrets)
            assertSanitized(description, forbiddenLiteral: "user:pass")
            assertSanitized(description, forbiddenLiteral: "token=secret")
            assertSanitized(description, forbiddenLiteral: "#frag")
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
        section.append(0x00)
        section.append(0x00)
        section.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00])
        section.append(0x00)
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
