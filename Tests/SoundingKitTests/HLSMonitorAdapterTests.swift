import Foundation
import XCTest
@testable import SoundingKit

final class HLSMonitorAdapterTests: XCTestCase {
    private let sourceWithSecrets = "https://user:pass@example.test/live/manifest.m3u8?token=secret#frag"

    func testLocalSegmentLoaderResolvesManifestRelativeURI() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HLS/manifest-scte35.m3u8")

        let data = try await HLSSegmentLoader().loadSegment(
            uri: "segments/segment7.ts",
            relativeTo: fixtureURL.absoluteString
        )

        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(data.first, 0x47)
    }

    func testAdapterEmitsManifestMarkersBeforeSegmentMarkersForSameMediaSequence() async throws {
        let section = makeSpliceInsertSection(eventID: 0x4800009E, ptsTicks: 8_100_000, breakDurationTicks: 5_426_421)
        let manifest = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:7
        #EXT-OATCLS-SCTE35:\(section.base64EncodedString())
        #EXTINF:6.0,
        segments/segment7.ts
        """
        let adapter = HLSMonitorAdapter(
            manifestSource: "file:///fixtures/manifest-scte35.m3u8",
            manifestText: manifest,
            segmentLoader: StubSegmentLoader(data: makeTransportStreamPacket(section: section)),
            segmentExtractor: HLSSegmentSCTE35Extractor()
        )

        let markers = try await adapter.markers()

        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers.map(\.source), ["hls_manifest", "hls_segment"])
        XCTAssertEqual(markers.map(\.segment), ["7", "7"])
        XCTAssertEqual(markers[1].tag, "mpegts_scte35_section")
        XCTAssertEqual(markers[1].fields["CommandName"], "SPLICE_INSERT_OON_TRUE")
    }

    func testLoaderFailuresWrapAsIngestPhaseMonitorErrorWithRedactedContext() async throws {
        let manifest = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:7
        #EXTINF:6.0,
        https://user:pass@example.test/segments/segment7.ts?token=secret#frag
        """
        let adapter = HLSMonitorAdapter(
            manifestSource: sourceWithSecrets,
            manifestText: manifest,
            segmentLoader: ThrowingSegmentLoader(error: FixtureError.message("failed https://user:pass@example.test/segments/segment7.ts?token=secret#frag")),
            segmentExtractor: HLSSegmentSCTE35Extractor()
        )

        do {
            _ = try await adapter.markers()
            XCTFail("Expected ingest MonitorError")
        } catch let error as MonitorError {
            let description = error.description
            XCTAssertTrue(description.contains("ingest"), description)
            XCTAssertTrue(description.contains("hls"), description)
            XCTAssertTrue(description.contains("https://example.test/live/manifest.m3u8"), description)
            XCTAssertTrue(description.contains("hls_segment"), description)
            XCTAssertTrue(description.contains("mediaSequence=7"), description)
            XCTAssertTrue(description.contains("https://example.test/segments/segment7.ts"), description)
            assertSanitized(description, forbiddenLiteral: sourceWithSecrets)
            assertSanitized(description, forbiddenLiteral: "user:pass")
            assertSanitized(description, forbiddenLiteral: "token=secret")
            assertSanitized(description, forbiddenLiteral: "#frag")
        } catch {
            XCTFail("Expected MonitorError, got \(error)")
        }
    }

    func testSegmentExtractionFailuresWrapAsDecodePhaseMonitorErrorWithRedactedContext() async throws {
        let manifest = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:7
        #EXTINF:6.0,
        https://user:pass@example.test/segments/segment7.ts?token=secret#frag
        """
        let adapter = HLSMonitorAdapter(
            manifestSource: sourceWithSecrets,
            manifestText: manifest,
            segmentLoader: StubSegmentLoader(data: Data([0x47, 0x40, 0x00, 0x10, 0xFC, 0x30, 0xFF])),
            segmentExtractor: HLSSegmentSCTE35Extractor()
        )

        do {
            _ = try await adapter.markers()
            XCTFail("Expected decode MonitorError")
        } catch let error as MonitorError {
            let description = error.description
            XCTAssertTrue(description.contains("decode"), description)
            XCTAssertTrue(description.contains("hls"), description)
            XCTAssertTrue(description.contains("hls_segment"), description)
            XCTAssertTrue(description.contains("mediaSequence=7"), description)
            XCTAssertTrue(description.contains("https://example.test/segments/segment7.ts"), description)
            assertSanitized(description, forbiddenLiteral: sourceWithSecrets)
            assertSanitized(description, forbiddenLiteral: "user:pass")
            assertSanitized(description, forbiddenLiteral: "token=secret")
            assertSanitized(description, forbiddenLiteral: "#frag")
            assertSanitized(description, forbiddenLiteral: Data([0x47, 0x40, 0x00, 0x10, 0xFC, 0x30, 0xFF]).base64EncodedString())
        } catch {
            XCTFail("Expected MonitorError, got \(error)")
        }
    }

    func testSegmentWithoutCandidateEmitsNoSegmentMarker() async throws {
        let manifest = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:7
        #EXT-X-CUE-IN
        #EXTINF:6.0,
        segments/segment7.ts
        """
        let adapter = HLSMonitorAdapter(
            manifestSource: "file:///fixtures/manifest-scte35.m3u8",
            manifestText: manifest,
            segmentLoader: StubSegmentLoader(data: Data(repeating: 0x00, count: 188)),
            segmentExtractor: HLSSegmentSCTE35Extractor()
        )

        let markers = try await adapter.markers()

        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.source, "hls_manifest")
        XCTAssertEqual(markers.first?.segment, "7")
    }

    func testPipelineRunsHLSFixtureAndAppliesMarkerTypeFilter() async throws {
        let fixturePath = hlsFixturePath()
        let options = try MonitorOptions(
            source: fixturePath,
            streamType: .hls,
            filter: "scte35",
            quiet: true,
            emitJSON: true
        )

        let markers = try await MonitorPipeline.run(options: options)

        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers.map(\.type), ["SCTE35", "SCTE35"])
        XCTAssertEqual(markers.map(\.source), ["hls_manifest", "hls_segment"])
        XCTAssertEqual(markers.map(\.segment), ["7", "7"])
    }

    func testPipelineClassifiesHLSFixtureBeforeAdFiltering() async throws {
        let options = try MonitorOptions(
            source: hlsFixturePath(),
            streamType: .hls,
            filter: "ad",
            quiet: true,
            emitJSON: true
        )

        let markers = try await MonitorPipeline.run(options: options)

        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.type, "SCTE35")
        XCTAssertEqual(markers.first?.source, "hls_segment")
        XCTAssertEqual(markers.first?.tag, "mpegts_scte35_section")
        XCTAssertEqual(markers.first?.classification, .adStart)
    }

    func testPipelineAutoDetectsLocalM3U8FixtureAsHLS() async throws {
        let options = try MonitorOptions(
            source: hlsFixturePath(),
            streamType: .auto,
            filter: "all"
        )

        let markers = try await MonitorPipeline.run(options: options)

        XCTAssertEqual(markers.map(\.source), ["hls_manifest", "hls_segment"])
        XCTAssertEqual(markers.map(\.segment), ["7", "7"])
    }

    func testPipelineAutoDetectionTreatsM3U8HTTPURLsAsHLSWithoutLoadingInTest() {
        XCTAssertEqual(
            MonitorPipeline.resolvedStreamType(for: "https://example.test/live/manifest.m3u8?token=secret#frag", requested: .auto),
            .hls
        )
        XCTAssertEqual(
            MonitorPipeline.resolvedStreamType(for: "http://example.test/live/manifest.M3U8", requested: .auto),
            .hls
        )
    }

    func testPipelineAutoNonHLSRemainsUnsupported() async throws {
        let options = try MonitorOptions(
            source: "fixture.aac",
            streamType: .auto,
            filter: "all"
        )

        do {
            _ = try await MonitorPipeline.run(options: options)
            XCTFail("Expected non-HLS auto source to remain unsupported")
        } catch let error as MonitorError {
            guard case let .notImplemented(phase, source, streamType) = error else {
                return XCTFail("Expected notImplemented, got \(error)")
            }
            XCTAssertEqual(phase, .sourceOpen)
            XCTAssertEqual(source, "fixture.aac")
            XCTAssertEqual(streamType, .auto)
        } catch {
            XCTFail("Expected MonitorError, got \(error)")
        }
    }

    func testPipelinePropagatesHLSAdapterErrorsWithoutRewriting() async throws {
        let options = try MonitorOptions(
            source: "missing-fixture.m3u8",
            streamType: .hls,
            filter: "all"
        )

        do {
            _ = try await MonitorPipeline.run(options: options)
            XCTFail("Expected source-open MonitorError")
        } catch let error as MonitorError {
            guard case let .operationFailed(phase, source, streamType, context, _) = error else {
                return XCTFail("Expected operationFailed, got \(error)")
            }
            XCTAssertEqual(phase, .sourceOpen)
            XCTAssertEqual(source, "missing-fixture.m3u8")
            XCTAssertEqual(streamType, .hls)
            XCTAssertEqual(context["sourceClass"], "hls_manifest")
        } catch {
            XCTFail("Expected MonitorError, got \(error)")
        }
    }

    func testHLSMissingPrivateManifestWrapsSourceOpenWithRedactedDescription() async throws {
        let source = "/tmp/user:pass-token=secret/missing-manifest.m3u8?token=secret#frag"
        let adapter = HLSMonitorAdapter(manifestSource: source)

        do {
            _ = try await adapter.markers()
            XCTFail("Expected source-open MonitorError")
        } catch let error as MonitorError {
            let description = error.description
            XCTAssertTrue(description.contains("sourceOpen"), description)
            XCTAssertTrue(description.contains("hls"), description)
            XCTAssertTrue(description.contains("sourceClass=hls_manifest"), description)
            XCTAssertTrue(description.contains("/tmp/"), description)
            XCTAssertTrue(description.contains("missing-manifest.m3u8"), description)
            assertSanitized(description, forbiddenLiteral: source)
            assertSanitized(description, forbiddenLiteral: "user:pass")
            assertSanitized(description, forbiddenLiteral: "token=secret")
            assertSanitized(description, forbiddenLiteral: "#frag")
        } catch {
            XCTFail("Expected MonitorError, got \(error)")
        }
    }

    private func hlsFixturePath() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HLS/manifest-scte35.m3u8")
            .path
    }

    private func makeTransportStreamPacket(section: Data) -> Data {
        var packet = Data(repeating: 0xFF, count: 188)
        packet[0] = 0x47
        packet[1] = 0x40
        packet[2] = 0x00
        packet[3] = 0x10
        packet[4] = 0x00 // pointer field: section begins at next byte
        packet.replaceSubrange(5..<(5 + section.count), with: section)
        return packet
    }

    private func makeSpliceInsertSection(
        eventID: UInt32,
        ptsTicks: UInt64,
        breakDurationTicks: UInt64,
        descriptors: [UInt8] = []
    ) -> Data {
        var command = BitWriter()
        command.write(UInt64(eventID), bits: 32)
        command.write(0, bits: 1)
        command.write(0x7F, bits: 7)
        command.write(1, bits: 1)
        command.write(1, bits: 1)
        command.write(1, bits: 1)
        command.write(0, bits: 1)
        command.write(0x0F, bits: 4)
        command.write(1, bits: 1)
        command.write(0x3F, bits: 6)
        command.write(ptsTicks, bits: 33)
        command.write(1, bits: 1)
        command.write(0x3F, bits: 6)
        command.write(breakDurationTicks, bits: 33)
        command.write(1, bits: 16)
        command.write(1, bits: 8)
        command.write(1, bits: 8)
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

private struct StubSegmentLoader: HLSSegmentLoading {
    let data: Data

    func loadSegment(uri: String, relativeTo manifestSource: String) async throws -> Data {
        data
    }
}

private struct ThrowingSegmentLoader: HLSSegmentLoading {
    let error: Error

    func loadSegment(uri: String, relativeTo manifestSource: String) async throws -> Data {
        throw error
    }
}

private enum FixtureError: Error {
    case message(String)
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
