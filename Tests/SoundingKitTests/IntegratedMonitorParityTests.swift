import Foundation
import XCTest
@testable import SoundingKit

final class IntegratedMonitorParityTests: XCTestCase {
    // R002 fixture acceptance map:
    // - HLS SCTE-35: `testHLSSCTE35FixtureEmitsManifestUnknownThenSegmentAdStart`
    // - HLS ID3: `testHLSID3FixtureEmitsSafeAdStartEvidence`
    // - ICY/Icecast: `testInjectedICYStreamEmitsPerRunAdStartAndAdEndTransitions`
    // - MPEGTS: `testMPEGTSSpliceNullFixtureEmitsUnknownMarker`
    // - UDP replay: `testUDPReplaySpliceNullFixtureEmitsUnknownMarkerWithDistinctSourceClass`
    // - Filters/JSON fields: each source test encodes public marker NDJSON and asserts classifications.
    override func tearDown() {
        MonitorPipeline.icyAdapterFactory = MonitorPipeline.defaultICYAdapterFactory
        super.tearDown()
    }

    func testHLSSCTE35FixtureEmitsManifestUnknownThenSegmentAdStart() async throws {
        let markers = try await runMonitor(
            fixture: "Fixtures/HLS/manifest-scte35.m3u8",
            streamType: .hls,
            filter: "all"
        )
        let objects = try encodeAndParseMarkers(markers, sourceClass: "hls-scte35")

        assertSemanticMarker(
            objects,
            at: 0,
            sourceClass: "hls-scte35",
            type: "SCTE35",
            source: "hls_manifest",
            classification: "UNKNOWN"
        )
        assertSemanticMarker(
            objects,
            at: 1,
            sourceClass: "hls-scte35",
            type: "SCTE35",
            source: "hls_segment",
            classification: "AD_START"
        )
        XCTAssertEqual(objects.count, 2)
        try assertNoTopLevelBreakDurationKeys(objects, sourceClass: "hls-scte35")

        XCTAssertEqual(objects[0]["Segment"] as? String, "7")
        XCTAssertEqual(value(at: "Command.Name", in: objects[0]) as? String, "Splice Null")
        XCTAssertEqual(value(at: "Fields.CommandName", in: objects[0]) as? String, "SPLICE_NULL")
        XCTAssertEqual(value(at: "Tags.MediaSequence", in: objects[0]) as? String, "7")
        XCTAssertEqual(value(at: "Tags.SegmentURI", in: objects[0]) as? String, "segments/segment7.ts")

        XCTAssertEqual(objects[1]["Segment"] as? String, "7")
        XCTAssertEqual(value(at: "Command.Name", in: objects[1]) as? String, "Splice Insert")
        XCTAssertEqual(value(at: "Fields.CommandName", in: objects[1]) as? String, "SPLICE_INSERT_OON_TRUE")
        XCTAssertEqual(value(at: "Tags.SourceClass", in: objects[1]) as? String, "hls_segment")
        XCTAssertEqual(value(at: "Tags.MediaSequence", in: objects[1]) as? String, "7")
    }

    func testHLSID3FixtureEmitsSafeAdStartEvidence() async throws {
        let markers = try await runMonitor(
            fixture: "Fixtures/HLS/manifest-id3.m3u8",
            streamType: .hls,
            filter: "ad_start"
        )
        let objects = try encodeAndParseMarkers(markers, sourceClass: "hls-id3")

        XCTAssertEqual(objects.count, 1)
        assertSemanticMarker(
            objects,
            at: 0,
            sourceClass: "hls-id3",
            type: "ID3",
            source: "hls_segment",
            classification: "AD_START"
        )
        try assertNoTopLevelBreakDurationKeys(objects, sourceClass: "hls-id3")

        let marker = objects[0]
        XCTAssertEqual(marker["Segment"] as? String, "42")
        XCTAssertEqual(marker["Tag"] as? String, "ID3")
        XCTAssertEqual(marker["PTS"] as? Double, 2.0)
        XCTAssertTrue(marker["RawBase64"] is NSNull, "ID3 marker must not expose raw private payload")
        XCTAssertTrue(marker["Timestamp"] is NSNull)
        XCTAssertEqual(value(at: "Tags.TIT2", in: marker) as? String, "Primary Cue")
        XCTAssertEqual(value(at: "Tags.TIT3", in: marker) as? String, "Subtitle Cue")
        XCTAssertEqual(value(at: "Tags.TXXX:TIDEMARK", in: marker) as? String, "AD|START")
        XCTAssertEqual(value(at: "Fields.PrivateFrameCount", in: marker) as? Int, 1)
        XCTAssertEqual(value(at: "Fields.TimestampTicks", in: marker) as? Int, 180_000)
        XCTAssertEqual(value(at: "Fields.TimestampSeconds", in: marker) as? Double, 2.0)
        XCTAssertEqual(value(at: "Fields.MediaSequence", in: marker) as? String, "42")
        XCTAssertEqual(value(at: "Fields.SourceClass", in: marker) as? String, "hls_segment")
        XCTAssertEqual(value(at: "Fields.SegmentURI", in: marker) as? String, "segments/id3-segment.aac")
        XCTAssertEqual(value(at: "Fields.PrivateOwners", in: marker) as? [String], ["com.apple.streaming.transportStreamTimestamp"])
        XCTAssertEqual(value(at: "Fields.FrameIDs", in: marker) as? [String], ["PRIV", "TIT2", "TIT3", "TXXX"])
    }

    func testInjectedICYStreamEmitsPerRunAdStartAndAdEndTransitions() async throws {
        MonitorPipeline.icyAdapterFactory = { source, streamType in
            ICYMonitorAdapter(source: source, streamType: streamType) { _, _ in
                ICYMonitorAdapter.OpenedStream(
                    responseHeaders: ["icy-metaint": "4"],
                    streamBytes: Self.icyStream(metaInt: 4, titles: ["Regular Content", "Promo Spot", "Regular Content"])
                )
            }
        }
        let options = try MonitorOptions(source: "https://example.test/live", streamType: .icy, filter: "ad")

        let markers = try await MonitorPipeline.run(options: options)
        let objects = try encodeAndParseMarkers(markers, sourceClass: "icy")

        XCTAssertEqual(objects.count, 2)
        assertSemanticMarker(objects, at: 0, sourceClass: "icy", type: "ICY", source: "icy_stream", classification: "AD_START")
        assertSemanticMarker(objects, at: 1, sourceClass: "icy", type: "ICY", source: "icy_stream", classification: "AD_END")
        XCTAssertEqual(value(at: "Fields.StreamTitle", in: objects[0]) as? String, "Promo Spot")
        XCTAssertEqual(value(at: "Fields.StreamTitle", in: objects[1]) as? String, "Regular Content")
        try assertNoTopLevelBreakDurationKeys(objects, sourceClass: "icy")
    }

    func testMPEGTSSpliceNullFixtureEmitsUnknownMarker() async throws {
        let markers = try await runMonitor(
            fixture: "Fixtures/MPEGTS/scte35_splice_null.ts",
            streamType: .mpegts,
            filter: "unknown"
        )
        let objects = try encodeAndParseMarkers(markers, sourceClass: "mpegts")

        XCTAssertEqual(objects.count, 1)
        assertSemanticMarker(objects, at: 0, sourceClass: "mpegts", type: "SCTE35", source: "mpegts", classification: "UNKNOWN")
        XCTAssertEqual(objects[0]["Tag"] as? String, "mpegts_scte35_section")
        XCTAssertEqual(value(at: "Command.Name", in: objects[0]) as? String, "Splice Null")
        XCTAssertEqual(value(at: "Fields.CommandName", in: objects[0]) as? String, "SPLICE_NULL")
        XCTAssertEqual(value(at: "Tags.SourceClass", in: objects[0]) as? String, "mpegts_stream")
        XCTAssertEqual(value(at: "Tags.StreamType", in: objects[0]) as? String, "mpegts")
        try assertNoTopLevelBreakDurationKeys(objects, sourceClass: "mpegts")
    }

    func testUDPReplaySpliceNullFixtureEmitsUnknownMarkerWithDistinctSourceClass() async throws {
        let markers = try await runMonitor(
            fixture: "Fixtures/MPEGTS/scte35_splice_null.ts",
            streamType: .udp,
            filter: "unknown"
        )
        let objects = try encodeAndParseMarkers(markers, sourceClass: "udp")

        XCTAssertEqual(objects.count, 1)
        assertSemanticMarker(objects, at: 0, sourceClass: "udp", type: "SCTE35", source: "udp", classification: "UNKNOWN")
        XCTAssertEqual(objects[0]["Tag"] as? String, "mpegts_scte35_section")
        XCTAssertEqual(value(at: "Command.Name", in: objects[0]) as? String, "Splice Null")
        XCTAssertEqual(value(at: "Fields.CommandName", in: objects[0]) as? String, "SPLICE_NULL")
        XCTAssertEqual(value(at: "Tags.SourceClass", in: objects[0]) as? String, "udp_datagram_replay")
        XCTAssertEqual(value(at: "Tags.StreamType", in: objects[0]) as? String, "udp")
        try assertNoTopLevelBreakDurationKeys(objects, sourceClass: "udp")
    }

    func testSemanticNDJSONHelpersReportNegativeCases() throws {
        XCTAssertThrowsError(try semanticJSONObjects(fromNDJSON: Data(), sourceClass: "empty-helper", recordFailure: false))
        XCTAssertThrowsError(try semanticJSONObjects(fromNDJSON: Data("{bad-json}\n".utf8), sourceClass: "malformed-helper", recordFailure: false))
        XCTAssertThrowsError(
            try assertPublicMarkerKeySet(["Type": "SCTE35"], sourceClass: "missing-keys-helper", recordFailure: false)
        )
        XCTAssertThrowsError(
            try assertNoTopLevelBreakDurationKeys([["BreakDuration": 30.0]], sourceClass: "forbidden-break-helper", recordFailure: false)
        )
        XCTAssertThrowsError(
            try assertNoTopLevelBreakDurationKeys([["breakDuration": 30.0]], sourceClass: "forbidden-break-helper", recordFailure: false)
        )
    }

    private func runMonitor(fixture: String, streamType: StreamType, filter: String) async throws -> [AdMarker] {
        let fixturePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(fixture)
            .path
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixturePath), "Missing fixture at \(fixturePath)")
        let options = try MonitorOptions(source: fixturePath, streamType: streamType, filter: filter, quiet: true, emitJSON: true)
        return try await MonitorPipeline.run(options: options)
    }

    private static func icyStream(metaInt: Int, titles: [String]) -> Data {
        var data = Data()
        for title in titles {
            data.append(Data(repeating: 0x41, count: metaInt))
            let metadata = "StreamTitle='\(title)';".data(using: .utf8)!
            let paddedLength = Int(ceil(Double(metadata.count) / 16.0)) * 16
            data.append(UInt8(paddedLength / 16))
            data.append(metadata)
            data.append(Data(repeating: 0, count: paddedLength - metadata.count))
        }
        return data
    }
}
