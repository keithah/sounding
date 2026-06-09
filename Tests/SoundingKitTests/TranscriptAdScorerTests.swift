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

    func testSplitDoctorAppAdCopyReinforcesAcrossNearbyFragments() {
        let fragments = [
            paragraph("I'm going on Zocdoc and finding you an eye doctor.", start: 0, end: 8),
            paragraph("You've got options.", start: 9, end: 12),
            paragraph("Download the Zocdoc app today.", start: 13, end: 18),
        ]

        let scores = TranscriptAdScorer.scores(for: fragments)

        XCTAssertGreaterThanOrEqual(scores[fragments[0].id]?.confidence ?? 0, 0.50)
        XCTAssertGreaterThanOrEqual(scores[fragments[2].id]?.confidence ?? 0, 0.50)
        XCTAssertTrue((scores[fragments[2].id]?.signals ?? []).contains { signal in
            signal.contains("cluster") || signal.contains("neighbor-reinforced")
        })
    }

    func testSplitTuneInPromoCopyReinforcesAcrossNearbyFragments() {
        let fragments = [
            paragraph("No matter what you're listening for, you can always find it on Tune In.", start: 0, end: 12),
            paragraph("News, sports, music, and today's hits. One simple app.", start: 13, end: 25),
            paragraph("Tune In is the audio platform with something forever.", start: 26, end: 34),
            paragraph("And even podcasts, whatever you love.", start: 35, end: 40),
        ]

        let scores = TranscriptAdScorer.scores(for: fragments)

        XCTAssertGreaterThanOrEqual(scores[fragments[0].id]?.confidence ?? 0, 0.50)
        XCTAssertGreaterThanOrEqual(scores[fragments[2].id]?.confidence ?? 0, 0.50)
        XCTAssertTrue((scores[fragments[0].id]?.signals ?? []).contains { $0.contains("cluster") })
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
