import Foundation
import XCTest
@testable import SoundingKit

final class UDPDatagramReplayTests: XCTestCase {
    func testRawMPEGTSChunksAndDatagramReplayEmitEquivalentSections() throws {
        let bytes = MPEGTSFixtureBuilder.transportStream()
        let rawChunks = MPEGTSFixtureBuilder.chunkedBytes(bytes, sizes: [17, 131, 503])
        let datagrams = MPEGTSFixtureBuilder.datagrams(from: bytes)
        var rawExtractor = MPEGTSSectionExtractor()

        let rawSections: [Data] = try rawChunks.flatMap { try rawExtractor.feed($0) }
        let replaySections: [Data] = try UDPDatagramReplay.extractSections(from: datagrams)

        XCTAssertEqual(rawSections, [MPEGTSFixtureBuilder.spliceNullSection])
        XCTAssertEqual(replaySections, rawSections)
    }

    func testDatagramReplayPreservesSplitPacketBoundariesAcrossDatagrams() throws {
        let bytes = MPEGTSFixtureBuilder.transportStream()
        let splitDatagrams = MPEGTSFixtureBuilder.chunkedBytes(bytes, sizes: [100, 88, 188, 47, 141])

        let sections: [Data] = try UDPDatagramReplay.extractSections(from: splitDatagrams)

        XCTAssertEqual(sections, [MPEGTSFixtureBuilder.spliceNullSection])
    }

    func test1316ByteStyleDatagramCanCarryTheFixtureStream() throws {
        var bytes = MPEGTSFixtureBuilder.transportStream()
        bytes.append(Data(repeating: 0xFF, count: MPEGTSFixtureBuilder.packetSize * 4))
        let datagrams = MPEGTSFixtureBuilder.datagrams(from: bytes)

        let sections: [Data] = try UDPDatagramReplay.extractSections(from: datagrams)

        XCTAssertEqual(datagrams.map(\.count), [MPEGTSFixtureBuilder.packetSize * MPEGTSFixtureBuilder.datagramPacketCount])
        XCTAssertEqual(sections, [MPEGTSFixtureBuilder.spliceNullSection])
    }

    func testEmptyDatagramArrayEmitsNoSections() throws {
        let sections: [Data] = try UDPDatagramReplay.extractSections(from: [])

        XCTAssertTrue(sections.isEmpty)
    }

    func testIncompleteFinalDatagramDoesNotEmitPartialSection() throws {
        var bytes = Data()
        bytes.append(MPEGTSFixtureBuilder.patPacket())
        bytes.append(MPEGTSFixtureBuilder.pmtPacket())
        bytes.append(MPEGTSFixtureBuilder.splitSCTE35SectionPackets(firstPayloadByteCount: 5)[0])
        let datagrams = MPEGTSFixtureBuilder.chunkedBytes(bytes, sizes: [188, 31])

        let sections: [Data] = try UDPDatagramReplay.extractSections(from: datagrams)

        XCTAssertTrue(sections.isEmpty)
    }

    func testMalformedDatagramThrowsIngestErrorWithoutDatagramContents() throws {
        let malformed = Data([0x47, 0x40, 0x00])

        XCTAssertThrowsError(try UDPDatagramReplay.extractSections(from: [malformed])) { error in
            XCTAssertTrue(String(describing: error).contains("ingest"), "Expected ingest context, got \(error)")
            XCTAssertFalse(String(describing: error).contains(malformed.base64EncodedString()))
        }
    }
}
