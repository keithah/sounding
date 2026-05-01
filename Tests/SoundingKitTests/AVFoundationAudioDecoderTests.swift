import Foundation
import XCTest
@testable import SoundingKit

final class AVFoundationAudioDecoderTests: XCTestCase {
    func testHLSManifestSegmentsProduceBoundedChunksWithManifestMarkers() async throws {
        let manifestURL = temporaryManifestURL(contents: """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:7
        #EXT-OATCLS-SCTE35:/DARAAAAAAAAAP/wAAAAAHpPGuQ=
        #EXTINF:6.0,
        segments/segment7.ts
        #EXTINF:6.0,
        segments/segment8.ts
        #EXT-X-ENDLIST
        """)
        defer { try? FileManager.default.removeItem(at: manifestURL.deletingLastPathComponent()) }

        let decoder = AVFoundationAudioDecoder(
            chunkDurationSeconds: 6,
            segmentLoader: FixtureSegmentLoader(payloads: [
                "segments/segment7.ts": Data([0x01, 0x02, 0x03]),
                "segments/segment8.ts": Data([0x04, 0x05, 0x06])
            ]),
            now: { "2026-04-30T12:00:00Z" }
        )

        let chunks = try await decoder.decodedChunks(for: AudioDecodeRequest(
            source: manifestURL.path,
            streamType: .hls,
            maxChunks: 1
        ))

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].sequence, 0)
        XCTAssertEqual(chunks[0].audio, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(chunks[0].startSeconds, 0)
        XCTAssertEqual(chunks[0].endSeconds, 6)
        XCTAssertEqual(chunks[0].adMarkers.count, 1)
        XCTAssertEqual(chunks[0].adMarkers[0].source, "hls_manifest")
        XCTAssertEqual(chunks[0].adMarkers[0].segment, "7")
    }

    func testMissingSourceThrowsSourceOpenDiagnosticErrorWithRedactedDescription() async throws {
        let decoder = AVFoundationAudioDecoder()

        do {
            _ = try await decoder.decodedChunks(for: AudioDecodeRequest(
                source: "/tmp/missing-token=secret.wav",
                streamType: .icecast,
                maxChunks: 1
            ))
            XCTFail("Expected missing source failure")
        } catch let error as AVFoundationAudioDecoderError {
            XCTAssertEqual(error.ingestDiagnosticPhase, .sourceOpen)
            XCTAssertEqual(error.ingestDiagnosticReason, "source-open-failed")
            XCTAssertFalse(error.description.contains("secret"), error.description)
        } catch {
            XCTFail("Expected AVFoundationAudioDecoderError, got \(error)")
        }
    }

    func testDurationBoundCanEndBeforeAnyHLSChunk() async throws {
        let manifestURL = temporaryManifestURL(contents: """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:1
        #EXTINF:6.0,
        segment1.ts
        #EXT-X-ENDLIST
        """)
        defer { try? FileManager.default.removeItem(at: manifestURL.deletingLastPathComponent()) }

        let decoder = AVFoundationAudioDecoder(
            chunkDurationSeconds: 6,
            segmentLoader: FixtureSegmentLoader(payloads: ["segment1.ts": Data([0x01])]),
            now: { "2026-04-30T12:00:00Z" }
        )

        let chunks = try await decoder.decodedChunks(for: AudioDecodeRequest(
            source: manifestURL.path,
            streamType: .hls,
            durationSeconds: 0
        ))

        XCTAssertEqual(chunks, [])
    }

    private func temporaryManifestURL(contents: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sounding-hls-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let segments = directory.appendingPathComponent("segments", isDirectory: true)
        try! FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("manifest.m3u8")
        try! contents.data(using: .utf8)!.write(to: manifest)
        return manifest
    }
}

private struct FixtureSegmentLoader: HLSSegmentLoading {
    var payloads: [String: Data]

    func loadSegment(uri: String, relativeTo manifestSource: String) async throws -> Data {
        if let payload = payloads[uri] {
            return payload
        }
        throw AVFoundationAudioDecoderError.sourceOpenFailed("fixture segment missing")
    }
}
