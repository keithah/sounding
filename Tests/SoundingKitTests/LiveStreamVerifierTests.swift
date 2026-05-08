import Foundation
import XCTest
@testable import SoundingKit

final class LiveStreamVerifierTests: XCTestCase {
    private let privateSource = "https://viewer:letmein@example.test/live/manifest.m3u8?token=synthetic-secret#private-fragment"

    override func tearDown() {
        MonitorPipeline.icyAdapterFactory = MonitorPipeline.defaultICYAdapterFactory
        super.tearDown()
    }

    func testConfigRejectsMalformedInputsWithoutEchoingRawSources() throws {
        XCTAssertThrowsError(try LiveStreamVerificationConfig(streams: [])) { error in
            XCTAssertTrue(String(describing: error).contains("at least one stream"))
        }

        XCTAssertThrowsError(try LiveStreamVerificationConfig(streams: [
            LiveStreamSpec(id: "bad-timeout", source: privateSource, timeoutSeconds: -1)
        ])) { error in
            let description = String(describing: error)
            XCTAssertTrue(description.contains("bad-timeout"), description)
            assertSanitized(description)
        }

        XCTAssertThrowsError(try LiveStreamVerificationConfig(streams: [
            LiveStreamSpec(id: "bad-filter", source: privateSource, filter: "definitely-not-a-filter")
        ])) { error in
            let description = String(describing: error)
            XCTAssertTrue(description.contains("bad-filter"), description)
            XCTAssertFalse(description.contains("definitely-not-a-filter"), description)
            assertSanitized(description)
        }

        let invalidTypeJSON = #"{"streams":[{"id":"bad-type","source":"https://viewer:letmein@example.test/live.m3u8?token=synthetic-secret#frag","streamType":"rtmp","filter":"all","minimumMarkers":1,"required":true}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(LiveStreamVerificationConfig.self, from: Data(invalidTypeJSON.utf8))) { error in
            let description = String(describing: error)
            XCTAssertFalse(description.contains("letmein"), description)
            XCTAssertFalse(description.contains("synthetic-secret"), description)
            XCTAssertFalse(description.contains("#frag"), description)
        }
    }

    func testFixtureSuccessProducesCodableRedactedEvidence() async throws {
        let verifier = LiveStreamVerifier()
        let config = try LiveStreamVerificationConfig(streams: [
            LiveStreamSpec(
                id: "fixture-mpegts",
                source: mpegtsFixturePath(),
                streamType: .mpegts,
                filter: "scte35",
                timeoutSeconds: 5,
                minimumMarkers: 1,
                required: true
            )
        ])

        let summary = await verifier.verify(config: config)

        XCTAssertTrue(summary.passed)
        XCTAssertEqual(summary.requiredFailures, 0)
        XCTAssertEqual(summary.results.count, 1)
        let result = try XCTUnwrap(summary.results.first)
        XCTAssertEqual(result.category, .passed)
        XCTAssertEqual(result.markerCount, 1)
        XCTAssertEqual(result.streamType, .mpegts)
        XCTAssertEqual(result.resolvedStreamType, .mpegts)
        XCTAssertEqual(result.filter, "scte35")
        XCTAssertEqual(result.timeoutSeconds, 5)
        XCTAssertEqual(result.minimumMarkers, 1)
        XCTAssertTrue(result.required)
        XCTAssertNil(result.diagnostic)

        let json = try verifier.encodeSummaryJSON(summary)
        let decoded = try JSONDecoder().decode(LiveStreamVerificationSummary.self, from: json)
        XCTAssertEqual(decoded.results.first?.category, .passed)
    }

    func testMissingSourceClassifiesStreamUnavailableAndRedactsEvidence() async throws {
        let verifier = LiveStreamVerifier()
        let source = "file:///tmp/private/missing-live.ts?token=synthetic-secret#frag"
        let results = await verifier.verify(streams: [
            LiveStreamSpec(id: "missing", source: source, streamType: .mpegts, filter: "all")
        ])

        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.category, .streamUnavailable)
        XCTAssertEqual(result.markerCount, 0)
        XCTAssertEqual(result.diagnostic?.phase, "sourceOpen")
        XCTAssertEqual(result.diagnostic?.sourceClass, "mpegts_stream")
        XCTAssertEqual(result.redactedSource, "file:///tmp/private/missing-live.ts")

        let json = try String(data: verifier.encodeResultsNDJSON(results), encoding: .utf8).unwrap()
        XCTAssertTrue(json.contains("stream_unavailable"), json)
        assertSanitized(json)
        XCTAssertFalse(json.contains(source), json)
    }

    func testTimeoutClassifiesTimeoutWithSanitizedDiagnostic() async throws {
        MonitorPipeline.icyAdapterFactory = { source, streamType in
            ICYMonitorAdapter(source: source, streamType: streamType) { _, _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return ICYMonitorAdapter.OpenedStream(responseHeaders: [:], streamBytes: Data())
            }
        }
        let verifier = LiveStreamVerifier()
        let results = await verifier.verify(streams: [
            LiveStreamSpec(
                id: "slow-icy",
                source: privateSource,
                streamType: .icy,
                filter: "all",
                timeoutSeconds: 0.001
            )
        ])

        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.category, .timeout)
        XCTAssertEqual(result.diagnostic?.phase, "ingest")
        XCTAssertEqual(result.diagnostic?.context["timeoutSeconds"], "0.001")
        XCTAssertEqual(result.redactedSource, "https://example.test/live/manifest.m3u8")

        let json = try String(data: verifier.encodeResultsNDJSON(results), encoding: .utf8).unwrap()
        XCTAssertTrue(json.contains("timeout"), json)
        assertSanitized(json)
    }

    func testUnsupportedLiveUDPClassifiesUnsupportedOrSkipped() async throws {
        let verifier = LiveStreamVerifier()
        let source = "udp://viewer:letmein@example.test:5000/live?token=synthetic-secret#frag"
        let results = await verifier.verify(streams: [
            LiveStreamSpec(id: "live-udp", source: source, streamType: .udp, filter: "all")
        ])

        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.category, .unsupportedOrSkipped)
        XCTAssertEqual(result.diagnostic?.phase, "sourceOpen")
        XCTAssertEqual(result.diagnostic?.sourceClass, "udp_datagram_replay")
        XCTAssertEqual(result.redactedSource, "udp://example.test:5000/live")

        let json = try String(data: verifier.encodeResultsNDJSON(results), encoding: .utf8).unwrap()
        XCTAssertTrue(json.contains("unsupported_or_skipped"), json)
        assertSanitized(json)
    }

    func testNoMarkersObservedUnlessMinimumMarkersIsZero() async throws {
        MonitorPipeline.icyAdapterFactory = { source, streamType in
            ICYMonitorAdapter(source: source, streamType: streamType) { _, _ in
                ICYMonitorAdapter.OpenedStream(
                    responseHeaders: ["icy-metaint": "4"],
                    streamBytes: Data([0x41, 0x41, 0x41, 0x41, 0x00])
                )
            }
        }
        let verifier = LiveStreamVerifier()
        let results = await verifier.verify(streams: [
            LiveStreamSpec(id: "requires-marker", source: "https://example.test/empty", streamType: .icy, minimumMarkers: 1),
            LiveStreamSpec(id: "allows-empty", source: "https://example.test/empty", streamType: .icy, minimumMarkers: 0)
        ])

        XCTAssertEqual(results.map(\.category), [.noMarkersObserved, .passed])
        XCTAssertEqual(results.map(\.markerCount), [0, 0])
    }

    func testOptionalFailuresDoNotFailSummary() async throws {
        let verifier = LiveStreamVerifier()
        let config = try LiveStreamVerificationConfig(streams: [
            LiveStreamSpec(id: "required-good", source: mpegtsFixturePath(), streamType: .mpegts, minimumMarkers: 1, required: true),
            LiveStreamSpec(id: "optional-missing", source: "/tmp/private/missing-optional.ts?token=synthetic-secret#frag", streamType: .mpegts, required: false)
        ])

        let summary = await verifier.verify(config: config)

        XCTAssertTrue(summary.passed)
        XCTAssertEqual(summary.requiredFailures, 0)
        XCTAssertEqual(summary.optionalFailures, 1)
        XCTAssertEqual(summary.results.map(\.category), [.passed, .streamUnavailable])
    }

    private func mpegtsFixturePath() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/MPEGTS/scte35_splice_null.ts")
            .path
    }

    private func assertSanitized(_ value: String, file: StaticString = #filePath, line: UInt = #line) {
        for forbidden in [
            "viewer",
            "letmein",
            "token=synthetic-secret",
            "synthetic-secret",
            "private-fragment",
            "#frag",
            "?token"
        ] {
            XCTAssertFalse(
                value.contains(forbidden),
                "Evidence leaked forbidden literal '\(forbidden)': \(value)",
                file: file,
                line: line
            )
        }
    }
}

private extension Optional where Wrapped == String {
    func unwrap(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        switch self {
        case let .some(value):
            return value
        case .none:
            XCTFail("Expected non-nil string", file: file, line: line)
            throw LiveStreamVerifierTestError.unexpectedNil
        }
    }
}

private enum LiveStreamVerifierTestError: Error {
    case unexpectedNil
}
