import Foundation
import XCTest
@testable import SoundingKit

final class MonitorPipelineTimeoutTests: XCTestCase {
    private let privateSource = "https://user:pass@example.test/live?token=secret#frag"

    override func tearDown() {
        MonitorPipeline.icyAdapterFactory = MonitorPipeline.defaultICYAdapterFactory
        super.tearDown()
    }

    func testNilTimeoutPreservesExistingPipelineBehavior() async throws {
        MonitorPipeline.icyAdapterFactory = { source, streamType in
            ICYMonitorAdapter(source: source, streamType: streamType) { _, _ in
                ICYMonitorAdapter.OpenedStream(
                    responseHeaders: ["icy-metaint": "4"],
                    streamBytes: Self.icyStream(metaInt: 4, titles: ["Promo Spot"])
                )
            }
        }
        let options = try MonitorOptions(
            source: privateSource,
            streamType: .icy,
            filter: "ad",
            timeoutSeconds: nil
        )

        let markers = try await MonitorPipeline.run(options: options)

        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.type, "ICY")
        XCTAssertEqual(markers.first?.classification, .adStart)
    }

    func testConfiguredTimeoutFailsWithRedactedMonitorErrorAndCancelsAdapterWork() async throws {
        let cancellation = CancellationProbe()
        MonitorPipeline.icyAdapterFactory = { source, streamType in
            ICYMonitorAdapter(source: source, streamType: streamType) { _, _ in
                try await withTaskCancellationHandler {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return ICYMonitorAdapter.OpenedStream(responseHeaders: [:], streamBytes: Data())
                } onCancel: {
                    Task { await cancellation.markCancelled() }
                }
            }
        }
        let options = try MonitorOptions(
            source: privateSource,
            streamType: .icy,
            filter: "all",
            timeoutSeconds: 0.001
        )

        do {
            _ = try await MonitorPipeline.run(options: options)
            XCTFail("Expected configured monitor timeout")
        } catch let error as MonitorError {
            guard case let .operationFailed(phase, source, streamType, context, _) = error else {
                return XCTFail("Expected operationFailed, got \(error)")
            }

            XCTAssertEqual(phase, .ingest)
            XCTAssertEqual(source, privateSource)
            XCTAssertEqual(streamType, .icy)
            XCTAssertEqual(context["sourceClass"], "icy_stream")
            XCTAssertEqual(context["streamType"], "icy")
            XCTAssertEqual(context["timeoutSeconds"], "0.001")

            let description = error.description
            XCTAssertTrue(description.contains("Monitor ingest failed"), description)
            XCTAssertTrue(description.contains("timeoutSeconds=0.001"), description)
            XCTAssertTrue(description.contains("https://example.test/live"), description)
            XCTAssertFalse(description.contains("user:pass"), description)
            XCTAssertFalse(description.contains("token=secret"), description)
            XCTAssertFalse(description.contains("#frag"), description)
            XCTAssertFalse(description.contains("?token"), description)
        } catch {
            XCTFail("Expected MonitorError, got \(error)")
        }

        XCTAssertTrue(await cancellation.waitUntilCancelled(), "Timed-out adapter task was not cancelled")
    }

    func testVerySmallPositiveTimeoutDoesNotHang() async throws {
        MonitorPipeline.icyAdapterFactory = { source, streamType in
            ICYMonitorAdapter(source: source, streamType: streamType) { _, _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return ICYMonitorAdapter.OpenedStream(responseHeaders: [:], streamBytes: Data())
            }
        }
        let options = try MonitorOptions(
            source: "https://example.test/live",
            streamType: .icecast,
            filter: "all",
            timeoutSeconds: 0.000_001
        )

        do {
            _ = try await MonitorPipeline.run(options: options)
            XCTFail("Expected configured monitor timeout")
        } catch let error as MonitorError {
            guard case let .operationFailed(phase, _, streamType, context, _) = error else {
                return XCTFail("Expected operationFailed, got \(error)")
            }

            XCTAssertEqual(phase, .ingest)
            XCTAssertEqual(streamType, .icecast)
            XCTAssertEqual(context["sourceClass"], "icy_stream")
            XCTAssertEqual(context["timeoutSeconds"], "1e-06")
        } catch {
            XCTFail("Expected MonitorError, got \(error)")
        }
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

private actor CancellationProbe {
    private var cancelled = false

    func markCancelled() {
        cancelled = true
    }

    func waitUntilCancelled() async -> Bool {
        for _ in 0..<50 {
            if cancelled {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cancelled
    }
}
