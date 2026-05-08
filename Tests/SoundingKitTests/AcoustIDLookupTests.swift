import XCTest
@testable import SoundingKit

final class AcoustIDLookupTests: XCTestCase {
    func testLookupOutcomesAreDistinctAndEquatable() {
        XCTAssertEqual(
            AcoustIDLookupOutcome.disabled(reason: "missing-key"),
            AcoustIDLookupOutcome.disabled(reason: "missing-key")
        )
        XCTAssertNotEqual(
            AcoustIDLookupOutcome.disabled(reason: "missing-key"),
            AcoustIDLookupOutcome.notFound(reason: "no-results")
        )
        XCTAssertNotEqual(
            AcoustIDLookupOutcome.transientFailure(reason: "network"),
            AcoustIDLookupOutcome.rateLimited(retryAfterSeconds: nil)
        )
        XCTAssertNotEqual(
            AcoustIDLookupOutcome.rateLimited(retryAfterSeconds: 0),
            AcoustIDLookupOutcome.rateLimited(retryAfterSeconds: 30)
        )
        XCTAssertEqual(
            AcoustIDLookupOutcome.matched(.fixture(title: "Fixture", artist: "Artist")),
            AcoustIDLookupOutcome.matched(.fixture(title: "Fixture", artist: "Artist"))
        )
    }

    func testNoOpLookupReturnsDisabledWithoutThrowing() async {
        let lookup = NoOpAcoustIDLookup(reason: "AcoustID api_key=secret disabled")

        let outcome = await lookup.lookup(.fixture)

        XCTAssertEqual(outcome, .disabled(reason: "AcoustID api_key=[redacted] disabled"))
    }

    func testDeterministicLookupMapsFingerprintHashToStableMetadata() async {
        let lookup = DeterministicAcoustIDLookup()
        let request = AcoustIDLookupRequest(
            algorithm: "sounding-deterministic",
            algorithmVersion: "1",
            fingerprint: "deterministic:ignored",
            fingerprintHash: "abcdef1234567890",
            durationSeconds: 12.5
        )

        let outcome = await lookup.lookup(request)

        XCTAssertEqual(
            outcome,
            .matched(
                AcoustIDMatch(
                    acoustID: "acoustid-abcdef1234567890",
                    recordingID: "recording-abcdef1234567890",
                    title: "Deterministic Song abcdef12",
                    artist: "Sounding Fixtures",
                    album: nil,
                    isrc: "QSND26259375",
                    durationSeconds: 12.5,
                    score: 1.0,
                    responseJSON: #"{"status":"ok","source":"deterministic","fingerprintHash":"abcdef1234567890"}"#
                )
            )
        )
    }

    func testDeterministicLookupCanDeriveHashFromFingerprintSongKey() async {
        let lookup = DeterministicAcoustIDLookup()
        let request = AcoustIDLookupRequest(
            algorithm: "sounding-deterministic",
            algorithmVersion: "1",
            fingerprint: "fingerprint:feedfacecafebeef",
            fingerprintHash: "",
            durationSeconds: nil
        )

        let outcome = await lookup.lookup(request)

        guard case .matched(let match) = outcome else {
            return XCTFail("Expected deterministic match, got \(outcome)")
        }
        XCTAssertEqual(match.title, "Deterministic Song feedface")
        XCTAssertEqual(match.artist, "Sounding Fixtures")
        XCTAssertNil(match.album)
        XCTAssertEqual(match.isrc, "QSND26707066")
        XCTAssertNil(match.durationSeconds)
    }

    func testEmptyDeterministicLookupRequestReturnsNotFoundWithoutThrowing() async {
        let lookup = DeterministicAcoustIDLookup()

        let outcome = await lookup.lookup(
            AcoustIDLookupRequest(
                algorithm: "sounding-deterministic",
                algorithmVersion: "1",
                fingerprint: " ",
                fingerprintHash: " ",
                durationSeconds: nil
            )
        )

        XCTAssertEqual(outcome, .notFound(reason: "empty-fingerprint-identity"))
    }

    func testHTTPClientLookupBuildsRedactedRequestAndParsesBestRecording() async throws {
        let response = """
            {
              "status": "ok",
              "results": [
                {
                  "id": "low-score",
                  "score": 0.44,
                  "recordings": [
                    {"id": "low-recording", "title": "Wrong", "artists": [{"name": "Other"}]}
                  ]
                },
                {
                  "id": "best-acoustid",
                  "score": 0.98,
                  "recordings": [
                    {
                      "id": "recording-123",
                      "title": "Best Song",
                      "duration": 211,
                      "artists": [{"name": "Best Artist"}],
                      "releasegroups": [{"title": "Best Album"}],
                      "isrcs": ["USABC2600001"]
                    }
                  ]
                }
              ]
            }
            """
        let transport = RecordingAcoustIDHTTPTransport(
            statusCode: 200,
            data: try XCTUnwrap(response.data(using: .utf8))
        )
        let lookup = AcoustIDHTTPClientLookup(
            clientKey: "client-secret",
            transport: transport
        )

        let outcome = await lookup.lookup(.fixture)

        guard case .matched(let match) = outcome else {
            return XCTFail("Expected matched response, got \(outcome)")
        }
        XCTAssertEqual(match.acoustID, "best-acoustid")
        XCTAssertEqual(match.recordingID, "recording-123")
        XCTAssertEqual(match.title, "Best Song")
        XCTAssertEqual(match.artist, "Best Artist")
        XCTAssertEqual(match.album, "Best Album")
        XCTAssertEqual(match.isrc, "USABC2600001")
        XCTAssertEqual(match.durationSeconds, 211)
        XCTAssertEqual(match.score, 0.98)
        XCTAssertTrue(match.responseJSON?.contains(#""status":"ok""#) ?? false)
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.host, "api.acoustid.org")
        XCTAssertEqual(request.url?.path, "/v2/lookup")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["client"], "client-secret")
        XCTAssertEqual(query["duration"], "12")
        XCTAssertEqual(query["fingerprint"], "deterministic:abcdef1234567890")
        XCTAssertEqual(query["meta"], "recordings releasegroups compress")
    }

    func testHTTPClientLookupFailuresAreNonFatalAndRedacted() async {
        let transport = RecordingAcoustIDHTTPTransport(
            statusCode: 403,
            data: Data(#"{"status":"error","error":{"message":"bad client=client-secret token=secret"}}"#.utf8)
        )
        let lookup = AcoustIDHTTPClientLookup(clientKey: "client-secret", transport: transport)

        let outcome = await lookup.lookup(.fixture)

        guard case .transientFailure(let reason) = outcome else {
            return XCTFail("Expected transient failure, got \(outcome)")
        }
        XCTAssertFalse(reason.contains("client-secret"), reason)
        XCTAssertFalse(reason.contains("token=secret"), reason)
    }

    func testReasonRedactionAndBoundingRemovesSecretsURLsAndPaths() {
        let reason = AcoustIDLookupOutcome.sanitizedReason(
            "failed url=https://user:pass@example.test/lookup?client=abc&api_key=secret path=/tmp/acoustid-secret/body.json "
                + String(repeating: "x", count: 300),
            maxLength: 96
        )

        XCTAssertLessThanOrEqual(reason.count, 96)
        XCTAssertTrue(reason.contains("[redacted-path]"), reason)
        XCTAssertFalse(reason.contains("user:pass"), reason)
        XCTAssertFalse(reason.contains("api_key=secret"), reason)
        XCTAssertFalse(reason.contains("/tmp/acoustid-secret/body.json"), reason)
        XCTAssertTrue(reason.hasSuffix("…"), reason)
    }
}

private actor RecordingAcoustIDHTTPTransport: AcoustIDHTTPTransporting {
    private let statusCode: Int
    private let data: Data
    private var requests: [URLRequest] = []

    init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }

    func data(for request: URLRequest) async throws -> AcoustIDHTTPResponse {
        requests.append(request)
        return AcoustIDHTTPResponse(statusCode: statusCode, data: data)
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private extension AcoustIDLookupRequest {
    static var fixture: AcoustIDLookupRequest {
        AcoustIDLookupRequest(
            algorithm: "sounding-deterministic",
            algorithmVersion: "1",
            fingerprint: "deterministic:abcdef1234567890",
            fingerprintHash: "abcdef1234567890",
            durationSeconds: 12.5
        )
    }
}

private extension AcoustIDMatch {
    static func fixture(title: String, artist: String) -> AcoustIDMatch {
        AcoustIDMatch(
            acoustID: "acoustid-fixture",
            recordingID: "recording-fixture",
            title: title,
            artist: artist,
            album: nil,
            isrc: nil,
            durationSeconds: nil,
            score: 0.99,
            responseJSON: nil
        )
    }
}
