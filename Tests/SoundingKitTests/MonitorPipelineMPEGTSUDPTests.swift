import Foundation
import XCTest
@testable import SoundingKit

final class MonitorPipelineMPEGTSUDPTests: XCTestCase {
    private let privateSource = "https://user:pass@example.test/live/fixture.ts?token=secret#frag"

    func testMPEGTSAdapterLoadsInjectedHTTPBytesAndMapsSCTE35Markers() async throws {
        let adapter = MPEGTSMonitorAdapter(
            source: privateSource,
            byteLoader: StubByteLoader(data: MPEGTSFixtureBuilder.transportStream())
        )

        let markers = try await adapter.markers()

        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].type, "SCTE35")
        XCTAssertEqual(markers[0].source, "mpegts")
        XCTAssertEqual(markers[0].tag, "mpegts_scte35_section")
        XCTAssertEqual(markers[0].fields["CommandName"], JSONValue.string("SPLICE_NULL"))
        XCTAssertEqual(markers[0].tags["SourceClass"], JSONValue.string("mpegts_stream"))
        XCTAssertEqual(markers[0].tags["StreamType"], JSONValue.string("mpegts"))
    }

    func testPipelineRunsLocalMPEGTSFixtureAndAppliesMarkerTypeFilter() async throws {
        let options = try MonitorOptions(
            source: mpegtsFixturePath(),
            streamType: .mpegts,
            filter: "scte35"
        )

        let markers = try await MonitorPipeline.run(options: options)

        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].type, "SCTE35")
        XCTAssertEqual(markers[0].fields["CommandName"], JSONValue.string("SPLICE_NULL"))
    }

    func testPipelineClassifiesMPEGTSFixtureBeforeUnknownAndAdFiltering() async throws {
        let unknownOptions = try MonitorOptions(
            source: mpegtsFixturePath(),
            streamType: .mpegts,
            filter: "unknown"
        )
        let adOptions = try MonitorOptions(
            source: mpegtsFixturePath(),
            streamType: .mpegts,
            filter: "ad"
        )

        let unknownMarkers = try await MonitorPipeline.run(options: unknownOptions)
        let adMarkers = try await MonitorPipeline.run(options: adOptions)

        XCTAssertEqual(unknownMarkers.count, 1)
        XCTAssertEqual(unknownMarkers.first?.type, "SCTE35")
        XCTAssertEqual(unknownMarkers.first?.source, "mpegts")
        XCTAssertEqual(unknownMarkers.first?.classification, .unknown)
        XCTAssertTrue(adMarkers.isEmpty)
    }

    func testMarkerTypeFilterExcludesMPEGTSMarkers() async throws {
        let options = try MonitorOptions(
            source: mpegtsFixturePath(),
            streamType: .mpegts,
            filter: "id3"
        )

        let markers = try await MonitorPipeline.run(options: options)

        XCTAssertTrue(markers.isEmpty)
    }

    func testUDPReplayAdapterFeedsDatagramsThroughSameExtractionPath() async throws {
        let datagrams = MPEGTSFixtureBuilder.datagrams(from: MPEGTSFixtureBuilder.transportStream())
        let adapter = UDPMonitorAdapter(source: "udp://stream.example.test:5000", datagramLoader: StubDatagramLoader(datagrams: datagrams))

        let markers = try await adapter.markers()

        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].source, "udp")
        XCTAssertEqual(markers[0].tag, "mpegts_scte35_section")
        XCTAssertEqual(markers[0].fields["CommandName"], JSONValue.string("SPLICE_NULL"))
        XCTAssertEqual(markers[0].tags["SourceClass"], JSONValue.string("udp_datagram_replay"))
        XCTAssertEqual(markers[0].tags["StreamType"], JSONValue.string("udp"))
    }

    func testPipelineClassifiesUDPReplayFixtureBeforeUnknownAndAdFiltering() async throws {
        let unknownOptions = try MonitorOptions(
            source: mpegtsFixturePath(),
            streamType: .udp,
            filter: "unknown"
        )
        let adOptions = try MonitorOptions(
            source: mpegtsFixturePath(),
            streamType: .udp,
            filter: "ad"
        )

        let unknownMarkers = try await MonitorPipeline.run(options: unknownOptions)
        let adMarkers = try await MonitorPipeline.run(options: adOptions)

        XCTAssertEqual(unknownMarkers.count, 1)
        XCTAssertEqual(unknownMarkers.first?.type, "SCTE35")
        XCTAssertEqual(unknownMarkers.first?.source, "udp")
        XCTAssertEqual(unknownMarkers.first?.classification, .unknown)
        XCTAssertTrue(adMarkers.isEmpty)
    }

    func testPipelineAutoRoutesTSPathsAndUDPURLs() async throws {
        let mpegtsOptions = try MonitorOptions(source: mpegtsFixturePath(), streamType: .auto, filter: "all")
        let mpegtsMarkers = try await MonitorPipeline.run(options: mpegtsOptions)
        XCTAssertEqual(mpegtsMarkers.map(\.source), ["mpegts"])

        XCTAssertEqual(
            MonitorPipeline.resolvedStreamType(for: "udp://239.0.0.1:5000", requested: .auto),
            .udp
        )
        XCTAssertEqual(
            MonitorPipeline.resolvedStreamType(for: "https://example.test/live/channel.m2ts?token=secret", requested: .auto),
            .mpegts
        )
    }

    func testPackageDoesNotDependOnFFmpegKit() throws {
        let packageURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Package.swift")
        let package = try String(contentsOf: packageURL, encoding: .utf8)

        XCTAssertFalse(package.localizedCaseInsensitiveContains("ffmpegkit"))
        XCTAssertFalse(package.localizedCaseInsensitiveContains("ffmpeg-kit"))
    }

    func testMPEGTSMissingSourceWrapsSourceOpenWithRedactedDescription() async throws {
        let source = "/tmp/private-token-secret/missing.ts?token=secret#frag"
        let adapter = MPEGTSMonitorAdapter(source: source)

        do {
            _ = try await adapter.markers()
            XCTFail("Expected source-open MonitorError")
        } catch let error as MonitorError {
            let description = error.description
            XCTAssertTrue(description.contains("sourceOpen"), description)
            XCTAssertTrue(description.contains("sourceClass=mpegts_stream"), description)
            XCTAssertFalse(description.contains("token=secret"), description)
            XCTAssertFalse(description.contains("#frag"), description)
        } catch {
            XCTFail("Expected MonitorError, got \(error)")
        }
    }

    func testMPEGTSMalformedPacketsWrapAsIngestWithoutRawBytesOrSecrets() async throws {
        let malformed = MPEGTSFixtureBuilder.malformedAdaptationFieldPacket()
        let adapter = MPEGTSMonitorAdapter(
            source: privateSource,
            byteLoader: StubByteLoader(data: malformed)
        )

        do {
            _ = try await adapter.markers()
            XCTFail("Expected ingest MonitorError")
        } catch let error as MonitorError {
            let description = error.description
            XCTAssertTrue(description.contains("ingest"), description)
            XCTAssertTrue(description.contains("sourceClass=mpegts_stream"), description)
            XCTAssertTrue(description.contains("packetCount=1"), description)
            assertSanitized(description, forbiddenLiteral: privateSource)
            assertSanitized(description, forbiddenLiteral: malformed.base64EncodedString())
            assertSanitized(description, forbiddenLiteral: "user:pass")
            assertSanitized(description, forbiddenLiteral: "token=secret")
        } catch {
            XCTFail("Expected MonitorError, got \(error)")
        }
    }

    func testMPEGTSMalformedSCTE35SectionWrapsAsDecodeWithoutPayloadBytes() async throws {
        let malformedSection = Data([0xFC, 0x30, 0x00])
        let adapter = MPEGTSMonitorAdapter(
            source: privateSource,
            byteLoader: StubByteLoader(data: Data()),
            sectionExtractor: StubSectionExtractor(sections: [malformedSection])
        )

        do {
            _ = try await adapter.markers()
            XCTFail("Expected decode MonitorError")
        } catch let error as MonitorError {
            let description = error.description
            XCTAssertTrue(description.contains("decode"), description)
            XCTAssertTrue(description.contains("sourceClass=mpegts_stream"), description)
            XCTAssertTrue(description.contains("sectionCount=1"), description)
            XCTAssertTrue(description.contains("tag=mpegts_scte35_section"), description)
            assertSanitized(description, forbiddenLiteral: malformedSection.base64EncodedString())
            assertSanitized(description, forbiddenLiteral: "token=secret")
        } catch {
            XCTFail("Expected MonitorError, got \(error)")
        }
    }

    func testUnsupportedUDPQueryStringFailsSourceOpenWithoutLeakingURLSecrets() async throws {
        let source = "udp://user:pass@example.test:5000/live?token=secret&mode=live#frag"
        let adapter = UDPMonitorAdapter(source: source)

        do {
            _ = try await adapter.markers()
            XCTFail("Expected source-open MonitorError")
        } catch let error as MonitorError {
            let description = error.description
            XCTAssertTrue(description.contains("sourceOpen"), description)
            XCTAssertTrue(description.contains("sourceClass=udp_datagram_replay"), description)
            XCTAssertTrue(description.contains("unsupported"), description.lowercased())
            assertSanitized(description, forbiddenLiteral: source)
            assertSanitized(description, forbiddenLiteral: "user:pass")
            assertSanitized(description, forbiddenLiteral: "token=secret")
            assertSanitized(description, forbiddenLiteral: "#frag")
        } catch {
            XCTFail("Expected MonitorError, got \(error)")
        }
    }

    func testEmptyUDPDatagramStreamEmitsNoMarkers() async throws {
        let adapter = UDPMonitorAdapter(source: "udp://stream.example.test:5000", datagramLoader: StubDatagramLoader(datagrams: []))

        let markers = try await adapter.markers()

        XCTAssertTrue(markers.isEmpty)
    }

    func testUDPMalformedDatagramWrapsAsIngestWithoutDatagramContents() async throws {
        let malformed = Data([0x47, 0x40, 0x00])
        let adapter = UDPMonitorAdapter(source: privateSource, datagramLoader: StubDatagramLoader(datagrams: [malformed]))

        do {
            _ = try await adapter.markers()
            XCTFail("Expected ingest MonitorError")
        } catch let error as MonitorError {
            let description = error.description
            XCTAssertTrue(description.contains("ingest"), description)
            XCTAssertTrue(description.contains("sourceClass=udp_datagram_replay"), description)
            XCTAssertTrue(description.contains("datagramCount=1"), description)
            assertSanitized(description, forbiddenLiteral: malformed.base64EncodedString())
            assertSanitized(description, forbiddenLiteral: "token=secret")
        } catch {
            XCTFail("Expected MonitorError, got \(error)")
        }
    }

    func testUDPMalformedSCTE35SectionWrapsAsDecodeWithoutSectionPayload() async throws {
        let malformedSection = Data([0xFC, 0x30, 0x04, 0x00, 0x00, 0x00, 0x00])
        let malformedStream = MPEGTSFixtureBuilder.transportStream(section: malformedSection)
        let adapter = UDPMonitorAdapter(
            source: privateSource,
            datagramLoader: StubDatagramLoader(datagrams: MPEGTSFixtureBuilder.datagrams(from: malformedStream))
        )

        do {
            _ = try await adapter.markers()
            XCTFail("Expected decode MonitorError")
        } catch let error as MonitorError {
            let description = error.description
            XCTAssertTrue(description.contains("decode"), description)
            XCTAssertTrue(description.contains("sourceClass=udp_datagram_replay"), description)
            XCTAssertTrue(description.contains("datagramCount=1"), description)
            XCTAssertTrue(description.contains("sectionCount=1"), description)
            XCTAssertTrue(description.contains("tag=mpegts_scte35_section"), description)
            assertSanitized(description, forbiddenLiteral: malformedSection.base64EncodedString())
            assertSanitized(description, forbiddenLiteral: "token=secret")
        } catch {
            XCTFail("Expected MonitorError, got \(error)")
        }
    }

    private func mpegtsFixturePath() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/MPEGTS/scte35_splice_null.ts")
            .path
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

private struct StubByteLoader: MPEGTSByteLoading {
    let data: Data

    func loadBytes(from source: String) async throws -> Data {
        data
    }
}

private struct StubDatagramLoader: UDPDatagramLoading {
    let datagrams: [Data]

    func loadDatagrams(from source: String) async throws -> [Data] {
        datagrams
    }
}

private struct StubSectionExtractor: MPEGTSSectionExtracting {
    let sections: [Data]

    func extractSections(from data: Data) throws -> [Data] {
        sections
    }
}
