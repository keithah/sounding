import XCTest
@testable import SoundingKit

final class StreamAppTimelineProjectionTests: XCTestCase {
    func testMetadataIndexFindsSongBoundariesByRange() {
        let index = StreamAppTimelineMetadataIndex(
            metadataChanges: [
                metadata("song:1", title: "First", artist: "Artist A", start: 10, end: 20),
                metadata("event:1", title: "Not a Song", artist: "", start: 12, end: 14, kind: .event),
                metadata("song:2", title: "Second", artist: "Artist B", start: 30, end: 40),
            ]
        )

        XCTAssertFalse(index.hasSongBoundary(after: 0, before: 9.9))
        XCTAssertTrue(index.hasSongBoundary(after: 0, before: 10))
        XCTAssertFalse(index.hasSongBoundary(after: 10, before: 29.9))
        XCTAssertTrue(index.hasSongBoundary(after: 29.9, before: 30))
    }

    func testMetadataIndexReturnsNewestArtistMetadataAtMidpoint() {
        let index = StreamAppTimelineMetadataIndex(
            metadataChanges: [
                metadata("song:1", title: "Earlier", artist: "Artist A", start: 10, end: 40),
                metadata("song:2", title: "Later", artist: "Artist B", start: 20, end: 50),
                metadata("song:3", title: "No Artist", artist: "", start: 30, end: 60),
            ]
        )

        XCTAssertEqual(index.artistMetadata(containingMidpoint: 25)?.title, "Later")
        XCTAssertEqual(index.artistMetadata(containingMidpoint: 15)?.title, "Earlier")
        XCTAssertNil(index.artistMetadata(containingMidpoint: 55))
    }

    func testMetadataIndexReturnsRecentSongsInNewestFirstOrder() {
        let index = StreamAppTimelineMetadataIndex(
            metadataChanges: [
                metadata("song:1", title: "Oldest", artist: "Artist A", start: 10, end: 20),
                metadata("event:1", title: "Event", artist: "", start: 30, end: 40, kind: .event),
                metadata("song:2", title: "Newest", artist: "Artist B", start: 50, end: 60),
                metadata("song:3", title: "Middle", artist: "Artist C", start: 30, end: 40),
            ]
        )

        XCTAssertEqual(index.recentSongs(limit: 2).map(\.title), ["Newest", "Middle"])
    }

    func testMetadataIndexReturnsCurrentSongOrNewestFallback() {
        let index = StreamAppTimelineMetadataIndex(
            metadataChanges: [
                metadata("song:1", title: "Older", artist: "Artist A", start: 10, end: 20),
                metadata("song:2", title: "Current", artist: "Artist B", start: 30, end: 50),
                metadata("song:3", title: "Newest", artist: "Artist C", start: 70, end: 80),
            ]
        )

        XCTAssertEqual(index.currentSong(at: 40)?.title, "Current")
        XCTAssertNil(index.currentSong(at: 60))
        XCTAssertEqual(index.currentSong(at: nil)?.title, "Newest")
    }

    func testCoalescesRepeatedMetadataAndKeepsDistinctConsecutiveSongsVisible() {
        let projection = StreamAppTimelineProjection(
            paragraphs: [],
            metadata: [
                metadata("song:1", title: "First", artist: "Artist A", start: 10, end: 20),
                metadata("song:2", title: "First", artist: "Artist A", start: 16, end: 26),
                metadata("song:3", title: "Second", artist: "Artist B", start: 30, end: 40),
                metadata("song:4", title: "Third", artist: "Artist C", start: 42, end: 50),
            ]
        )

        XCTAssertEqual(projection.metadataChanges.map(\.title), ["First", "Second", "Third"])
        XCTAssertEqual(projection.metadataChanges.first?.endSeconds, 30)
        XCTAssertEqual(
            projection.timelineItems(limit: 10).filter { $0.kind == .song }.map(\.title),
            ["First", "Second", "Third"]
        )
    }

    func testTranscriptParagraphsMergeOnlyUntilMetadataBoundary() {
        let speaker = display("host")
        let projection = StreamAppTimelineProjection(
            paragraphs: [
                paragraph(1, speaker: speaker, start: 0, end: 4, text: "First thought."),
                paragraph(2, speaker: speaker, start: 6, end: 10, text: "Continues here."),
                paragraph(3, speaker: speaker, start: 16, end: 20, text: "New song boundary."),
            ],
            metadata: [
                metadata("song:1", title: "Song Boundary", artist: "Artist", start: 12, end: 30),
            ]
        )

        XCTAssertEqual(
            projection.timelineItems(limit: 10).filter { $0.kind == .transcript }.map(\.subtitle),
            ["First thought. Continues here.", "New song boundary."]
        )
    }

    func testMetadataArtistReplacesTranscriptSpeakerInsideSongWindow() {
        let projection = StreamAppTimelineProjection(
            paragraphs: [
                paragraph(
                    1,
                    speaker: display(StreamAppSpeakerDisplayProjection.unknownSpeakerLabel),
                    start: 20,
                    end: 24,
                    text: "Artist-backed words."
                ),
            ],
            metadata: [
                metadata("song:1", title: "Song", artist: "Artist Name", start: 10, end: 30),
            ]
        )

        let transcript = projection.timelineItems(limit: 10).first { $0.kind == .transcript }
        XCTAssertEqual(transcript?.title, "Artist Name")
        XCTAssertEqual(transcript?.speakerDisplay?.displayLabel, "Artist Name")
    }

    private func display(_ label: String) -> StreamAppSpeakerDisplay {
        StreamAppSpeakerDisplay(
            rawLabel: label,
            displayLabel: label,
            colorToken: StreamAppSpeakerDisplayProjection.fallbackColorToken(for: label)
        )
    }

    private func paragraph(
        _ id: Int64,
        speaker: StreamAppSpeakerDisplay,
        start: Double,
        end: Double,
        text: String
    ) -> StreamAppTranscriptParagraph {
        StreamAppTranscriptParagraph(
            id: id,
            streamID: 1,
            runID: 1,
            chunkID: 1,
            sequence: Int(id),
            speakerDisplay: speaker,
            startSeconds: start,
            endSeconds: end,
            text: text,
            confidence: nil
        )
    }

    private func metadata(
        _ id: String,
        title: String,
        artist: String,
        start: Double,
        end: Double,
        kind: StreamAppMetadataKind = .song
    ) -> StreamAppMetadataItem {
        StreamAppMetadataItem(
            id: id,
            kind: kind,
            startSeconds: start,
            endSeconds: end,
            title: title,
            artist: artist,
            subtitle: nil
        )
    }
}
