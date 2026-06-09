import Foundation
import XCTest

@testable import SoundingKit

final class AVFoundationAudioDecoderTests: XCTestCase {
    func testHLSManifestSegmentsProduceBoundedChunksWithManifestMarkers() async throws {
        let manifestURL = temporaryManifestURL(
            contents: """
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
                "segments/segment8.ts": Data([0x04, 0x05, 0x06]),
            ]),
            now: { "2026-04-30T12:00:00Z" }
        )

        let chunks = try await decoder.decodedChunks(
            for: AudioDecodeRequest(
                source: manifestURL.path,
                streamType: .hls,
                maxChunks: 1
            ))

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].sequence, 0)
        XCTAssertEqual(chunks[0].hlsIdentity?.mediaSequence, 7)
        XCTAssertEqual(chunks[0].hlsIdentity?.manifestPosition, 0)
        XCTAssertEqual(chunks[0].hlsIdentity?.segmentIdentity, "[redacted-path]")
        XCTAssertEqual(chunks[0].audio, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(chunks[0].startSeconds, 0)
        XCTAssertEqual(chunks[0].endSeconds, 6)
        XCTAssertEqual(chunks[0].adMarkers.count, 1)
        XCTAssertEqual(chunks[0].adMarkers[0].source, "hls_manifest")
        XCTAssertEqual(chunks[0].adMarkers[0].segment, "7")
    }

    func testHLSIdentityUsesMediaSequenceForContiguousSegments() async throws {
        let manifestURL = temporaryManifestURL(
            contents: """
                #EXTM3U
                #EXT-X-TARGETDURATION:6
                #EXT-X-MEDIA-SEQUENCE:7
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
                "segments/segment7.ts": Data([0x01]),
                "segments/segment8.ts": Data([0x02]),
            ]),
            now: { "2026-04-30T12:00:00Z" }
        )

        let chunks = try await decoder.decodedChunks(
            for: AudioDecodeRequest(
                source: manifestURL.path,
                streamType: .hls
            ))

        XCTAssertEqual(chunks.map(\.sequence), [0, 1])
        XCTAssertEqual(chunks.compactMap { $0.hlsIdentity?.mediaSequence }, [7, 8])
        XCTAssertEqual(chunks.compactMap { $0.hlsIdentity?.manifestPosition }, [0, 1])
    }

    func testHLSDecodeSkipsSegmentsBeforeMinimumMediaSequenceBeforeLoading() async throws {
        let manifestURL = temporaryManifestURL(
            contents: """
                #EXTM3U
                #EXT-X-TARGETDURATION:6
                #EXT-X-MEDIA-SEQUENCE:7
                #EXTINF:6.0,
                segments/segment7.ts
                #EXTINF:6.0,
                segments/segment8.ts
                #EXTINF:6.0,
                segments/segment9.ts
                #EXT-X-ENDLIST
                """)
        defer { try? FileManager.default.removeItem(at: manifestURL.deletingLastPathComponent()) }

        let loader = RecordingSegmentLoader(payload: Data([0x09]))
        let decoder = AVFoundationAudioDecoder(
            chunkDurationSeconds: 6,
            segmentLoader: loader,
            now: { "2026-04-30T12:00:00Z" }
        )

        let chunks = try await decoder.decodedChunks(
            for: AudioDecodeRequest(
                source: manifestURL.path,
                streamType: .hls,
                maxChunks: 1,
                minimumHLSMediaSequence: 9
            ))

        XCTAssertEqual(chunks.map { $0.hlsIdentity?.mediaSequence }, [9])
        let requests = await loader.requests()
        XCTAssertEqual(requests.map(\.uri), ["segments/segment9.ts"])
    }

    func testHLSDecodeKeepsCurrentPlaylistWhenPersistedMinimumIsAboveResetSequence() async throws {
        let manifestURL = temporaryManifestURL(
            contents: """
                #EXTM3U
                #EXT-X-TARGETDURATION:6
                #EXT-X-MEDIA-SEQUENCE:8
                #EXT-X-DISCONTINUITY-SEQUENCE:2
                #EXT-X-DISCONTINUITY
                #EXTINF:6.0,
                segments/segment8.ts
                #EXTINF:6.0,
                segments/segment9.ts
                #EXT-X-ENDLIST
                """)
        defer { try? FileManager.default.removeItem(at: manifestURL.deletingLastPathComponent()) }

        let loader = RecordingSegmentLoader(payload: Data([0x08]))
        let decoder = AVFoundationAudioDecoder(
            chunkDurationSeconds: 6,
            segmentLoader: loader,
            now: { "2026-04-30T12:00:00Z" }
        )

        let chunks = try await decoder.decodedChunks(
            for: AudioDecodeRequest(
                source: manifestURL.path,
                streamType: .hls,
                maxChunks: 1,
                minimumHLSMediaSequence: 713
            ))

        XCTAssertEqual(chunks.map { $0.hlsIdentity?.mediaSequence }, [8])
        let requests = await loader.requests()
        XCTAssertEqual(requests.map(\.uri), ["segments/segment8.ts"])
    }

    func testHLSResetFallbackAppliesMaxChunksAfterPersistedIdentityExclusions() async throws {
        let manifestURL = temporaryManifestURL(
            contents: """
                #EXTM3U
                #EXT-X-TARGETDURATION:6
                #EXT-X-MEDIA-SEQUENCE:8
                #EXT-X-DISCONTINUITY-SEQUENCE:2
                #EXT-X-DISCONTINUITY
                #EXTINF:6.0,
                segments/segment8.ts
                #EXTINF:6.0,
                segments/segment9.ts
                #EXT-X-ENDLIST
                """)
        defer { try? FileManager.default.removeItem(at: manifestURL.deletingLastPathComponent()) }

        let loader = RecordingSegmentLoader(payload: Data([0x09]))
        let decoder = AVFoundationAudioDecoder(
            chunkDurationSeconds: 6,
            segmentLoader: loader,
            now: { "2026-04-30T12:00:00Z" }
        )

        let chunks = try await decoder.decodedChunks(
            for: AudioDecodeRequest(
                source: manifestURL.path,
                streamType: .hls,
                maxChunks: 1,
                minimumHLSMediaSequence: 713,
                excludedHLSSegmentKeys: [
                    HLSDecodedAudioSegmentKey(mediaSequence: 8, segmentIdentity: "[redacted-path]")
                ]
            ))

        XCTAssertEqual(chunks.map { $0.hlsIdentity?.mediaSequence }, [9])
        let requests = await loader.requests()
        XCTAssertEqual(requests.map(\.uri), ["segments/segment9.ts"])
    }

    func testHLSDecodedChunksIncludeSegmentByteMarkers() async throws {
        let manifestURL = temporaryManifestURL(
            contents: """
                #EXTM3U
                #EXT-X-TARGETDURATION:6
                #EXT-X-MEDIA-SEQUENCE:7
                #EXTINF:6.0,
                segments/segment7.aac
                #EXT-X-ENDLIST
                """)
        defer { try? FileManager.default.removeItem(at: manifestURL.deletingLastPathComponent()) }

        let decoder = AVFoundationAudioDecoder(
            chunkDurationSeconds: 6,
            segmentLoader: FixtureSegmentLoader(payloads: [
                "segments/segment7.aac": Data([0x01, 0x02, 0x03])
            ]),
            segmentID3Extractor: FixtureSegmentID3Extractor(),
            segmentSCTE35Extractor: EmptySegmentSCTE35Extractor(),
            now: { "2026-04-30T12:00:00Z" }
        )

        let chunks = try await decoder.decodedChunks(
            for: AudioDecodeRequest(
                source: manifestURL.path,
                streamType: .hls,
                maxChunks: 1
            ))

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].adMarkers.map(\.type), ["ID3"])
        XCTAssertEqual(chunks[0].adMarkers.first?.fields["StreamTitle"], .string("Fixture Title"))
        XCTAssertEqual(chunks[0].adMarkers.first?.segment, "7")
    }

    func testHLSSegmentByteMarkerFailuresDoNotAbortDecode() async throws {
        let manifestURL = temporaryManifestURL(
            contents: """
                #EXTM3U
                #EXT-X-TARGETDURATION:6
                #EXT-X-MEDIA-SEQUENCE:7
                #EXTINF:6.0,
                segments/segment7.aac
                #EXT-X-ENDLIST
                """)
        defer { try? FileManager.default.removeItem(at: manifestURL.deletingLastPathComponent()) }

        let decoder = AVFoundationAudioDecoder(
            chunkDurationSeconds: 6,
            segmentLoader: FixtureSegmentLoader(payloads: [
                "segments/segment7.aac": Data([0x01, 0x02, 0x03])
            ]),
            segmentID3Extractor: ThrowingSegmentID3Extractor(),
            segmentSCTE35Extractor: EmptySegmentSCTE35Extractor(),
            now: { "2026-04-30T12:00:00Z" }
        )

        let chunks = try await decoder.decodedChunks(
            for: AudioDecodeRequest(
                source: manifestURL.path,
                streamType: .hls,
                maxChunks: 1
            ))

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].audio, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(chunks[0].adMarkers, [])
    }

    func testHLSSegmentLoaderFailureKeepsRawSegmentURIOutOfError() async throws {
        let manifestURL = temporaryManifestURL(
            contents: """
                #EXTM3U
                #EXT-X-MEDIA-SEQUENCE:7
                #EXTINF:6.0,
                https://user:pass@example.test/segment7.ts?token=secret#frag
                #EXT-X-ENDLIST
                """)
        defer { try? FileManager.default.removeItem(at: manifestURL.deletingLastPathComponent()) }

        let decoder = AVFoundationAudioDecoder(
            chunkDurationSeconds: 6,
            segmentLoader: FailingSegmentLoader(),
            now: { "2026-04-30T12:00:00Z" }
        )

        do {
            _ = try await decoder.decodedChunks(
                for: AudioDecodeRequest(
                    source: manifestURL.path,
                    streamType: .hls,
                    maxChunks: 1
                ))
            XCTFail("Expected segment loader failure")
        } catch let error as AVFoundationAudioDecoderError {
            XCTAssertEqual(error.ingestDiagnosticPhase, .decode)
            XCTAssertEqual(error.ingestDiagnosticReason, "decode-failed")
            XCTAssertTrue(
                error.description.contains("https://example.test/segment7.ts"), error.description)
            XCTAssertFalse(error.description.contains("user:pass"), error.description)
            XCTAssertFalse(error.description.contains("token=secret"), error.description)
            XCTAssertFalse(error.description.contains("#frag"), error.description)
        } catch {
            XCTFail("Expected AVFoundationAudioDecoderError, got \(error)")
        }
    }

    func testMissingSourceThrowsSourceOpenDiagnosticErrorWithRedactedDescription() async throws {
        let decoder = AVFoundationAudioDecoder()

        do {
            _ = try await decoder.decodedChunks(
                for: AudioDecodeRequest(
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

    func testNonHLSAssetDecodeSlicesPCMPerChunk() async throws {
        let url = temporaryWAVURL(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = AVFoundationAudioDecoder(chunkDurationSeconds: 1)

        let chunks = try await decoder.decodedChunks(
            for: AudioDecodeRequest(
                source: url.path,
                streamType: .icecast,
                durationSeconds: 2,
                maxChunks: 2
            ))

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.map(\.startSeconds), [0, 1])
        XCTAssertEqual(chunks.map(\.endSeconds), [1, 2])
        XCTAssertEqual(chunks[0].audioFormat.payloadKind, .linearPCM)
        XCTAssertLessThan(chunks[0].audio.count, chunks[0].audio.count + chunks[1].audio.count)
        XCTAssertNotEqual(chunks[0].audio, chunks[1].audio)
    }

    func testICYTimelineStartUsesPersistentByteOffset() {
        let start = AVFoundationAudioDecoder.icyTimelineStartSeconds(
            totalAudioBytesAfterRead: 320_000,
            readAudioByteCount: 160_000,
            byteRate: 16_000
        )

        XCTAssertEqual(start, 10, accuracy: 0.001)
    }

    func testICYStreamingSessionKeepsFutureMetadataMarkersQueued() {
        let current = ICYStreamingSession.PendingMarker(
            marker: AdMarker(
                type: "ICY",
                classification: .unknown,
                source: "icy_stream",
                fields: ["StreamTitle": .string("Current Song")]
            ),
            audioByteOffset: 160_000
        )
        let future = ICYStreamingSession.PendingMarker(
            marker: AdMarker(
                type: "ICY",
                classification: .unknown,
                source: "icy_stream",
                fields: ["StreamTitle": .string("Future Song")]
            ),
            audioByteOffset: 320_000
        )
        let unpositioned = ICYStreamingSession.PendingMarker(
            marker: AdMarker(
                type: "ICY",
                classification: .unknown,
                source: "icy_stream",
                fields: ["StreamTitle": .string("Unpositioned")]
            ),
            audioByteOffset: nil
        )

        let split = ICYStreamingSession.splitPendingMarkersForRead(
            [current, future, unpositioned],
            readEndAudioByteOffset: 160_000
        )

        XCTAssertEqual(
            split.ready.map { streamTitle(from: $0.marker) },
            ["Current Song", "Unpositioned"]
        )
        XCTAssertEqual(
            split.remaining.map { streamTitle(from: $0.marker) },
            ["Future Song"]
        )
    }

    func testDurationBoundCanEndBeforeAnyHLSChunk() async throws {
        let manifestURL = temporaryManifestURL(
            contents: """
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

        let chunks = try await decoder.decodedChunks(
            for: AudioDecodeRequest(
                source: manifestURL.path,
                streamType: .hls,
                durationSeconds: 0
            ))

        XCTAssertEqual(chunks, [])
    }

    func testHLSMasterManifestFollowsLowestBandwidthVariantAndPreservesRequiredQuery() async throws {
        let masterURL = temporaryManifestURL(
            contents: """
                #EXTM3U
                #EXT-X-STREAM-INF:BANDWIDTH=320000,CODECS=\"mp4a.40.2\"
                high/manifest.m3u8?suid=abc&playlist-id=high
                #EXT-X-STREAM-INF:BANDWIDTH=165000,CODECS=\"mp4a.40.2\"
                low/manifest.m3u8?suid=abc&playlist-id=low
                """
        )
        let lowDirectory = masterURL.deletingLastPathComponent().appendingPathComponent("low", isDirectory: true)
        try FileManager.default.createDirectory(at: lowDirectory, withIntermediateDirectories: true)
        let variantURL = lowDirectory.appendingPathComponent("manifest.m3u8")
        try """
            #EXTM3U
            #EXT-X-MEDIA-SEQUENCE:42
            #EXTINF:6.0,
            segment42.aac?session=kept
            """.data(using: .utf8)!.write(to: variantURL)
        defer { try? FileManager.default.removeItem(at: masterURL.deletingLastPathComponent()) }

        let loader = RecordingSegmentLoader(payload: Data([0x01, 0x02, 0x03]))
        let decoder = AVFoundationAudioDecoder(
            chunkDurationSeconds: 6,
            segmentLoader: loader,
            now: { "2026-04-30T12:00:00Z" }
        )

        let chunks = try await decoder.decodedChunks(
            for: AudioDecodeRequest(source: masterURL.path, streamType: .hls, maxChunks: 1))

        XCTAssertEqual(chunks.map(\.sequence), [0])
        XCTAssertEqual(chunks.first?.hlsIdentity?.mediaSequence, 42)
        let requested = await loader.requests()
        XCTAssertEqual(requested.map(\.uri), ["segment42.aac?session=kept"])
        XCTAssertEqual(requested.map(\.relativeTo), [variantURL.path])
    }

    private func temporaryManifestURL(contents: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sounding-hls-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let segments = directory.appendingPathComponent("segments", isDirectory: true)
        try! FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("manifest.m3u8")
        try! contents.data(using: .utf8)!.write(to: manifest)
        return manifest
    }

    private func streamTitle(from marker: AdMarker) -> String? {
        guard case let .string(title)? = marker.fields["StreamTitle"] else { return nil }
        return title
    }

    private func temporaryWAVURL(seconds: Double) -> URL {
        let sampleRate = 44_100
        let channelCount = 1
        let bitDepth = 16
        let frameCount = Int(Double(sampleRate) * seconds)
        var pcm = Data()
        pcm.reserveCapacity(frameCount * MemoryLayout<Int16>.size)
        for frame in 0..<frameCount {
            var sample = Int16(clamping: frame % Int(Int16.max))
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }

        var wav = Data()
        appendASCII("RIFF", to: &wav)
        appendUInt32LE(UInt32(36 + pcm.count), to: &wav)
        appendASCII("WAVE", to: &wav)
        appendASCII("fmt ", to: &wav)
        appendUInt32LE(16, to: &wav)
        appendUInt16LE(1, to: &wav)
        appendUInt16LE(UInt16(channelCount), to: &wav)
        appendUInt32LE(UInt32(sampleRate), to: &wav)
        appendUInt32LE(UInt32(sampleRate * channelCount * bitDepth / 8), to: &wav)
        appendUInt16LE(UInt16(channelCount * bitDepth / 8), to: &wav)
        appendUInt16LE(UInt16(bitDepth), to: &wav)
        appendASCII("data", to: &wav)
        appendUInt32LE(UInt32(pcm.count), to: &wav)
        wav.append(pcm)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-fixture-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try! wav.write(to: url, options: .atomic)
        return url
    }

    private func appendASCII(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
    }

    private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}

private actor RecordingSegmentLoader: HLSSegmentLoading {
    struct Request: Equatable {
        var uri: String
        var relativeTo: String
    }

    var payload: Data
    private var recordedRequests: [Request] = []

    init(payload: Data) {
        self.payload = payload
    }

    func loadSegment(uri: String, relativeTo manifestSource: String) async throws -> Data {
        recordedRequests.append(Request(uri: uri, relativeTo: manifestSource))
        return payload
    }

    func requests() -> [Request] { recordedRequests }
}

private struct FailingSegmentLoader: HLSSegmentLoading {
    func loadSegment(uri: String, relativeTo manifestSource: String) async throws -> Data {
        throw AVFoundationAudioDecoderError.sourceOpenFailed("failed loading \(uri)")
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

private struct FixtureSegmentID3Extractor: HLSSegmentID3Extracting {
    func extractMarkers(
        from data: Data,
        mediaSequence: String,
        segmentURI: String
    ) throws -> [AdMarker] {
        [
            AdMarker(
                type: "ID3",
                classification: .unknown,
                source: "hls_segment",
                tag: "ID3",
                segment: mediaSequence,
                fields: ["StreamTitle": .string("Fixture Title")]
            )
        ]
    }
}

private struct ThrowingSegmentID3Extractor: HLSSegmentID3Extracting {
    func extractMarkers(
        from data: Data,
        mediaSequence: String,
        segmentURI: String
    ) throws -> [AdMarker] {
        throw NSError(domain: "fixture-id3", code: 32)
    }
}

private struct EmptySegmentSCTE35Extractor: HLSSegmentSCTE35Extracting {
    func extractMarkers(
        from data: Data,
        mediaSequence: String,
        segmentURI: String
    ) throws -> [AdMarker] {
        []
    }
}
