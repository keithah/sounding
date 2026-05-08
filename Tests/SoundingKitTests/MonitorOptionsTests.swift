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

    func testURLSourceRedactionRemovesCredentialsQueryAndFragment() {
        let description = MonitorError.redactedSourceDescription("https://viewer:letmein@example.test/live/manifest.m3u8?token=synthetic-secret#private-fragment")

        XCTAssertEqual(description, "https://example.test/live/manifest.m3u8", description)
        XCTAssertFalse(description.contains("viewer"), description)
        XCTAssertFalse(description.contains("letmein"), description)
        XCTAssertFalse(description.contains("token="), description)
        XCTAssertFalse(description.contains("synthetic-secret"), description)
        XCTAssertFalse(description.contains("private-fragment"), description)
        XCTAssertFalse(description.contains("?"), description)
        XCTAssertFalse(description.contains("#"), description)
    }

    func testRelativeSourceRedactionRemovesSecretLikePathComponents() {
        let description = MonitorError.redactedSourceDescription("/tmp/output/user:pass-token=secret-api_key=hunter2/out.ndjson")

        XCTAssertTrue(description.contains("[redacted-path]/out.ndjson"), description)
        XCTAssertFalse(description.contains("user:pass"), description)
        XCTAssertFalse(description.contains("token=secret"), description)
        XCTAssertFalse(description.contains("api_key=hunter2"), description)
        XCTAssertFalse(description.contains("hunter2"), description)
    }

    func testOperationFailureFullyMasksOutputPathContextValues() {
        let outputPath = "/tmp/sounding-output/user:pass-token=secret-api_key=hunter2/private.ndjson"
        let error = MonitorError.operationFailed(
            phase: .output,
            source: "fixture.ts",
            streamType: .mpegts,
            context: [
                "attempt": "1",
                "outputPath": outputPath,
            ],
            reason: "could not write to \(outputPath)"
        )

        let description = error.description
        XCTAssertTrue(description.contains("Monitor output failed"), description)
        XCTAssertTrue(description.contains("outputPath=[redacted]"), description)
        XCTAssertTrue(description.contains("attempt=1"), description)
        XCTAssertFalse(description.contains(outputPath), description)
        XCTAssertFalse(description.contains("user:pass"), description)
        XCTAssertFalse(description.contains("token=secret"), description)
        XCTAssertFalse(description.contains("api_key=hunter2"), description)
        XCTAssertFalse(description.contains("hunter2"), description)
        XCTAssertFalse(description.contains("private.ndjson"), description)
    }

    func testOperationFailureMasksAlternateOutputPathContextKeys() {
        let error = MonitorError.operationFailed(
            phase: .output,
            source: "fixture.ts",
            streamType: .mpegts,
            context: [
                "jsonOut": "/tmp/private-json-out.ndjson",
                "path": "/tmp/private-path.ndjson",
            ],
            reason: "write failed"
        )

        let description = error.description
        XCTAssertTrue(description.contains("jsonOut=[redacted]"), description)
        XCTAssertTrue(description.contains("path=[redacted]"), description)
        XCTAssertFalse(description.contains("private-json-out"), description)
        XCTAssertFalse(description.contains("private-path"), description)
    }

    func testPipelineMPEGTSSourceOpenFailuresAreRedactedOperationErrors() async throws {
        let options = try MonitorOptions(
            source: "file:///tmp/missing-live.ts?token=secret#frag",
            streamType: .mpegts,
            filter: "all"
        )

        do {
            _ = try await MonitorPipeline.run(options: options)
            XCTFail("Expected MPEG-TS monitor pipeline source-open failure")
        } catch let error as MonitorError {
            guard case let .operationFailed(phase, source, streamType, context, _) = error else {
                return XCTFail("Expected operationFailed, got \(error)")
            }

            XCTAssertEqual(phase, .sourceOpen)
            XCTAssertEqual(source, options.source)
            XCTAssertEqual(streamType, .mpegts)
            XCTAssertEqual(context["sourceClass"], "mpegts_stream")

            let description = error.description
            XCTAssertTrue(description.contains("sourceOpen"))
            XCTAssertTrue(description.contains("mpegts"))
            XCTAssertTrue(description.contains("file:///tmp/missing-live.ts"))
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
