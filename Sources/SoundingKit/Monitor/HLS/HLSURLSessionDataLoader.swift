import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cross-platform async bridge for URLSession byte loads.
///
/// Swift's async `URLSession.data(from:)` availability differs between Darwin and
/// Linux FoundationNetworking versions. Keeping the bridge in one place lets HLS
/// manifest and segment loading use the same URLSession-backed path in tests and
/// production without platform-specific call sites.
enum HLSURLSessionDataLoader {
    static func data(from url: URL, using session: URLSession) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: url) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data, let response else {
                    continuation.resume(throwing: HLSSessionDataLoaderError.missingResponse)
                    return
                }

                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }
}

private enum HLSSessionDataLoaderError: Error, CustomStringConvertible, Sendable {
    case missingResponse

    var description: String {
        "URLSession data load completed without response bytes."
    }
}
