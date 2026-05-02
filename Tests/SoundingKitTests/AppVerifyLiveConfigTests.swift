import Foundation
import XCTest

@testable import SoundingKit

final class AppVerifyLiveConfigTests: XCTestCase {
    private let privateHLS = "https://viewer:letmein@example.test/live/manifest.m3u8?token=synthetic-secret#private-fragment"
    private let privateHTTP = "https://viewer:letmein@example.test/radio/stream?access_token=synthetic-secret#private-fragment"

    func testDecodesAutoHLSAndAppliesBoundedDefaults() throws {
        let json = #"""
        {
          "streams": [
            { "id": "main-hls", "source": "https://example.test/live/main.m3u8" },
            { "id": "generic-icy", "source": "https://example.test/radio", "streamType": "icy", "required": false }
          ]
        }
        """#

        let config = try JSONDecoder().decode(AppVerifyLiveConfiguration.self, from: Data(json.utf8))

        XCTAssertEqual(config.streams.count, 2)
        XCTAssertEqual(config.streams[0].streamType, .auto)
        XCTAssertEqual(config.streams[0].resolvedStreamType, .hls)
        XCTAssertEqual(config.streams[0].timeoutSeconds, AppVerifyLiveConfiguration.defaultTimeoutSeconds)
        XCTAssertEqual(config.streams[0].maxChunks, AppVerifyLiveConfiguration.defaultMaxChunks)
        XCTAssertTrue(config.streams[0].required)
        XCTAssertEqual(config.streams[0].expectations.transcript, .warn)
        XCTAssertEqual(config.streams[0].expectations.metadata, .warn)
        XCTAssertEqual(config.streams[0].redactedSource, "https://example.test/live/main.m3u8")
        XCTAssertEqual(config.streams[1].resolvedStreamType, .icy)
        XCTAssertFalse(config.streams[1].required)
    }

    func testRejectsMalformedConfigBoundaryWithRedactedMessages() {
        let cases: [(String, String)] = [
            (#"{"streams":[]}"#, "at least one stream"),
            (#"{"streams":[{"id":"   ","source":"https://example.test/live.m3u8"}]}"#, "id must not be blank"),
            (#"{"streams":[{"id":"blank-source","source":"   "}]}"#, "source must not be blank"),
            (#"{"streams":[{"id":"mpegts-live","source":"https://example.test/live.ts","streamType":"mpegts"}]}"#, "unsupported stream type"),
            (#"{"streams":[{"id":"udp-live","source":"udp://example.test:5000/live","streamType":"udp"}]}"#, "unsupported stream type"),
            (#"{"streams":[{"id":"auto-http","source":"https://example.test/radio"}]}"#, "auto stream type could not be resolved"),
            (#"{"streams":[{"id":"negative-timeout","source":"https://example.test/live.m3u8","timeoutSeconds":-1}]}"#, "timeoutSeconds"),
            (#"{"streams":[{"id":"huge-timeout","source":"https://example.test/live.m3u8","timeoutSeconds":9999}]}"#, "timeoutSeconds"),
            (#"{"streams":[{"id":"huge-chunks","source":"https://example.test/live.m3u8","maxChunks":9999}]}"#, "maxChunks"),
            (#"{"streams":[{"id":"optional-strict","source":"https://example.test/live.m3u8","required":false,"expectations":{"transcript":"strict"}}]}"#, "optional streams cannot use strict"),
        ]

        for (json, expected) in cases {
            XCTAssertThrowsError(try JSONDecoder().decode(AppVerifyLiveConfiguration.self, from: Data(json.utf8)), "Expected failure for \(json)") { error in
                let description = String(describing: error)
                XCTAssertTrue(description.contains(expected), description)
                assertSanitized(description)
            }
        }
    }

    func testExplicitIcecastAndIcyAreAcceptedForGenericHTTPSources() throws {
        let config = try AppVerifyLiveConfiguration(streams: [
            AppVerifyLiveStreamSpec(id: "icecast", source: privateHTTP, streamType: .icecast),
            AppVerifyLiveStreamSpec(id: "icy", source: privateHTTP, streamType: .icy),
        ])

        XCTAssertEqual(config.streams.map(\.resolvedStreamType), [.icecast, .icy])
        XCTAssertEqual(config.streams.map(\.redactedSource), [
            "https://example.test/radio/stream",
            "https://example.test/radio/stream",
        ])
    }

    func testLiveExpectationEvaluatorsUseWarnByDefaultAndFailWhenStrict() {
        let warnTranscript = AppVerifyCheckEvaluator.liveTranscriptExpectation(
            observedCount: 0,
            expectation: .warn,
            required: true,
            streamID: "main",
            source: privateHLS
        )
        XCTAssertEqual(warnTranscript.name, .liveTranscriptObserved)
        XCTAssertEqual(warnTranscript.status, .warn)
        XCTAssertFalse(warnTranscript.required)

        let strictTranscript = AppVerifyCheckEvaluator.liveTranscriptExpectation(
            observedCount: 0,
            expectation: .strict,
            required: true,
            streamID: "main",
            source: privateHLS
        )
        XCTAssertEqual(strictTranscript.status, .fail)
        XCTAssertTrue(strictTranscript.required)

        let strictMetadata = AppVerifyCheckEvaluator.liveMetadataExpectation(
            observedCount: 0,
            expectation: .strict,
            required: true,
            streamID: "main",
            source: privateHLS
        )
        XCTAssertEqual(strictMetadata.name, .liveMetadataObserved)
        XCTAssertEqual(strictMetadata.status, .fail)
        XCTAssertTrue(strictMetadata.required)

        let summary = AppVerifyEvidenceSummary.aggregate([warnTranscript])
        XCTAssertEqual(summary.status, .warn)
        XCTAssertEqual(summary.failedRequiredCheckCount, 0)
        XCTAssertEqual(summary.warningCheckCount, 1)
    }

    func testLiveEvidenceFactsAndArtifactsAreBoundedAndRedacted() throws {
        let facts = AppVerifyLiveStreamFacts(
            streamID: "main token=synthetic-secret",
            streamType: .auto,
            resolvedStreamType: .hls,
            source: privateHLS,
            timeoutSeconds: 9,
            maxChunks: 3,
            required: true,
            transcriptExpectation: .warn,
            metadataExpectation: .strict,
            registeredStreamID: 123,
            processedChunks: 2,
            decodedChunks: 1,
            scheduledBuffers: 1,
            transcriptCount: 0,
            metadataCount: 0,
            diagnosticCount: 2,
            recentDiagnosticEvents: ["opened \(privateHLS)", "/tmp/private-output.json?token=synthetic-secret"],
            fields: [
                "configPath": "/Users/alice/app-verify-live.local.json",
                "outputPath": "/tmp/app-verify-live-evidence.json",
                "url": privateHLS
            ]
        )
        let check = AppVerifyCheckRecord.warn(
            .liveTranscriptObserved,
            phase: .liveTranscript,
            reason: "missing transcript for \(privateHLS) from /Users/alice/app-verify-live.local.json to /tmp/app-verify-live-evidence.json",
            liveFacts: facts,
            artifacts: [
                AppVerifyRedactedArtifact(kind: "config", path: "/Users/alice/app-verify-live.local.json"),
                AppVerifyRedactedArtifact(kind: "evidence", path: "/tmp/app-verify-live-evidence.json?token=synthetic-secret"),
            ]
        )
        let evidence = AppVerifyEvidence(
            generatedAt: "2026-05-02T18:00:00Z",
            runID: "live-run-token=synthetic-secret",
            checks: [check]
        )

        let json = try XCTUnwrap(String(data: try evidence.jsonData(), encoding: .utf8))
        XCTAssertTrue(json.contains(#""liveFacts""#), json)
        XCTAssertTrue(json.contains(#""live_transcript_observed""#), json)
        XCTAssertTrue(json.contains(#""redactedSource":"https://example.test/live/manifest.m3u8""#), json)
        assertSanitized(json)
        XCTAssertFalse(json.contains("/Users/alice"), json)
        XCTAssertFalse(json.contains("/tmp/app-verify"), json)
        XCTAssertFalse(json.contains("outputPath"), json)
        XCTAssertFalse(json.contains("configPath"), json)
    }

    private func assertSanitized(_ value: String, file: StaticString = #filePath, line: UInt = #line) {
        for forbidden in [
            "viewer",
            "letmein",
            "token=synthetic-secret",
            "access_token=synthetic-secret",
            "synthetic-secret",
            "private-fragment",
            "#private",
            "?token",
            "?access_token"
        ] {
            XCTAssertFalse(
                value.contains(forbidden),
                "Live app-verify contract leaked forbidden literal '\(forbidden)': \(value)",
                file: file,
                line: line
            )
        }
    }
}
