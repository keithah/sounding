import Foundation
import XCTest
@testable import SoundingKit

final class MonitorPipelineICYTests: XCTestCase {
    private let privateSource = "https://user:pass@example.test/live?token=secret#frag"

    override func tearDown() {
        MonitorPipeline.icyAdapterFactory = MonitorPipeline.defaultICYAdapterFactory
        super.tearDown()
    }

    func testAdapterSendsICYRequestHeadersToInjectedOpener() async throws {
        let headerCapture = HeaderCapture()
        let adapter = ICYMonitorAdapter(source: privateSource, streamType: .icy) { _, headers in
            await headerCapture.set(headers)
            return ICYMonitorAdapter.OpenedStream(
                responseHeaders: ["icy-metaint": "4"],
                streamBytes: Self.icyStream(metaInt: 4, titles: ["Promo Spot"])
            )
        }

        let markers = try await adapter.markers()

        let capturedHeaders = await headerCapture.value
        XCTAssertEqual(capturedHeaders, ICYMetadataParser.requestHeaders)
        XCTAssertEqual(markers.map { $0.fields["StreamTitle"] }, [.string("Promo Spot")])
    }

    func testPipelineRoutesICYAndClassifiesPromoAsAdStart() async throws {
        MonitorPipeline.icyAdapterFactory = { source, streamType in
            ICYMonitorAdapter(source: source, streamType: streamType) { _, _ in
                ICYMonitorAdapter.OpenedStream(
                    responseHeaders: ["icy-metaint": "4"],
                    streamBytes: Self.icyStream(metaInt: 4, titles: ["Promo Spot"])
                )
            }
        }
        let options = try MonitorOptions(source: "https://example.test/live", streamType: .icy, filter: "all")

        let markers = try await MonitorPipeline.run(options: options)

        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.type, "ICY")
        XCTAssertEqual(markers.first?.source, "icy_stream")
        XCTAssertEqual(markers.first?.classification, .adStart)
    }

    func testPipelineRoutesIcecastAndAppliesMarkerTypeFilter() async throws {
        MonitorPipeline.icyAdapterFactory = { source, streamType in
            ICYMonitorAdapter(source: source, streamType: streamType) { _, _ in
                ICYMonitorAdapter.OpenedStream(
                    responseHeaders: ["iCy-MeTaInT": "4"],
                    streamBytes: Self.icyStream(metaInt: 4, titles: ["Song Title"])
                )
            }
        }
        let options = try MonitorOptions(source: "https://example.test/live", streamType: .icecast, filter: "icy")

        let markers = try await MonitorPipeline.run(options: options)

        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.type, "ICY")
        XCTAssertEqual(markers.first?.classification, .unknown)
    }

    func testMissingAndBlankMetaIntDefaultTo16000() async throws {
        for headers in [[:], ["icy-metaint": "  "]] as [[String: String]] {
            let adapter = ICYMonitorAdapter(source: "fixture", streamType: .icy) { _, _ in
                ICYMonitorAdapter.OpenedStream(
                    responseHeaders: headers,
                    streamBytes: Self.icyStream(metaInt: ICYMetadataParser.defaultMetaInt, titles: ["Promo Spot"])
                )
            }

            let markers = try await adapter.markers()

            XCTAssertEqual(markers.count, 1)
            XCTAssertEqual(markers.first?.fields["StreamTitle"], .string("Promo Spot"))
        }
    }

    func testInvalidMetaIntValuesAreRejectedWithSafeContext() async throws {
        for rawValue in ["bogus", "0", "-1"] {
            let adapter = ICYMonitorAdapter(source: privateSource, streamType: .icy) { _, _ in
                ICYMonitorAdapter.OpenedStream(
                    responseHeaders: ["icy-metaint": rawValue],
                    streamBytes: Data()
                )
            }

            do {
                _ = try await adapter.markers()
                XCTFail("Expected invalid metaint to throw")
            } catch let error as MonitorError {
                guard case let .operationFailed(phase, source, streamType, context, _) = error else {
                    return XCTFail("Expected operationFailed, got \(error)")
                }
                XCTAssertEqual(phase, .configuration)
                XCTAssertEqual(source, privateSource)
                XCTAssertEqual(streamType, .icy)
                XCTAssertEqual(context["sourceClass"], "icy_stream")
                if rawValue == "bogus" {
                    XCTAssertEqual(context["metaInt"], "invalid")
                } else {
                    XCTAssertEqual(context["metaInt"], "nonPositive")
                }

                let description = error.description
                XCTAssertTrue(description.contains("configuration"), description)
                XCTAssertTrue(description.contains("sourceClass=icy_stream"), description)
                assertSanitized(description)
            } catch {
                XCTFail("Expected MonitorError, got \(error)")
            }
        }
    }

    func testClassificationHappensBeforeAdFiltering() async throws {
        MonitorPipeline.icyAdapterFactory = { source, streamType in
            ICYMonitorAdapter(source: source, streamType: streamType) { _, _ in
                ICYMonitorAdapter.OpenedStream(
                    responseHeaders: ["icy-metaint": "4"],
                    streamBytes: Self.icyStream(metaInt: 4, titles: ["Regular Content", "Promo Spot", "Regular Content"])
                )
            }
        }
        let options = try MonitorOptions(source: "https://example.test/live", streamType: .icy, filter: "ad")

        let markers = try await MonitorPipeline.run(options: options)

        XCTAssertEqual(markers.map(\.classification), [.adStart, .adEnd])
        XCTAssertEqual(markers.map { $0.fields["StreamTitle"] }, [.string("Promo Spot"), .string("Regular Content")])
    }

    func testSourceOpenFailureIsRedactedAndDoesNotLeakHeadersOrSourceSecrets() async throws {
        let adapter = ICYMonitorAdapter(source: privateSource, streamType: .icy) { _, _ in
            throw FixtureError.message("failed opening https://user:pass@example.test/live?token=secret#frag with Icy-MetaData=1")
        }

        do {
            _ = try await adapter.markers()
            XCTFail("Expected source-open failure")
        } catch let error as MonitorError {
            guard case let .operationFailed(phase, _, _, context, _) = error else {
                return XCTFail("Expected operationFailed, got \(error)")
            }
            XCTAssertEqual(phase, .sourceOpen)
            XCTAssertEqual(context["sourceClass"], "icy_stream")
            let description = error.description
            XCTAssertTrue(description.contains("sourceOpen"), description)
            assertSanitized(description)
            XCTAssertFalse(description.contains("Icy-MetaData=1"), description)
        } catch {
            XCTFail("Expected MonitorError, got \(error)")
        }
    }

    func testIncompleteMetadataFrameBecomesDecodeFailureWithoutRawChunkLeak() async throws {
        let rawMetadata = "StreamTitle='secret promo chunk';"
        var bytes = Data(repeating: 0x41, count: 4)
        bytes.append(3) // promises 48 metadata bytes, then provides fewer
        bytes.append(contentsOf: rawMetadata.data(using: .utf8)!)
        let incompleteBytes = bytes
        let adapter = ICYMonitorAdapter(source: privateSource, streamType: .icy) { _, _ in
            ICYMonitorAdapter.OpenedStream(responseHeaders: ["icy-metaint": "4"], streamBytes: incompleteBytes)
        }

        do {
            _ = try await adapter.markers()
            XCTFail("Expected incomplete metadata failure")
        } catch let error as MonitorError {
            guard case let .operationFailed(phase, _, _, context, _) = error else {
                return XCTFail("Expected operationFailed, got \(error)")
            }
            XCTAssertEqual(phase, .decode)
            XCTAssertEqual(context["sourceClass"], "icy_stream")
            XCTAssertEqual(context["phase"], "metadata")
            XCTAssertEqual(context["expectedByteCount"], "48")
            XCTAssertEqual(context["actualByteCount"], String(rawMetadata.utf8.count))
            let description = error.description
            assertSanitized(description)
            XCTAssertFalse(description.contains(rawMetadata), description)
            XCTAssertFalse(description.contains(bytes.base64EncodedString()), description)
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

    private func assertSanitized(_ description: String, file: StaticString = #filePath, line: UInt = #line) {
        for forbidden in ["user:pass", "token=secret", "secret#frag", "#frag", "?token", "Icy-MetaData=1"] {
            XCTAssertFalse(description.contains(forbidden), "Leaked forbidden literal in: \(description)", file: file, line: line)
        }
    }
}

private actor HeaderCapture {
    private var headers = [String: String]()

    var value: [String: String] {
        headers
    }

    func set(_ headers: [String: String]) {
        self.headers = headers
    }
}

private enum FixtureError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case let .message(message):
            return message
        }
    }
}
