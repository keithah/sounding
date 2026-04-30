import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Loads media segment bytes referenced by an HLS manifest.
///
/// The default implementation supports deterministic local file resolution for fixture tests and
/// URLSession-backed HTTP(S) reads for real HLS sources. Callers own timeout/cancellation policy.
public protocol HLSSegmentLoading {
    func loadSegment(uri: String, relativeTo manifestSource: String) async throws -> Data
}

public struct HLSSegmentLoader: HLSSegmentLoading {
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func loadSegment(uri: String, relativeTo manifestSource: String) async throws -> Data {
        let segmentURL = try resolveSegmentURL(uri: uri, relativeTo: manifestSource)

        if segmentURL.isFileURL {
            return try Data(contentsOf: segmentURL)
        }

        guard segmentURL.scheme == "http" || segmentURL.scheme == "https" else {
            throw HLSSegmentLoaderError.unsupportedScheme
        }

        let (data, response) = try await urlSession.data(from: segmentURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HLSSegmentLoaderError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw HLSSegmentLoaderError.httpStatus(httpResponse.statusCode)
        }
        return data
    }

    private func resolveSegmentURL(uri: String, relativeTo manifestSource: String) throws -> URL {
        if let absoluteURL = URL(string: uri), absoluteURL.scheme != nil {
            return absoluteURL
        }

        if let manifestURL = URL(string: manifestSource), manifestURL.scheme != nil {
            let directoryURL = manifestURL.deletingLastPathComponent()
            if let resolved = URL(string: uri, relativeTo: directoryURL)?.absoluteURL {
                return resolved
            }
        }

        let manifestURL = URL(fileURLWithPath: manifestSource)
        let directoryURL = manifestURL.deletingLastPathComponent()
        return directoryURL.appendingPathComponent(uri)
    }
}

public enum HLSSegmentLoaderError: Error, Equatable, CustomStringConvertible, Sendable {
    case unsupportedScheme
    case invalidResponse
    case httpStatus(Int)

    public var description: String {
        switch self {
        case .unsupportedScheme:
            return "HLS segment load failed: unsupported segment URI scheme."
        case .invalidResponse:
            return "HLS segment load failed: invalid URL response."
        case let .httpStatus(statusCode):
            return "HLS segment load failed: HTTP status \(statusCode)."
        }
    }
}
