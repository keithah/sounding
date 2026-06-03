import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

@testable import SoundingKit

final class HLSURLSessionDataLoaderTests: XCTestCase {
    override func tearDown() {
        HangingURLProtocol.reset()
        super.tearDown()
    }

    func testCancellingSwiftTaskCancelsUnderlyingURLSessionTask() async throws {
        let cancelled = expectation(description: "URL protocol received cancellation")
        HangingURLProtocol.onStopLoading = {
            cancelled.fulfill()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let task = Task {
            _ = try await HLSURLSessionDataLoader.data(
                from: URL(string: "https://example.test/live.m3u8")!,
                using: session
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        task.cancel()

        await fulfillment(of: [cancelled], timeout: 1.0)
        do {
            try await task.value
            XCTFail("Expected cancelled HLS URL load to throw")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as NSError).code == NSURLErrorCancelled)
        }
    }
}

private final class HangingURLProtocol: URLProtocol {
    static var onStopLoading: (@Sendable () -> Void)?

    static func reset() {
        onStopLoading = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {}

    override func stopLoading() {
        Self.onStopLoading?()
    }
}
