import Foundation
import XCTest
@testable import SoundingKit

final class MPEGTSSectionExtractionTests: XCTestCase {
    func testDiscoversSCTE35PIDFromPATAndPMTAndEmitsExactSectionBytes() throws {
        let bytes = MPEGTSFixtureBuilder.transportStream()
        var extractor = MPEGTSSectionExtractor()

        let sections: [Data] = try extractor.feed(bytes)

        XCTAssertEqual(sections, [MPEGTSFixtureBuilder.spliceNullSection])
        let section = try XCTUnwrap(sections.first)
        let cue = try SCTE35Decoder.decodeSection(section)
        XCTAssertEqual(cue.commandName, "Splice Null")
        XCTAssertEqual(cue.rawBase64, MPEGTSFixtureBuilder.spliceNullSection.base64EncodedString())
    }

    func testResynchronizesAfterLeadingGarbageBeforePAT() throws {
        var bytes = Data([0x00, 0x47, 0x12, 0x34, 0xFF, 0x00])
        bytes.append(MPEGTSFixtureBuilder.transportStream())
        var extractor = MPEGTSSectionExtractor()

        let sections: [Data] = try extractor.feed(bytes)

        XCTAssertEqual(sections, [MPEGTSFixtureBuilder.spliceNullSection])
    }

    func testAcceptsArbitraryInputFragmentationAcrossPackets() throws {
        let chunks = MPEGTSFixtureBuilder.chunkedBytes(
            MPEGTSFixtureBuilder.transportStream(),
            sizes: [1, 2, 7, 31, 89]
        )
        var extractor = MPEGTSSectionExtractor()
        var sections = [Data]()

        for chunk in chunks {
            sections.append(contentsOf: try extractor.feed(chunk))
        }

        XCTAssertEqual(sections, [MPEGTSFixtureBuilder.spliceNullSection])
    }

    func testAssemblesSCTE35SectionSplitAcrossMultiplePackets() throws {
        var bytes = Data()
        bytes.append(MPEGTSFixtureBuilder.patPacket())
        bytes.append(MPEGTSFixtureBuilder.pmtPacket())
        for packet in MPEGTSFixtureBuilder.splitSCTE35SectionPackets(firstPayloadByteCount: 5) {
            bytes.append(packet)
        }
        var extractor = MPEGTSSectionExtractor()

        let sections: [Data] = try extractor.feed(bytes)

        XCTAssertEqual(sections, [MPEGTSFixtureBuilder.spliceNullSection])
    }

    func testSkipsValidAdaptationFieldBeforePayload() throws {
        let bytes = MPEGTSFixtureBuilder.transportStream(includeAdaptationField: true)
        var extractor = MPEGTSSectionExtractor()

        let sections: [Data] = try extractor.feed(bytes)

        XCTAssertEqual(sections, [MPEGTSFixtureBuilder.spliceNullSection])
    }

    func testNoPMTMeansNoSCTE35Sections() throws {
        let bytes = MPEGTSFixtureBuilder.transportStream(includePMT: false)
        var extractor = MPEGTSSectionExtractor()

        let sections: [Data] = try extractor.feed(bytes)

        XCTAssertTrue(sections.isEmpty)
    }

    func testPMTWithoutSCTE35StreamMeansNoSections() throws {
        var bytes = Data()
        bytes.append(MPEGTSFixtureBuilder.patPacket())
        bytes.append(MPEGTSFixtureBuilder.pmtPacket(streamType: 0x1B))
        bytes.append(MPEGTSFixtureBuilder.scte35Packet())
        var extractor = MPEGTSSectionExtractor()

        let sections: [Data] = try extractor.feed(bytes)

        XCTAssertTrue(sections.isEmpty)
    }

    func testProgramMapParsesAllPATProgramsAndAllSCTE35Streams() throws {
        let pmtPIDs = try MPEGTSProgramMap.pmtPIDs(inPATSection: MPEGTSFixtureBuilder.patSection(programs: [
            (programNumber: 0x0000, pmtPID: 0x0010),
            (programNumber: 0x0001, pmtPID: 0x0100),
            (programNumber: 0x0002, pmtPID: 0x0103)
        ]))
        let sctePIDs = try MPEGTSProgramMap.scte35PIDs(inPMTSection: MPEGTSFixtureBuilder.pmtSection(streams: [
            (streamType: 0x1B, elementaryPID: 0x0101),
            (streamType: 0x86, elementaryPID: 0x0102),
            (streamType: 0x86, elementaryPID: 0x0104)
        ]))

        XCTAssertEqual(pmtPIDs, [0x0100, 0x0103])
        XCTAssertEqual(sctePIDs, [0x0102, 0x0104])
    }

    func testMultipleSCTE35PIDsDiscoveredFromPMTAreEligible() throws {
        var bytes = Data()
        bytes.append(MPEGTSFixtureBuilder.patPacket())
        bytes.append(MPEGTSFixtureBuilder.pmtPacket(streams: [
            (streamType: 0x86, elementaryPID: MPEGTSFixtureBuilder.scte35PID),
            (streamType: 0x86, elementaryPID: MPEGTSFixtureBuilder.ignoredPID)
        ]))
        bytes.append(MPEGTSFixtureBuilder.scte35Packet(pid: MPEGTSFixtureBuilder.scte35PID))
        bytes.append(MPEGTSFixtureBuilder.scte35Packet(pid: MPEGTSFixtureBuilder.ignoredPID, continuityCounter: 1))
        var extractor = MPEGTSSectionExtractor()

        let sections: [Data] = try extractor.feed(bytes)

        XCTAssertEqual(sections, [MPEGTSFixtureBuilder.spliceNullSection, MPEGTSFixtureBuilder.spliceNullSection])
    }

    func testMalformedProgramMapSectionsThrowSanitizedIngestErrors() throws {
        let malformedPAT = Data([0x00, 0xB0, 0x0D, 0x00])
        let malformedPMT = Data([0x02, 0xB0, 0x12, 0x00])

        XCTAssertThrowsError(try MPEGTSProgramMap.pmtPIDs(inPATSection: malformedPAT)) { error in
            XCTAssertTrue(String(describing: error).contains("ingest"), "Expected ingest context, got \(error)")
            XCTAssertFalse(String(describing: error).contains(malformedPAT.base64EncodedString()))
        }
        XCTAssertThrowsError(try MPEGTSProgramMap.scte35PIDs(inPMTSection: malformedPMT)) { error in
            XCTAssertTrue(String(describing: error).contains("ingest"), "Expected ingest context, got \(error)")
            XCTAssertFalse(String(describing: error).contains(malformedPMT.base64EncodedString()))
        }
    }

    func testSCTELookingSectionOnUndiscoveredPIDIsIgnored() throws {
        var bytes = Data()
        bytes.append(MPEGTSFixtureBuilder.patPacket())
        bytes.append(MPEGTSFixtureBuilder.pmtPacket(sctePID: MPEGTSFixtureBuilder.scte35PID))
        bytes.append(MPEGTSFixtureBuilder.scte35Packet(pid: MPEGTSFixtureBuilder.ignoredPID))
        var extractor = MPEGTSSectionExtractor()

        let sections: [Data] = try extractor.feed(bytes)

        XCTAssertTrue(sections.isEmpty)
    }

    func testTruncatedPacketIsBufferedUntilCompletion() throws {
        let bytes = MPEGTSFixtureBuilder.transportStream()
        let splitOffset = bytes.count - 17
        var extractor = MPEGTSSectionExtractor()

        let firstSections: [Data] = try extractor.feed(bytes.prefix(splitOffset))
        let finalSections: [Data] = try extractor.feed(bytes.dropFirst(splitOffset))

        XCTAssertTrue(firstSections.isEmpty)
        XCTAssertEqual(finalSections, [MPEGTSFixtureBuilder.spliceNullSection])
    }

    func testMalformedAdaptationFieldThrowsIngestErrorWithoutPacketBytes() throws {
        var extractor = MPEGTSSectionExtractor()
        let malformed = MPEGTSFixtureBuilder.malformedAdaptationFieldPacket()

        XCTAssertThrowsError(try extractor.feed(malformed)) { error in
            XCTAssertTrue(String(describing: error).contains("ingest"), "Expected ingest context, got \(error)")
            XCTAssertFalse(String(describing: error).contains(malformed.base64EncodedString()))
        }
    }

    func testIncompleteFinalSectionDoesNotEmitBytes() throws {
        var bytes = Data()
        bytes.append(MPEGTSFixtureBuilder.patPacket())
        bytes.append(MPEGTSFixtureBuilder.pmtPacket())
        bytes.append(MPEGTSFixtureBuilder.splitSCTE35SectionPackets(firstPayloadByteCount: 5)[0])
        var extractor = MPEGTSSectionExtractor()

        let sections: [Data] = try extractor.feed(bytes)

        XCTAssertTrue(sections.isEmpty)
    }

    func testTrackedFixtureLoadsAndContainsTheDeterministicTransportStream() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/MPEGTS/scte35_splice_null.ts")
        let fixtureBytes = try Data(contentsOf: fixtureURL)
        var extractor = MPEGTSSectionExtractor()

        let sections: [Data] = try extractor.feed(fixtureBytes)

        XCTAssertEqual(fixtureBytes.count, MPEGTSFixtureBuilder.packetSize * 3)
        XCTAssertEqual(sections, [MPEGTSFixtureBuilder.spliceNullSection])
    }
}
