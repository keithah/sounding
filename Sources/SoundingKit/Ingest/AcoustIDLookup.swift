import Foundation

/// Fingerprint identity and optional timing context passed to an AcoustID lookup provider.
///
/// The request is intentionally independent from persistence so lookup providers can be injected into
/// ingest orchestration without coupling tests or CLI fixture runs to SQLite or live HTTP.
public struct AcoustIDLookupRequest: Equatable, Sendable {
    public var algorithm: String
    public var algorithmVersion: String
    public var fingerprint: String
    public var fingerprintHash: String
    public var durationSeconds: Double?

    public init(
        algorithm: String,
        algorithmVersion: String,
        fingerprint: String,
        fingerprintHash: String,
        durationSeconds: Double? = nil
    ) {
        self.algorithm = algorithm
        self.algorithmVersion = algorithmVersion
        self.fingerprint = fingerprint
        self.fingerprintHash = fingerprintHash
        self.durationSeconds = durationSeconds
    }
}

/// Normalized successful metadata returned by an AcoustID lookup.
///
/// Only this successful shape is suitable for the durable lookup cache. Operational failures remain
/// explicit ``AcoustIDLookupOutcome`` values so base fingerprint/song-play persistence can proceed.
public struct AcoustIDMatch: Equatable, Sendable {
    public var acoustID: String?
    public var recordingID: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var isrc: String?
    public var durationSeconds: Double?
    public var score: Double?
    public var responseJSON: String?

    public init(
        acoustID: String? = nil,
        recordingID: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        isrc: String? = nil,
        durationSeconds: Double? = nil,
        score: Double? = nil,
        responseJSON: String? = nil
    ) {
        self.acoustID = acoustID
        self.recordingID = recordingID
        self.title = title
        self.artist = artist
        self.album = album
        self.isrc = isrc
        self.durationSeconds = durationSeconds
        self.score = score
        self.responseJSON = responseJSON
    }
}

/// Non-throwing lookup taxonomy for expected AcoustID operational states.
public enum AcoustIDLookupOutcome: Equatable, Sendable {
    case matched(AcoustIDMatch)
    case disabled(reason: String)
    case notFound(reason: String)
    case transientFailure(reason: String)
    case rateLimited(retryAfterSeconds: Int?)
    case malformedResponse(reason: String)

    public static let maximumReasonLength = 240

    /// Redacts and bounds provider/configuration details before they are surfaced in diagnostics.
    public static func sanitizedReason(
        _ reason: String,
        maxLength: Int = maximumReasonLength
    ) -> String {
        let redacted = IngestRedaction.redact(reason)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = redacted.isEmpty ? "unspecified" : redacted
        guard maxLength > 1, fallback.count > maxLength else { return fallback }
        let end = fallback.index(fallback.startIndex, offsetBy: maxLength - 1)
        return String(fallback[..<end]) + "…"
    }
}

/// SoundingKit-owned AcoustID lookup seam.
///
/// Expected operational states are represented by ``AcoustIDLookupOutcome`` rather than thrown errors.
/// Implementations should reserve process-level failures for their own internals and convert provider
/// errors, timeouts, rate limits, malformed responses, missing credentials, and not-found responses into
/// outcomes so ingest can preserve base deterministic fingerprints.
public protocol AcoustIDLookuping: Sendable {
    func lookup(_ request: AcoustIDLookupRequest) async -> AcoustIDLookupOutcome
}

public struct AcoustIDHTTPResponse: Equatable, Sendable {
    public var statusCode: Int
    public var data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol AcoustIDHTTPTransporting: Sendable {
    func data(for request: URLRequest) async throws -> AcoustIDHTTPResponse
}

public struct URLSessionAcoustIDHTTPTransport: AcoustIDHTTPTransporting {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> AcoustIDHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return AcoustIDHTTPResponse(statusCode: 0, data: data)
        }
        return AcoustIDHTTPResponse(statusCode: httpResponse.statusCode, data: data)
    }
}

/// Real AcoustID lookup client for operator-enabled fingerprint enrichment.
///
/// The client key is only placed in the outbound request. Diagnostics produced from failures redact
/// the key before returning an outcome so callers can persist diagnostics without leaking it.
public struct AcoustIDHTTPClientLookup: AcoustIDLookuping {
    private let clientKey: String
    private let endpoint: URL
    private let transport: any AcoustIDHTTPTransporting

    public init(
        clientKey: String,
        endpoint: URL = URL(string: "https://api.acoustid.org/v2/lookup")!,
        transport: any AcoustIDHTTPTransporting = URLSessionAcoustIDHTTPTransport()
    ) {
        self.clientKey = clientKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.endpoint = endpoint
        self.transport = transport
    }

    public func lookup(_ request: AcoustIDLookupRequest) async -> AcoustIDLookupOutcome {
        guard !clientKey.isEmpty else {
            return .disabled(reason: "acoustid api key missing")
        }
        guard let urlRequest = makeRequest(for: request) else {
            return .malformedResponse(reason: "could not build acoustid lookup request")
        }

        do {
            let response = try await transport.data(for: urlRequest)
            guard (200 ..< 300).contains(response.statusCode) else {
                return .transientFailure(
                    reason: sanitized("acoustid http \(response.statusCode): \(responseBodySummary(response.data))")
                )
            }
            return decode(response.data)
        } catch {
            return .transientFailure(reason: sanitized("acoustid request failed: \(error)"))
        }
    }

    private func makeRequest(for request: AcoustIDLookupRequest) -> URLRequest? {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "client", value: clientKey),
            URLQueryItem(name: "fingerprint", value: request.fingerprint),
            URLQueryItem(name: "meta", value: "recordings releasegroups compress")
        ]
        if let duration = request.durationSeconds, duration.isFinite, duration > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(duration))))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = 15
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        return urlRequest
    }

    private func decode(_ data: Data) -> AcoustIDLookupOutcome {
        do {
            let decoded = try JSONDecoder().decode(AcoustIDLookupResponse.self, from: data)
            guard decoded.status == "ok" else {
                return .transientFailure(reason: sanitized(decoded.error?.message ?? "acoustid lookup failed"))
            }
            guard let match = bestMatch(from: decoded, responseJSON: minifiedJSON(data)) else {
                return .notFound(reason: "acoustid returned no usable recordings")
            }
            return .matched(match)
        } catch {
            return .malformedResponse(reason: sanitized("acoustid response decode failed: \(error)"))
        }
    }

    private func bestMatch(
        from response: AcoustIDLookupResponse,
        responseJSON: String?
    ) -> AcoustIDMatch? {
        response.results
            .sorted { ($0.score ?? 0) > ($1.score ?? 0) }
            .compactMap { result -> AcoustIDMatch? in
                guard let recording = result.recordings?.first else { return nil }
                let match = AcoustIDMatch(
                    acoustID: normalized(result.id),
                    recordingID: normalized(recording.id),
                    title: normalized(recording.title),
                    artist: normalized(recording.artists?.compactMap { normalized($0.name) }.joined(separator: ", ")),
                    album: normalized(recording.releasegroups?.compactMap { normalized($0.title) }.first),
                    isrc: normalized(recording.isrcs?.first),
                    durationSeconds: recording.duration,
                    score: result.score,
                    responseJSON: responseJSON
                )
                return isUsable(match) ? match : nil
            }
            .first
    }

    private func isUsable(_ match: AcoustIDMatch) -> Bool {
        [match.acoustID, match.recordingID, match.title, match.artist, match.album, match.isrc].contains {
            normalized($0) != nil
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func responseBodySummary(_ data: Data) -> String {
        guard let body = String(data: data, encoding: .utf8), !body.isEmpty else {
            return "empty response body"
        }
        return body
    }

    private func sanitized(_ reason: String) -> String {
        AcoustIDLookupOutcome.sanitizedReason(
            reason.replacingOccurrences(of: clientKey, with: "[redacted-key]")
        )
    }

    private func minifiedJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let minified = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return String(data: data, encoding: .utf8)
        }
        return String(data: minified, encoding: .utf8)
    }
}

private struct AcoustIDLookupResponse: Decodable {
    var status: String
    var error: AcoustIDLookupErrorResponse?
    var results: [AcoustIDLookupResult]

    enum CodingKeys: String, CodingKey {
        case status
        case error
        case results
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        error = try container.decodeIfPresent(AcoustIDLookupErrorResponse.self, forKey: .error)
        results = try container.decodeIfPresent([AcoustIDLookupResult].self, forKey: .results) ?? []
    }
}

private struct AcoustIDLookupErrorResponse: Decodable {
    var message: String?
}

private struct AcoustIDLookupResult: Decodable {
    var id: String?
    var score: Double?
    var recordings: [AcoustIDRecording]?
}

private struct AcoustIDRecording: Decodable {
    var id: String?
    var title: String?
    var duration: Double?
    var artists: [AcoustIDArtist]?
    var releasegroups: [AcoustIDReleaseGroup]?
    var isrcs: [String]?
}

private struct AcoustIDArtist: Decodable {
    var name: String?
}

private struct AcoustIDReleaseGroup: Decodable {
    var title: String?
}

/// Production-safe placeholder for disabled or unconfigured AcoustID lookup.
public struct NoOpAcoustIDLookup: AcoustIDLookuping {
    private let reason: String

    public init(reason: String = "acoustid-lookup-disabled") {
        self.reason = AcoustIDLookupOutcome.sanitizedReason(reason)
    }

    public func lookup(_ request: AcoustIDLookupRequest) async -> AcoustIDLookupOutcome {
        .disabled(reason: reason)
    }
}

/// Deterministic local lookup for tests and fixture-backed CLI proof runs.
///
/// This implementation never uses an API key or network. It maps a stable fingerprint identity to
/// normalized metadata so downstream enrichment/cache wiring can be tested against realistic success
/// shapes while remaining fully deterministic.
public struct DeterministicAcoustIDLookup: AcoustIDLookuping {
    public init() {}

    public func lookup(_ request: AcoustIDLookupRequest) async -> AcoustIDLookupOutcome {
        guard let hash = Self.normalizedFingerprintHash(from: request) else {
            return .notFound(reason: "empty-fingerprint-identity")
        }

        let prefix = String(hash.prefix(8))
        return .matched(
            AcoustIDMatch(
                acoustID: "acoustid-\(hash)",
                recordingID: "recording-\(hash)",
                title: "Deterministic Song \(prefix)",
                artist: "Sounding Fixtures",
                album: nil,
                isrc: Self.isrc(for: hash),
                durationSeconds: request.durationSeconds,
                score: 1.0,
                responseJSON: Self.responseJSON(for: hash)
            )
        )
    }

    private static func normalizedFingerprintHash(from request: AcoustIDLookupRequest) -> String? {
        let explicitHash = request.fingerprintHash.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitHash.isEmpty { return explicitHash }

        let fingerprint = request.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fingerprint.isEmpty else { return nil }

        if fingerprint.hasPrefix("fingerprint:") {
            let suffix = String(fingerprint.dropFirst("fingerprint:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.isEmpty ? nil : suffix
        }

        if let separator = fingerprint.lastIndex(of: ":") {
            let suffix = String(fingerprint[fingerprint.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.isEmpty ? nil : suffix
        }

        return fingerprint
    }

    private static func isrc(for hash: String) -> String {
        let hexPrefix = String(hash.prefix(6))
        let numeric = Int(hexPrefix, radix: 16) ?? abs(hash.hashValue)
        return String(format: "QSND26%06d", numeric % 1_000_000)
    }

    private static func responseJSON(for hash: String) -> String {
        #"{"status":"ok","source":"deterministic","fingerprintHash":""#
            + jsonEscaped(hash)
            + #""}"#
    }

    private static func jsonEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
    }
}
