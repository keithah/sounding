import Foundation
import XCTest
@testable import SoundingKit

final class ID3MarkerDecoderTests: XCTestCase {
    func testMapsApplePrivateTimestampTagIntoSafeMarkerContract() throws {
        let tag = appleMarkerTag()

        let markers = try ID3MarkerDecoder.decodeMarkers(
            fromSegmentBytes: Data([0x00, 0x01]) + tag + Data([0x02, 0x03]),
            segment: "segment-0001.ts",
            timestamp: "2026-04-30T08:00:00Z"
        )

        XCTAssertEqual(markers.count, 1)
        let marker = try XCTUnwrap(markers.first)
        XCTAssertEqual(marker.type, "ID3")
        XCTAssertEqual(marker.classification, .unknown)
        XCTAssertEqual(marker.source, "hls_segment")
        XCTAssertEqual(marker.tag, "ID3")
        XCTAssertEqual(marker.segment, "segment-0001.ts")
        XCTAssertEqual(marker.timestamp, "2026-04-30T08:00:00Z")
        XCTAssertEqual(try XCTUnwrap(marker.pts), 2.0, accuracy: 0.000_001)
        XCTAssertNil(marker.rawBase64)
        XCTAssertNil(marker.command)
        XCTAssertEqual(marker.descriptors, [])
        XCTAssertEqual(marker.tags["TIT2"], "Primary Cue")
        XCTAssertEqual(marker.tags["TIT3"], "Subtitle Cue")
        XCTAssertEqual(marker.tags["TXXX:TIDEMARK"], "AD|START")
        XCTAssertEqual(marker.fields["FrameIDs"], ["PRIV", "TIT2", "TIT3", "TXXX"])
        XCTAssertEqual(marker.fields["TimestampTicks"], 180_000)
        XCTAssertEqual(marker.fields["TimestampSeconds"], 2.0)
        XCTAssertEqual(marker.fields["PrivateOwners"], ["com.apple.streaming.transportStreamTimestamp"])
        XCTAssertEqual(marker.fields["PrivateFrameCount"], 1)

        let frames = try XCTUnwrap(marker.fields["Frames"])
        XCTAssertEqual(frames, .array([
            .object([
                "ID": "PRIV",
                "Index": 3,
                "Owner": "com.apple.streaming.transportStreamTimestamp",
                "DataLength": 8,
                "TimestampTicks": 180_000,
                "TimestampSeconds": 2.0
            ]),
            .object([
                "ID": "TIT2",
                "Index": 0,
                "Texts": ["Primary Cue"]
            ]),
            .object([
                "ID": "TIT3",
                "Index": 1,
                "Texts": ["Subtitle Cue"]
            ]),
            .object([
                "ID": "TXXX",
                "Index": 2,
                "Description": "TIDEMARK",
                "Texts": ["AD", "START"]
            ])
        ]))

        let actualData = try JSONEncoder().encode(marker)
        let expectedURL = try XCTUnwrap(Bundle.module.url(forResource: "expected-apple-priv-marker", withExtension: "json", subdirectory: "Fixtures/ID3"))
        let expectedObject = try semanticJSONObject(from: Data(contentsOf: expectedURL))
        try assertSemanticJSONEqual(actualData, expectedObject)
    }

    func testNoID3SegmentReturnsNoMarkers() throws {
        let markers = try ID3MarkerDecoder.decodeMarkers(fromSegmentBytes: Data("not an id3 segment".utf8))

        XCTAssertEqual(markers, [])
    }

    func testMalformedID3CandidatePropagatesSanitizedDecodeError() throws {
        let malformed = Data([0x49, 0x44, 0x33, 0x04])

        XCTAssertThrowsError(try ID3MarkerDecoder.decodeMarkers(fromSegmentBytes: malformed)) { error in
            guard let decodeError = error as? ID3DecodeError else {
                return XCTFail("Expected ID3DecodeError, got \(error)")
            }
            XCTAssertEqual(decodeError, .truncatedHeader)
            XCTAssertTrue(decodeError.description.contains("ID3 scan failed"))
            XCTAssertFalse(decodeError.description.contains("not an id3 segment"))
            XCTAssertFalse(decodeError.description.contains("SUQz"))
            XCTAssertFalse(decodeError.description.contains("494433"))
        }
    }

    func testDuplicateFramesUseDeterministicSafeOrdering() throws {
        let tag = ID3FixtureBuilder.tag(frames: [
            ID3FixtureBuilder.userTextFrame(description: "beta", values: ["two"]),
            ID3FixtureBuilder.textFrame(id: "TIT2", values: ["Second Title"]),
            ID3FixtureBuilder.userTextFrame(description: "alpha", values: ["one"]),
            ID3FixtureBuilder.textFrame(id: "TIT2", values: ["First Title"])
        ])

        let marker = try XCTUnwrap(ID3MarkerDecoder.decodeMarkers(fromSegmentBytes: tag).first)

        XCTAssertEqual(marker.tags["TIT2"], "First Title")
        XCTAssertEqual(marker.tags["TXXX:alpha"], "one")
        XCTAssertEqual(marker.tags["TXXX:beta"], "two")
        XCTAssertEqual(marker.fields["FrameIDs"], ["TIT2", "TIT2", "TXXX", "TXXX"])
        XCTAssertEqual(marker.fields["Frames"], .array([
            .object(["ID": "TIT2", "Index": 1, "Texts": ["Second Title"]]),
            .object(["ID": "TIT2", "Index": 3, "Texts": ["First Title"]]),
            .object(["ID": "TXXX", "Index": 0, "Description": "beta", "Texts": ["two"]]),
            .object(["ID": "TXXX", "Index": 2, "Description": "alpha", "Texts": ["one"]])
        ]))
    }

    func testMultipleTagsProduceMultipleMarkersAndAbsentTimestampLeavesPTSNull() throws {
        let first = appleMarkerTag(ticks: 90_000)
        let second = ID3FixtureBuilder.tag(frames: [
            ID3FixtureBuilder.textFrame(id: "TIT2", values: ["No Timestamp"])
        ])

        let markers = try ID3MarkerDecoder.decodeMarkers(fromSegmentBytes: first + Data([0x99]) + second)

        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers[0].pts, 1.0)
        XCTAssertNil(markers[1].pts)
        XCTAssertNil(markers[1].fields["TimestampTicks"])
        XCTAssertNil(markers[1].fields["TimestampSeconds"])
    }

    func testMarkerJSONDoesNotLeakPrivatePayloadsOrUnsafeURLSourceDetails() throws {
        let privateLiteral = "PRIVATE-SECRET-PAYLOAD"
        let privatePayload = Data(privateLiteral.utf8)
        let tag = ID3FixtureBuilder.tag(frames: [
            ID3FixtureBuilder.textFrame(id: "TIT2", values: ["Public Cue"]),
            ID3FixtureBuilder.privateFrame(owner: "owner.example", data: privatePayload)
        ])
        let fullSegment = Data("prefix".utf8) + tag + Data("suffix".utf8)
        let marker = try XCTUnwrap(ID3MarkerDecoder.decodeMarkers(
            fromSegmentBytes: fullSegment,
            source: "https://user:pass@example.test/path/segment.ts?token=secret#frag"
        ).first)

        let json = String(decoding: try JSONEncoder().encode(marker), as: UTF8.self)

        XCTAssertFalse(json.contains(privateLiteral))
        XCTAssertFalse(json.contains(privatePayload.map { String(format: "%02x", $0) }.joined()))
        XCTAssertFalse(json.contains(privatePayload.base64EncodedString()))
        XCTAssertFalse(json.contains(tag.base64EncodedString()))
        XCTAssertFalse(json.contains(fullSegment.base64EncodedString()))
        XCTAssertFalse(json.contains("raw_base64"))
        XCTAssertFalse(json.contains("user:pass"))
        XCTAssertFalse(json.contains("token=secret"))
        XCTAssertFalse(json.contains("#frag"))
        XCTAssertFalse(json.contains("https://user:pass@example.test/path/segment.ts?token=secret#frag"))
        XCTAssertEqual(marker.source, "https://example.test/path/segment.ts")
        XCTAssertEqual(marker.fields["PrivateOwners"], ["owner.example"])
        XCTAssertEqual(marker.fields["PrivateFrameCount"], 1)
    }

    private func appleMarkerTag(ticks: UInt64 = 180_000) -> Data {
        ID3FixtureBuilder.tag(frames: [
            ID3FixtureBuilder.textFrame(id: "TIT2", values: ["Primary Cue"]),
            ID3FixtureBuilder.textFrame(id: "TIT3", values: ["Subtitle Cue"]),
            ID3FixtureBuilder.userTextFrame(description: "TIDEMARK", values: ["AD", "START"]),
            ID3FixtureBuilder.appleTransportTimestampFrame(ticks: ticks)
        ])
    }
}
