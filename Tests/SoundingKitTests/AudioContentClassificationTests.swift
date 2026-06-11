import XCTest

@testable import SoundingKit

final class AudioContentClassificationTests: XCTestCase {
    func testMusicLabelAllowsNearThresholdFingerprinting() {
        let classification = AudioContentClassification(
            musicProbability: 0.74,
            speechProbability: 0.18,
            label: "music"
        )

        XCTAssertTrue(
            classification.allowsFingerprinting(minimumMusicProbability: 0.80)
        )
    }

    func testSingingLabelAllowsNearThresholdFingerprinting() {
        let classification = AudioContentClassification(
            musicProbability: 0.73,
            speechProbability: 0.15,
            label: "singing"
        )

        XCTAssertTrue(
            classification.allowsFingerprinting(minimumMusicProbability: 0.80)
        )
    }

    func testRappingLabelAllowsFingerprintingBelowGenericMusicThreshold() {
        let classification = AudioContentClassification(
            musicProbability: 0.68,
            speechProbability: 0.58,
            label: "rapping"
        )

        XCTAssertTrue(
            classification.allowsFingerprinting(minimumMusicProbability: 0.80)
        )
    }

    func testHighConfidenceSpeechBlocksBedMusicFingerprinting() {
        let classification = AudioContentClassification(
            musicProbability: 0.78,
            speechProbability: 0.90,
            label: "speech"
        )

        XCTAssertFalse(
            classification.allowsFingerprinting(minimumMusicProbability: 0.80)
        )
    }
}
