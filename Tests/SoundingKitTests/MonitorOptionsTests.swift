import XCTest
@testable import SoundingKit

final class MonitorOptionsTests: XCTestCase {
    func testNormalizesStreamTypesAndMarkerFilters() throws {
        let options = try MonitorOptions(
            source: "fixture.ts",
            streamType: .hls,
            filter: "scte35",
            jsonOut: nil,
            timeoutSeconds: 10,
            quiet: false,
            emitJSON: true
        )

        XCTAssertEqual(options.streamType, .hls)
        XCTAssertEqual(options.filter, .markerType("scte35"))
        XCTAssertEqual(try MonitorFilter(normalizing: "SCTE35"), .markerType("scte35"))
        XCTAssertEqual(try MonitorFilter(normalizing: " id3 "), .markerType("id3"))
        XCTAssertEqual(try MonitorFilter(normalizing: "icy"), .markerType("icy"))
    }

    func testNormalizesAdAndClassificationFilters() throws {
        XCTAssertEqual(try MonitorFilter(normalizing: "all"), .all)
        XCTAssertEqual(try MonitorFilter(normalizing: "ad"), .ad)
        XCTAssertEqual(try MonitorFilter(normalizing: "AD_START"), .classification(.adStart))
        XCTAssertEqual(try MonitorFilter(normalizing: "ad-end"), .classification(.adEnd))
        XCTAssertEqual(try MonitorFilter(normalizing: "unknown"), .classification(.unknown))
    }

    func testRejectsUnknownFilterInSoundingKit() {
        XCTAssertThrowsError(try MonitorFilter(normalizing: "bogus")) { error in
            guard let monitorError = error as? MonitorError,
                  case let .invalidFilter(filter) = monitorError else {
                return XCTFail("Expected invalidFilter, got \(error)")
            }

            XCTAssertEqual(filter, "bogus")
            XCTAssertTrue(monitorError.description.contains("Monitor configuration failed"))
        }
    }

    func testRejectsNegativeTimeoutBeforeRuntime() {
        XCTAssertThrowsError(
            try MonitorOptions(
                source: "fixture.ts",
                streamType: .auto,
                timeoutSeconds: -1
            )
        ) { error in
            guard let monitorError = error as? MonitorError,
                  case let .invalidTimeout(timeout, _, streamType) = monitorError else {
                return XCTFail("Expected invalidTimeout, got \(error)")
            }

            XCTAssertEqual(timeout, -1)
            XCTAssertEqual(streamType, .auto)
            XCTAssertTrue(monitorError.description.contains("configuration"))
        }
    }

    func testPipelineKeepsUnsupportedTypesAsRedactedNotImplementedErrors() async throws {
        let options = try MonitorOptions(
            source: "https://user:pass@example.test/live.ts?token=secret#frag",
            streamType: .icecast,
            filter: "all"
        )

        do {
            _ = try await MonitorPipeline.run(options: options)
            XCTFail("Expected unsupported monitor pipeline source to throw")
        } catch let error as MonitorError {
            guard case let .notImplemented(phase, source, streamType) = error else {
                return XCTFail("Expected notImplemented, got \(error)")
            }

            XCTAssertEqual(phase, .sourceOpen)
            XCTAssertEqual(source, options.source)
            XCTAssertEqual(streamType, .icecast)

            let description = error.description
            XCTAssertTrue(description.contains("sourceOpen"))
            XCTAssertTrue(description.contains("icecast"))
            XCTAssertTrue(description.contains("https://example.test/live.ts"))
            XCTAssertFalse(description.contains("user"))
            XCTAssertFalse(description.contains("pass"))
            XCTAssertFalse(description.contains("token"))
            XCTAssertFalse(description.contains("secret"))
            XCTAssertFalse(description.contains("?"))
            XCTAssertFalse(description.contains("#frag"))
        } catch {
            XCTFail("Expected MonitorError, got \(error)")
        }
    }

    func testFilterIncludesCentralizesMarkerMatchingSemantics() throws {
        let scte35Unknown = AdMarker(type: "SCTE35", classification: .unknown, source: "hls_manifest")
        let lowercasedSCTE35AdStart = AdMarker(type: "scte35", classification: .adStart, source: "hls_segment")
        let id3AdEnd = AdMarker(type: "ID3", classification: .adEnd, source: "fixture")

        XCTAssertTrue(MonitorFilter.all.includes(scte35Unknown))
        XCTAssertFalse(MonitorFilter.ad.includes(scte35Unknown))
        XCTAssertTrue(MonitorFilter.ad.includes(lowercasedSCTE35AdStart))
        XCTAssertTrue(MonitorFilter.ad.includes(id3AdEnd))
        XCTAssertTrue(MonitorFilter.classification(.unknown).includes(scte35Unknown))
        XCTAssertFalse(MonitorFilter.classification(.adEnd).includes(lowercasedSCTE35AdStart))
        XCTAssertTrue(MonitorFilter.markerType("scte35").includes(scte35Unknown))
        XCTAssertTrue(MonitorFilter.markerType("SCTE35").includes(lowercasedSCTE35AdStart))
        XCTAssertFalse(MonitorFilter.markerType("scte35").includes(id3AdEnd))
    }
}
