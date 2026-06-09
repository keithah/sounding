import XCTest
@testable import SoundingKit

final class TranscriptAdScorerTests: XCTestCase {
    func testScoresUrlAndCTAAsLikelyAd() {
        let score = TranscriptAdScorer.score(
            paragraph: paragraph("Start your free trial today at Shopify.com/win."),
            neighbors: []
        )

        XCTAssertGreaterThanOrEqual(score.confidence, 0.50)
        XCTAssertTrue(score.signals.contains { $0.contains("url") })
        XCTAssertTrue(score.signals.contains { $0.contains("cta") })
    }

    func testScoresLegalDisclaimersAsStrongAdSignal() {
        let score = TranscriptAdScorer.score(
            paragraph: paragraph("Mobile carriers message and data rates may apply. Wells Fargo Bank is a member FDIC."),
            neighbors: []
        )

        XCTAssertGreaterThanOrEqual(score.confidence, 0.70)
        XCTAssertTrue(score.signals.contains { $0.contains("disclaimer") })
    }

    func testAdjacencyReinforcesWeakAdParagraphWithoutLiftingFromZero() {
        let weak = paragraph("Discover what our low carbon solutions can do for your business.", start: 30, end: 38)
        let strongNeighbor = paragraph("Visit example.com today. Terms and conditions apply.", start: 0, end: 20)
        let reinforced = TranscriptAdScorer.score(paragraph: weak, neighbors: [strongNeighbor])
        let isolated = TranscriptAdScorer.score(paragraph: weak, neighbors: [])
        let music = TranscriptAdScorer.score(
            paragraph: paragraph("oh baby don't go", start: 80, end: 85),
            neighbors: [strongNeighbor]
        )

        XCTAssertLessThan(isolated.confidence, 0.50)
        XCTAssertGreaterThanOrEqual(reinforced.confidence, 0.50)
        XCTAssertEqual(music.confidence, 0.0)
    }

    func testNewsQuoteWithAdLanguageStaysBelowAdThreshold() {
        let score = TranscriptAdScorer.score(
            paragraph: paragraph("Build quotes faster triggering the president to walk out of that interview."),
            neighbors: []
        )

        XCTAssertLessThan(score.confidence, 0.50)
    }

    func testSponsorUrlCTAAndMusicTagScoresAsHighConfidenceAd() {
        let score = TranscriptAdScorer.score(
            paragraph: paragraph("Brought to you by Acme. Visit acme dot com. Call now. [MUSIC]", start: 10, end: 35),
            neighbors: []
        )

        XCTAssertGreaterThanOrEqual(score.confidence, 0.80)
    }

    private func paragraph(
        _ text: String,
        start: Double = 0,
        end: Double = 10
    ) -> StreamAppTranscriptParagraph {
        StreamAppTranscriptParagraph(
            id: Int64(start + 1),
            streamID: 1,
            runID: 1,
            chunkID: 1,
            sequence: Int(start),
            speakerDisplay: StreamAppSpeakerDisplay(
                rawLabel: "speaker",
                displayLabel: "speaker",
                colorToken: "blue"
            ),
            startSeconds: start,
            endSeconds: end,
            text: text,
            confidence: nil
        )
    }
}
