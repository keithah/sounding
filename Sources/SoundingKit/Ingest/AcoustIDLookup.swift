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
        #"{"status":"ok","source":"deterministic","fingerprintHash":"#
            + jsonEscaped(hash)
            + #""}"#
    }

    private static func jsonEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
    }
}
