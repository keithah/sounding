import XCTest
@testable import SoundingKit

final class FoundationModelsAdVerifierTests: XCTestCase {
    func testParsesAdJSONResponseIntoTranscriptVerification() throws {
        let response = """
        {
          "verdict": "ad",
          "ad_type": "commercial_spot",
          "brand": "Wells Fargo",
          "product": "Clear Access Banking",
          "confidence": "high",
          "reason": "Mentions bank product, offer language, and FDIC disclaimer."
        }
        """

        let verification = try FoundationModelsAdVerifierResponseParser.parse(
            response,
            classifiedAt: "2026-06-09T21:10:00Z",
            modelIdentifier: "foundationmodels.default"
        )

        XCTAssertEqual(verification.verdict, .ad)
        XCTAssertEqual(verification.adType, .commercialSpot)
        XCTAssertEqual(verification.brand, "Wells Fargo")
        XCTAssertEqual(verification.product, "Clear Access Banking")
        XCTAssertEqual(verification.confidence, .high)
        XCTAssertEqual(verification.reason, "Mentions bank product, offer language, and FDIC disclaimer.")
        XCTAssertEqual(verification.modelIdentifier, "foundationmodels.default")
        XCTAssertEqual(verification.classifiedAt, "2026-06-09T21:10:00Z")
    }

    func testParsesFencedJSONAndNormalizesNonAdFields() throws {
        let response = """
        ```json
        {
          "verdict": "music",
          "ad_type": null,
          "brand": "   ",
          "product": "",
          "confidence": "medium",
          "reason": "Lyrics and music markers dominate the paragraph."
        }
        ```
        """

        let verification = try FoundationModelsAdVerifierResponseParser.parse(
            response,
            classifiedAt: "2026-06-09T21:11:00Z",
            modelIdentifier: "foundationmodels.default"
        )

        XCTAssertEqual(verification.verdict, .music)
        XCTAssertNil(verification.adType)
        XCTAssertNil(verification.brand)
        XCTAssertNil(verification.product)
        XCTAssertEqual(verification.confidence, .medium)
    }

    func testRejectsInvalidJSONResponse() {
        XCTAssertThrowsError(
            try FoundationModelsAdVerifierResponseParser.parse(
                "not json",
                classifiedAt: "2026-06-09T21:12:00Z",
                modelIdentifier: "foundationmodels.default"
            )
        ) { error in
            XCTAssertEqual(error as? FoundationModelsAdVerifierError, .invalidResponse)
        }
    }

    func testAvailabilityFactoryIsCallableOnCurrentRuntime() {
        let status = FoundationModelsAdVerifierFactory.availability()

        XCTAssertFalse(status.message.isEmpty)
        _ = FoundationModelsAdVerifierFactory.makeIfAvailable(
            now: { "2026-06-09T21:13:00Z" }
        )
    }
}
