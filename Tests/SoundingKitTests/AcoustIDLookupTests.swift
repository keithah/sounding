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
