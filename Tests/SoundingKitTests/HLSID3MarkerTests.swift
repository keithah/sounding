import Foundation
import XCTest
@testable import SoundingKit

final class HLSID3MarkerTests: XCTestCase {
    private let sourceWithSecrets = "https://user:pass@example.test/live/manifest-id3.m3u8?token=secret#frag"

    func testAdapterEmitsID3MarkersFromSegmentBytesWithSafeContext() async throws {
        let fixtureURL = hlsFixtureURL(named: "manifest-id3.m3u8")
        let manifest = try String(contentsOf: fixtureURL, encoding: .utf8)
        let segmentData = try Data(contentsOf: fixtureURL.deletingLastPathComponent().appendingPathComponent("segments/id3-segment.aac"))
        let adapter = HLSMonitorAdapter(
            manifestSource: fixtureURL.path,
            manifestText: manifest,
            segmentLoader: StubSegmentLoader(data: segmentData),
            segmentExtractor: HLSSegmentSCTE35Extractor()
        )

        let markers = try await adapter.markers()
        let id3Marker = try XCTUnwrap(markers.first { $0.type == "ID3" })

        XCTAssertEqual(markers.filter { $0.type == "ID3" }.count, 1)
        XCTAssertEqual(id3Marker.source, "hls_segment")
        XCTAssertEqual(id3Marker.segment, "42")
        XCTAssertEqual(id3Marker.tag, "ID3")
        XCTAssertEqual(id3Marker.tags["TIT2"], "Primary Cue")
        XCTAssertEqual(id3Marker.tags["TIT3"], "Subtitle Cue")
        XCTAssertEqual(id3Marker.tags["TXXX:TIDEMARK"], "AD|START")
        XCTAssertEqual(id3Marker.fields["FrameIDs"], ["PRIV", "TIT2", "TIT3", "TXXX"])
        XCTAssertEqual(id3Marker.fields["TimestampTicks"], 180_000)
        XCTAssertEqual(id3Marker.fields["TimestampSeconds"], 2.0)
        XCTAssertEqual(id3Marker.fields["MediaSequence"], "42")
        XCTAssertEqual(id3Marker.fields["SourceClass"], "hls_segment")
        XCTAssertEqual(id3Marker.fields["SegmentURI"], "segments/id3-segment.aac")
        XCTAssertEqual(try XCTUnwrap(id3Marker.pts), 2.0, accuracy: 0.000_001)
        XCTAssertNil(id3Marker.rawBase64)
    }

    func testPipelineFilterID3KeepsID3MarkersAndExcludesSCTE35Markers() async throws {
        let options = try MonitorOptions(
            source: hlsFixtureURL(named: "manifest-id3.m3u8").path,
            streamType: .hls,
            filter: "id3",
            quiet: true,
            emitJSON: true
        )

        let markers = try await MonitorPipeline.run(options: options)

        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.map(\.type), ["ID3"])
        XCTAssertEqual(markers.first?.source, "hls_segment")
        XCTAssertEqual(markers.first?.segment, "42")
    }

    func testPipelineClassifiesHLSID3FixtureBeforeAdStartFiltering() async throws {
        let options = try MonitorOptions(
            source: hlsFixtureURL(named: "manifest-id3.m3u8").path,
            streamType: .hls,
            filter: "ad_start",
            quiet: true,
            emitJSON: true
        )

        let markers = try await MonitorPipeline.run(options: options)

        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.type, "ID3")
        XCTAssertEqual(markers.first?.source, "hls_segment")
        XCTAssertEqual(markers.first?.segment, "42")
        XCTAssertEqual(markers.first?.classification, .adStart)
    }

    func testNoID3SegmentBytesReturnNoID3Markers() throws {
        let extractor = HLSSegmentID3Extractor()

        let markers = try extractor.extractMarkers(
            from: Data(repeating: 0x00, count: 188),
            mediaSequence: "42",
            segmentURI: "segments/no-id3.aac"
        )

        XCTAssertEqual(markers, [])
    }

    func testSegmentID3ExtractorSkipsFalseID3MagicBeforeValidTag() throws {
        let extractor = HLSSegmentID3Extractor()
        let falseMagic = Data([0x47, 0x40, 0x00, 0x10]) + Data("ID3 ".utf8)
            + Data([0xFF, 0x00, 0x01])
        let validTag = makeID3Tag(frames:
            makeFrame(id: "TXXX", payload: textPayload(encoding: 3, "TIDEMARK", "AD|START"), versionMajor: 4)
        )

        let markers = try extractor.extractMarkers(
            from: falseMagic + validTag,
            mediaSequence: "43",
            segmentURI: "segments/false-id3.ts"
        )

        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].tags["TXXX:TIDEMARK"], "AD|START")
        XCTAssertEqual(markers[0].fields["MediaSequence"], "43")
    }

    func testSegmentID3ExtractorDemuxesMPEGTSTimedID3Payloads() throws {
        let extractor = HLSSegmentID3Extractor()
        let tag = makeID3Tag(frames:
            makeFrame(id: "TIT2", payload: textPayload(encoding: 3, "Wire Title"), versionMajor: 4)
                + makeFrame(id: "TPE1", payload: textPayload(encoding: 3, "Wire Artist"), versionMajor: 4)
        )
        let segment = makeTimedID3TransportStream(id3Payload: tag, ptsSeconds: 124.0)

        let markers = try extractor.extractMarkers(
            from: segment,
            mediaSequence: "517",
            segmentURI: "segments/timed-id3.ts"
        )

        let marker = try XCTUnwrap(markers.first)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(marker.tags["TIT2"], "Wire Title")
        XCTAssertEqual(marker.tags["TPE1"], "Wire Artist")
        XCTAssertEqual(try XCTUnwrap(marker.pts), 124.0, accuracy: 0.000_001)
        XCTAssertEqual(marker.fields["PESTimestampSeconds"], 124.0)
        XCTAssertEqual(marker.fields["MPEGTSMetadataPID"], 35.0)
        XCTAssertEqual(marker.fields["SourceClass"], "hls_timed_id3")
        XCTAssertEqual(marker.fields["MediaSequence"], "517")
        XCTAssertEqual(marker.fields["SegmentURI"], "segments/timed-id3.ts")
    }

    func testMalformedID3SegmentFailureWrapsAsDecodeMonitorErrorWithRedactedContext() async throws {
        let manifest = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:42
        #EXTINF:6.0,
        https://user:pass@example.test/segments/id3-segment.aac?token=secret#frag
        """
        let malformedPrivateLiteral = "PRIVATE-SECRET-PAYLOAD"
        let malformedTag = Data([0x49, 0x44, 0x33, 0x04]) + Data(malformedPrivateLiteral.utf8)
        let adapter = HLSMonitorAdapter(
            manifestSource: sourceWithSecrets,
            manifestText: manifest,
            segmentLoader: StubSegmentLoader(data: malformedTag),
            segmentExtractor: HLSSegmentSCTE35Extractor()
        )

        do {
            _ = try await adapter.markers()
            XCTFail("Expected decode MonitorError")
        } catch let error as MonitorError {
            let description = error.description
            XCTAssertTrue(description.contains("decode"), description)
            XCTAssertTrue(description.contains("hls"), description)
            XCTAssertTrue(description.contains("sourceClass=hls_segment"), description)
            XCTAssertTrue(description.contains("tag=ID3"), description)
            XCTAssertTrue(description.contains("mediaSequence=42"), description)
            XCTAssertTrue(description.contains("https://example.test/segments/id3-segment.aac"), description)
            assertSanitized(description, forbiddenLiteral: sourceWithSecrets)
            assertSanitized(description, forbiddenLiteral: "user:pass")
            assertSanitized(description, forbiddenLiteral: "token=secret")
            assertSanitized(description, forbiddenLiteral: "#frag")
            assertSanitized(description, forbiddenLiteral: malformedPrivateLiteral)
            assertSanitized(description, forbiddenLiteral: malformedTag.map { String(format: "%02x", $0) }.joined())
            assertSanitized(description, forbiddenLiteral: malformedTag.base64EncodedString())
        } catch {
            XCTFail("Expected MonitorError, got \(error)")
        }
    }

    private func hlsFixtureURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HLS")
            .appendingPathComponent(name)
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

private func makeID3Tag(frames: Data, versionMajor: UInt8 = 4) -> Data {
    Data([0x49, 0x44, 0x33, versionMajor, 0x00, 0x00])
        + synchsafe(frames.count)
        + frames
}

private func makeFrame(id: String, payload: Data, versionMajor: UInt8) -> Data {
    Data(id.utf8)
        + (versionMajor == 4 ? synchsafe(payload.count) : bigEndian(payload.count))
        + Data([0x00, 0x00])
        + payload
}

private func textPayload(encoding: UInt8, _ values: String...) -> Data {
    Data([encoding]) + values.joined(separator: "\0").data(using: .utf8)!
}

private func synchsafe(_ value: Int) -> Data {
    Data([
        UInt8((value >> 21) & 0x7F),
        UInt8((value >> 14) & 0x7F),
        UInt8((value >> 7) & 0x7F),
        UInt8(value & 0x7F)
    ])
}

private func bigEndian(_ value: Int) -> Data {
    Data([
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ])
}

private func makeTimedID3TransportStream(id3Payload: Data, ptsSeconds: Double) -> Data {
    let metadataPID: UInt16 = 0x0023
    var data = Data()
    data.append(MPEGTSFixtureBuilder.patPacket())
    data.append(MPEGTSFixtureBuilder.pmtPacket(streams: [
        (streamType: 0x0F, elementaryPID: 0x0022),
        (streamType: 0x15, elementaryPID: metadataPID)
    ]))

    let pes = makeTimedID3PES(id3Payload: id3Payload, ptsSeconds: ptsSeconds)
    var offset = 0
    var continuityCounter: UInt8 = 0
    var payloadUnitStart = true
    while offset < pes.count {
        let remaining = pes.count - offset
        let take = min(remaining, 184)
        let chunk = pes.subdata(in: offset..<(offset + take))
        data.append(MPEGTSFixtureBuilder.packet(
            pid: metadataPID,
            payloadUnitStart: payloadUnitStart,
            continuityCounter: continuityCounter,
            payload: chunk
        ))
        offset += take
        continuityCounter = (continuityCounter + 1) & 0x0F
        payloadUnitStart = false
    }
    return data
}

private func makeTimedID3PES(id3Payload: Data, ptsSeconds: Double) -> Data {
    let ptsTicks = UInt64((ptsSeconds * 90_000.0).rounded())
    let pesPacketLength = 8 + id3Payload.count
    return Data([
        0x00, 0x00, 0x01, 0xBD,
        UInt8((pesPacketLength >> 8) & 0xFF),
        UInt8(pesPacketLength & 0xFF),
        0x84, 0x80, 0x05
    ]) + encodedPTS(ptsTicks) + id3Payload
}

private func encodedPTS(_ ticks: UInt64) -> Data {
    let first = UInt8(0x20 | UInt8(((ticks >> 30) & 0x07) << 1) | 0x01)
    let second = UInt8((ticks >> 22) & 0xFF)
    let third = UInt8(UInt8(((ticks >> 15) & 0x7F) << 1) | 0x01)
    let fourth = UInt8((ticks >> 7) & 0xFF)
    let fifth = UInt8(UInt8((ticks & 0x7F) << 1) | 0x01)
    return Data([first, second, third, fourth, fifth])
}

private struct StubSegmentLoader: HLSSegmentLoading {
    let data: Data

    func loadSegment(uri: String, relativeTo manifestSource: String) async throws -> Data {
        data
    }
}
