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

private struct StubSegmentLoader: HLSSegmentLoading {
    let data: Data

    func loadSegment(uri: String, relativeTo manifestSource: String) async throws -> Data {
        data
    }
}
