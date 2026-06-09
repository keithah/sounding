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
        XCTAssertEqual(index.currentSong(at: 60)?.title, "Current")
        XCTAssertNil(index.currentSong(at: 5))
        XCTAssertEqual(index.currentSong(at: nil)?.title, "Newest")
    }

    func testTimelineItemsPreserveRawMetadataPayload() throws {
        let rawMetadata = #"{"StreamTitle":"AD","TIT2":"Advertisement"}"#
        let projection = StreamAppTimelineProjection(
            paragraphs: [],
            metadata: [
                metadata(
                    "event:raw",
                    title: "AD",
                    artist: nil,
                    start: 12,
                    end: 12,
                    kind: .event,
                    source: "icy",
                    rawMetadata: rawMetadata
                )
            ]
        )

        let item = try XCTUnwrap(projection.timelineItems(limit: 10).first)
        XCTAssertEqual(item.rawMetadata, rawMetadata)
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

    func testSuppressesTitleOnlyMetadataEventsInsideArtistBackedSongRun() {
        let projection = StreamAppTimelineProjection(
            paragraphs: [],
            metadata: [
                metadata("song:0", title: "Beautiful Things", artist: nil, start: 96, end: 96, source: "timed_id3"),
                metadata("event:0", title: "Beautiful Things", artist: nil, start: 100, end: 100, kind: .event, source: "timed_id3"),
                metadata("event:7", title: "Beautiful Things", artist: "Benson Boone", start: 100, end: 100, kind: .event, source: "hls_segment"),
                metadata("song:1", title: "Beautiful Things", artist: "Benson Boone", start: 100, end: 116, source: "timed_id3"),
                metadata("event:5", title: "Ad break end", artist: nil, start: 110, end: 110, kind: .event, source: "scte35"),
                metadata("event:6", title: "Beautiful Things", artist: nil, start: 118, end: 118, kind: .event, source: "timed_id3"),
                metadata("event:8", title: "Beautiful Things", artist: "Benson Boone", start: 124, end: 124, kind: .event, source: "hls_segment"),
                metadata("song:2", title: "Beautiful Things", artist: nil, start: 112, end: 112, source: "timed_id3"),
                metadata("song:3", title: "Beautiful Things", artist: nil, start: 126, end: 126, source: "timed_id3"),
                metadata("event:4", title: "Ad break end", artist: nil, start: 98, end: 98, kind: .event, source: "scte35"),
                metadata("song:4", title: "Next Song", artist: "Next Artist", start: 240, end: 300, source: "timed_id3"),
            ]
        )

        XCTAssertEqual(
            projection.timelineItems(limit: 10).map { "\($0.kind.rawValue):\($0.title)" },
            [
                "song:Beautiful Things",
                "event:Ad break end",
                "event:Ad break end",
                "song:Next Song",
            ]
        )
        XCTAssertEqual(projection.metadataChanges.first { $0.title == "Beautiful Things" }?.endSeconds, 126)
    }

    func testPromotesRepeatedTitleOnlyMetadataToSingleArtistBackedRun() {
        let projection = StreamAppTimelineProjection(
            paragraphs: [],
            metadata: [
                metadata("event:title:1", title: "The Great Divide", artist: nil, start: 0, end: 0, kind: .event, source: "timed_id3"),
                metadata("event:title:2", title: "The Great Divide", artist: nil, start: 8, end: 8, kind: .event, source: "timed_id3"),
                metadata("song:artist", title: "The Great Divide", artist: "Noah Kahan", start: 12, end: 24, source: "timed_id3"),
                metadata("event:title:3", title: "The Great Divide", artist: nil, start: 36, end: 36, kind: .event, source: "timed_id3"),
                metadata("song:title:4", title: "The Great Divide", artist: nil, start: 48, end: 48, source: "timed_id3"),
                metadata("song:next", title: "Hotline Bling", artist: "Drake", start: 72, end: 90, source: "timed_id3"),
            ]
        )

        XCTAssertEqual(projection.metadataChanges.map(\.title), ["The Great Divide", "Hotline Bling"])
        let greatDivide = projection.metadataChanges.first
        XCTAssertEqual(greatDivide?.artist, "Noah Kahan")
        XCTAssertEqual(greatDivide?.startSeconds, 0)
        XCTAssertEqual(greatDivide?.endSeconds, 72)
        XCTAssertEqual(
            projection.timelineItems(limit: 10).filter { $0.title == "The Great Divide" }.count,
            1
        )
    }

    func testCollapsesGenericSegmentTitleEventsIntoOneSongLikeRun() {
        let projection = StreamAppTimelineProjection(
            paragraphs: [],
            metadata: [
                metadata("event:1", title: "Manchild (Clean)", artist: nil, start: 0, end: 0, kind: .event, source: "hls_segment"),
                metadata("event:2", title: "Manchild (Clean)", artist: nil, start: 12, end: 12, kind: .event, source: "hls_segment"),
                metadata("event:3", title: "Manchild (Clean)", artist: nil, start: 24, end: 24, kind: .event, source: "hls_segment"),
                metadata("song:4", title: "Manchild (Clean)", artist: "Sabrina Carpenter", start: 36, end: 64, source: "timed_id3"),
                metadata("event:5", title: "Manchild (Clean)", artist: nil, start: 72, end: 72, kind: .event, source: "hls_segment"),
                metadata("event:ad", title: "Ad break start", artist: nil, start: 90, end: 90, kind: .event, source: "scte35"),
            ]
        )

        XCTAssertEqual(
            projection.timelineItems(limit: 10).map { "\($0.kind.rawValue):\($0.title)" },
            [
                "song:Manchild (Clean)",
                "event:Ad break start",
            ]
        )
        let song = projection.metadataChanges.first
        XCTAssertEqual(song?.artist, "Sabrina Carpenter")
        XCTAssertEqual(song?.startSeconds, 0)
        XCTAssertEqual(song?.endSeconds, 72)
    }

    func testCollapsesSCTETitleOnlyRowsIntoArtistBackedSongRun() {
        let projection = StreamAppTimelineProjection(
            paragraphs: [],
            metadata: [
                metadata("event:scte:title:1", title: "The Great Divide", artist: nil, start: 0, end: 0, kind: .event, source: "scte35"),
                metadata("event:scte:title:2", title: "The Great Divide", artist: nil, start: 8, end: 8, kind: .event, source: "scte35"),
                metadata("song:artist", title: "The Great Divide", artist: "Noah Kahan", start: 12, end: 24, source: "timed_id3"),
                metadata("event:scte:title:3", title: "The Great Divide", artist: nil, start: 21, end: 21, kind: .event, source: "scte35"),
                metadata("event:scte:ad", title: "Ad break start", artist: nil, start: 90, end: 90, kind: .event, source: "scte35"),
            ]
        )

        XCTAssertEqual(
            projection.timelineItems(limit: 10).map { "\($0.kind.rawValue):\($0.title)" },
            [
                "song:The Great Divide",
                "event:Ad break start",
            ]
        )
        let song = projection.metadataChanges.first
        XCTAssertEqual(song?.artist, "Noah Kahan")
        XCTAssertEqual(song?.startSeconds, 0)
        XCTAssertEqual(song?.endSeconds, 24)
    }

    func testCollapsesICYTitleOnlyRowsIntoArtistBackedSongRun() {
        let projection = StreamAppTimelineProjection(
            paragraphs: [],
            metadata: [
                metadata("event:icy:title:1", title: "Love Somebody", artist: nil, start: 0, end: 0, kind: .event, source: "icy_stream"),
                metadata("event:icy:title:2", title: "Love Somebody", artist: nil, start: 12, end: 12, kind: .event, source: "icy_stream"),
                metadata("song:artist", title: "Love Somebody", artist: "Morgan Wallen", start: 12, end: 48, source: "icy"),
                metadata("event:icy:title:3", title: "Love Somebody", artist: nil, start: 24, end: 24, kind: .event, source: "icy_stream"),
                metadata("event:scte:ad", title: "Ad break start", artist: nil, start: 70, end: 70, kind: .event, source: "scte35"),
            ]
        )

        XCTAssertEqual(
            projection.timelineItems(limit: 10).map { "\($0.kind.rawValue):\($0.title)" },
            [
                "song:Love Somebody",
                "event:Ad break start",
            ]
        )
        let song = projection.metadataChanges.first
        XCTAssertEqual(song?.artist, "Morgan Wallen")
        XCTAssertEqual(song?.startSeconds, 0)
        XCTAssertEqual(song?.endSeconds, 48)
    }

    func testSuppressesHistoricalTitleOnlyEchoesAroundArtistBackedSong() {
        let projection = StreamAppTimelineProjection(
            paragraphs: [],
            metadata: [
                metadata("event:title:1", title: "The Great Divide", artist: nil, start: 0, end: 0, kind: .event, source: "timed_id3"),
                metadata("event:title:2", title: "The Great Divide", artist: nil, start: 8, end: 8, kind: .event, source: "scte35"),
                metadata("song:artist", title: "The Great Divide", artist: "Noah Kahan", start: 8, end: 32, source: "timed_id3"),
                metadata("event:title:3", title: "The Great Divide", artist: nil, start: 13, end: 13, kind: .event, source: "timed_id3"),
                metadata("event:title:4", title: "The Great Divide", artist: nil, start: 21, end: 21, kind: .event, source: "scte35"),
                metadata("event:title:5", title: "The Great Divide", artist: nil, start: 32, end: 32, kind: .event, source: "icy_stream"),
            ]
        )

        XCTAssertEqual(projection.metadataChanges.map { "\($0.kind.rawValue):\($0.title):\($0.artist ?? "")" }, [
            "song:The Great Divide:Noah Kahan",
        ])
        XCTAssertEqual(
            projection.timelineItems(limit: 20).map { "\($0.kind.rawValue):\($0.title)" },
            ["song:The Great Divide"]
        )
    }

    func testCollapsesTitleOnlyEchoesWhenArtistNeverArrives() {
        let projection = StreamAppTimelineProjection(
            paragraphs: [],
            metadata: [
                metadata("event:title:1", title: "Manchild (Clean)", artist: nil, start: 0, end: 0, kind: .event, source: "timed_id3"),
                metadata("event:title:2", title: "Manchild (Clean)", artist: nil, start: 12, end: 12, kind: .event, source: "scte35"),
                metadata("event:title:3", title: "Manchild (Clean)", artist: nil, start: 24, end: 24, kind: .event, source: "hls_segment"),
                metadata("event:title:4", title: "Manchild (Clean)", artist: nil, start: 36, end: 36, kind: .event, source: "icy_stream"),
            ]
        )

        XCTAssertEqual(projection.metadataChanges.map(\.title), ["Manchild (Clean)"])
        XCTAssertEqual(projection.metadataChanges.first?.startSeconds, 0)
        XCTAssertEqual(projection.metadataChanges.first?.endSeconds, 36)
        XCTAssertEqual(
            projection.timelineItems(limit: 20).map { "\($0.kind.rawValue):\($0.title)" },
            ["song:Manchild (Clean)"]
        )
    }

    func testKeepsOneArtistBackedRowForRepeatedSameTrackTitleMarkers() {
        let projection = StreamAppTimelineProjection(
            paragraphs: [],
            metadata: [
                metadata("event:title:1", title: "The Great Divide", artist: nil, start: 0, end: 0, kind: .event, source: "scte35"),
                metadata("event:title:2", title: "The Great Divide", artist: nil, start: 8, end: 8, kind: .event, source: "scte35"),
                metadata("song:artist", title: "The Great Divide", artist: "Noah Kahan", start: 8, end: 32, source: "timed_id3"),
                metadata("event:title:3", title: "The Great Divide", artist: nil, start: 21, end: 21, kind: .event, source: "scte35"),
                metadata("event:title:4", title: "The Great Divide", artist: nil, start: 32, end: 32, kind: .event, source: "scte35"),
                metadata("event:title:5", title: "The Great Divide", artist: nil, start: 40, end: 40, kind: .event, source: "timed_id3"),
            ]
        )

        XCTAssertEqual(projection.metadataChanges.map(\.title), ["The Great Divide"])
        XCTAssertEqual(projection.metadataChanges.first?.artist, "Noah Kahan")
        XCTAssertEqual(projection.metadataChanges.first?.startSeconds, 0)
        XCTAssertEqual(projection.metadataChanges.first?.endSeconds, 40)
        XCTAssertEqual(
            projection.timelineItems(limit: 20).map { "\($0.kind.rawValue):\($0.title):\($0.speakerDisplay?.displayLabel ?? "")" },
            ["song:The Great Divide:Noah Kahan"]
        )
    }

    func testPromotesLongRepeatedTitleRunToSingleArtistBackedTrack() {
        let projection = StreamAppTimelineProjection(
            paragraphs: [],
            metadata: [
                metadata("event:title:1", title: "Beautiful Things", artist: nil, start: 0, end: 0, kind: .event, source: "timed_id3"),
                metadata("event:title:2", title: "Beautiful Things", artist: nil, start: 75, end: 75, kind: .event, source: "scte35"),
                metadata("event:title:3", title: "Beautiful Things", artist: nil, start: 150, end: 150, kind: .event, source: "timed_id3"),
                metadata("event:title:4", title: "Beautiful Things", artist: nil, start: 225, end: 225, kind: .event, source: "scte35"),
                metadata("song:artist", title: "Beautiful Things", artist: "Benson Boone", start: 302, end: 320, source: "timed_id3"),
                metadata("event:title:5", title: "Beautiful Things", artist: nil, start: 315, end: 315, kind: .event, source: "timed_id3"),
                metadata("song:next", title: "Next Song", artist: "Next Artist", start: 360, end: 400, source: "timed_id3"),
            ]
        )

        XCTAssertEqual(
            projection.metadataChanges.map { "\($0.kind.rawValue):\($0.title):\($0.artist ?? "")" },
            [
                "song:Beautiful Things:Benson Boone",
                "song:Next Song:Next Artist",
            ]
        )
        XCTAssertEqual(projection.metadataChanges.first?.startSeconds, 0)
        XCTAssertEqual(projection.metadataChanges.first?.endSeconds, 360)
        XCTAssertEqual(
            projection.timelineItems(limit: 20).map { "\($0.kind.rawValue):\($0.title):\($0.speakerDisplay?.displayLabel ?? "")" },
            [
                "song:Beautiful Things:Benson Boone",
                "song:Next Song:Next Artist",
            ]
        )
    }

    func testSuppressesGenericEventEchoesAroundArtistBackedTrack() {
        let projection = StreamAppTimelineProjection(
            paragraphs: [],
            metadata: [
                metadata("event:generic:1", title: "The Great Divide", artist: nil, start: 0, end: 0, kind: .event, source: nil),
                metadata("event:generic:2", title: "The Great Divide", artist: nil, start: 8, end: 8, kind: .event, source: nil),
                metadata("song:artist", title: "The Great Divide", artist: "Noah Kahan", start: 8, end: 32, source: "timed_id3"),
                metadata("event:generic:3", title: "The Great Divide", artist: nil, start: 21, end: 21, kind: .event, source: nil),
                metadata("event:generic:4", title: "The Great Divide", artist: nil, start: 32, end: 32, kind: .event, source: nil),
            ]
        )

        XCTAssertEqual(projection.metadataChanges.map(\.title), ["The Great Divide"])
        XCTAssertEqual(projection.metadataChanges.first?.artist, "Noah Kahan")
        XCTAssertEqual(projection.metadataChanges.first?.startSeconds, 0)
        XCTAssertEqual(projection.metadataChanges.first?.endSeconds, 32)
        XCTAssertEqual(
            projection.timelineItems(limit: 20).map { "\($0.kind.rawValue):\($0.title):\($0.speakerDisplay?.displayLabel ?? "")" },
            ["song:The Great Divide:Noah Kahan"]
        )
    }

    func testTrustedTimedMetadataSuppressesFingerprintGuessesUntilGap() {
        let projection = StreamAppTimelineProjection(
            paragraphs: [],
            metadata: [
                metadata("song:1", title: "The Great Divide", artist: "Noah Kahan", start: 0, end: 60, source: "scte35"),
                metadata("song:2", title: "Hotline Bling", artist: "Drake", start: 60, end: 102, source: "chromaprint"),
                metadata("song:3", title: "The Great Divide", artist: "Noah Kahan", start: 92, end: 132, source: "scte35"),
                metadata("song:4", title: "Hotline Bling", artist: "Drake", start: 132, end: 150, source: "chromaprint"),
                metadata("song:5", title: "Next Song", artist: "Next Artist", start: 190, end: 210, source: "chromaprint"),
            ],
            player: AppPlayerTimelineSnapshot(streamID: 1, positionSeconds: 120, liveEdgeSeconds: 220)
        )

        XCTAssertEqual(projection.metadataChanges.map(\.title), ["The Great Divide", "Next Song"])
        XCTAssertEqual(projection.metadataChanges.first?.endSeconds, 190)
        XCTAssertEqual(projection.currentMetadata()?.title, "The Great Divide")
        XCTAssertEqual(
            projection.timelineItems(limit: 10).filter { $0.kind == .song }.map(\.title),
            ["The Great Divide", "Next Song"]
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

    func testTranscriptParagraphsDoNotMergeIntoMinuteLongBlocksWithoutMetadataBoundaries() {
        let speaker = display("host")
        let projection = StreamAppTimelineProjection(
            paragraphs: [
                paragraph(1, speaker: speaker, start: 0, end: 8, text: "First chunk."),
                paragraph(2, speaker: speaker, start: 10, end: 18, text: "Second chunk."),
                paragraph(3, speaker: speaker, start: 20, end: 28, text: "Third chunk."),
                paragraph(4, speaker: speaker, start: 30, end: 38, text: "Fourth chunk."),
            ],
            metadata: []
        )

        XCTAssertEqual(
            projection.timelineItems(limit: 10).filter { $0.kind == .transcript }.map(\.subtitle),
            [
                "First chunk. Second chunk. Third chunk.",
                "Fourth chunk.",
            ]
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

    func testNonSongPolicyKeepsAdTranscriptEvenWhenSongMarkerOverlaps() {
        let speaker = display(StreamAppSpeakerDisplayProjection.unknownSpeakerLabel)
        let projection = StreamAppTimelineProjection(
            paragraphs: [
                paragraph(1, speaker: speaker, start: 95, end: 105, text: "Sale ends Sunday."),
                paragraph(2, speaker: speaker, start: 15, end: 25, text: "Song lyric line."),
            ],
            metadata: [
                metadata(
                    "song:stale",
                    title: "The Great Divide",
                    artist: "Noah Kahan",
                    start: 0,
                    end: 120,
                    source: "ID3"
                ),
                StreamAppMetadataItem(
                    id: "event:ad",
                    kind: .event,
                    startSeconds: 90,
                    endSeconds: 150,
                    title: "Ad break start",
                    artist: nil,
                    subtitle: "Duration 60.000s | SCTE35",
                    source: "SCTE35"
                ),
            ],
            transcriptionPolicy: .nonSongs
        )

        XCTAssertEqual(projection.timelineItems(limit: 10).filter { $0.kind == .transcript }.map(\.subtitle), [
            "Sale ends Sunday.",
        ])
    }

    func testRepeatedAdStartsSplitTranscriptParagraphsIntoSeparateBreaks() {
        let host = display("host")
        let guest = display("guest")
        let projection = StreamAppTimelineProjection(
            paragraphs: [
                paragraph(1, speaker: host, start: 100, end: 112, text: "First ad sentence."),
                paragraph(2, speaker: guest, start: 116, end: 145, text: "Second ad sentence."),
                paragraph(3, speaker: host, start: 160, end: 188, text: "Third ad sentence."),
                paragraph(4, speaker: host, start: 230, end: 242, text: "Back to music transcript."),
            ],
            metadata: [
                metadata("event:icy:ad:start", title: "Ad break start", artist: nil, start: 98, end: 98, kind: .event, source: "icy"),
                metadata("event:icy:ad:repeat", title: "Ad break start", artist: nil, start: 130, end: 130, kind: .event, source: "icy"),
                metadata("song:next", title: "Next Song", artist: "Next Artist", start: 210, end: 260, source: "icy"),
            ],
            transcriptionPolicy: .nonSongs
        )

        let transcripts = projection.timelineItems(limit: 10).filter { $0.kind == .transcript }
        XCTAssertEqual(transcripts.count, 2)
        XCTAssertEqual(
            transcripts.map(\.subtitle),
            [
                "First ad sentence. Second ad sentence.",
                "Third ad sentence.",
            ]
        )
        XCTAssertEqual(transcripts.map(\.startSeconds), [100, 160])
        XCTAssertEqual(transcripts.map(\.endSeconds), [145, 188])
    }

    func testLongTranscriptSegmentSplitsAtRepeatedAdMarkersUsingWordTiming() {
        let host = display("host")
        let words = timedWords(
            segmentID: 1,
            speaker: host,
            entries: [
                (100, 105, "First"),
                (106, 112, "ad"),
                (134, 140, "Second"),
                (141, 145, "ad"),
                (164, 170, "Third"),
                (171, 188, "ad"),
            ]
        )
        let projection = StreamAppTimelineProjection(
            paragraphs: [
                paragraph(
                    1,
                    speaker: host,
                    start: 100,
                    end: 188,
                    text: "First ad Second ad Third ad",
                    words: words
                ),
            ],
            metadata: [
                metadata("event:icy:ad:start", title: "Ad break start", artist: nil, start: 98, end: 98, kind: .event, source: "icy"),
                metadata("event:icy:ad:repeat", title: "Ad break start", artist: nil, start: 130, end: 130, kind: .event, source: "icy"),
                metadata("event:icy:ad:repeat2", title: "Ad break start", artist: nil, start: 160, end: 160, kind: .event, source: "icy"),
                metadata("song:next", title: "Next Song", artist: "Next Artist", start: 210, end: 260, source: "icy"),
            ],
            transcriptionPolicy: .nonSongs
        )

        let transcripts = projection.timelineItems(limit: 10).filter { $0.kind == .transcript }
        XCTAssertEqual(transcripts.map(\.subtitle), [
            "First ad",
            "Second ad",
            "Third ad",
        ])
        XCTAssertEqual(transcripts.map(\.startSeconds), [100, 134, 164])
        XCTAssertEqual(transcripts.map(\.endSeconds), [112, 145, 188])
    }

    func testCollapsesRepeatedGenericAdMetadataIntoOneRun() {
        let projection = StreamAppTimelineProjection(
            paragraphs: [],
            metadata: [
                metadata("event:ad:1", title: "AD", artist: nil, start: 10, end: 10, kind: .event, source: "timed_id3 | Advertisement | ID3"),
                metadata("event:ad:2", title: "AD", artist: nil, start: 22, end: 22, kind: .event, source: "timed_id3 | Advertisement | ID3"),
                metadata("event:ad:3", title: "AD", artist: nil, start: 34, end: 34, kind: .event, source: "timed_id3 | Advertisement | ID3"),
                metadata("event:end", title: "Ad break end", artist: nil, start: 70, end: 70, kind: .event, source: "SCTE35"),
                metadata("song:next", title: "Next Song", artist: "Next Artist", start: 90, end: 120, source: "ID3"),
            ]
        )

        XCTAssertEqual(
            projection.timelineItems(limit: 10).map { "\($0.kind.rawValue):\($0.title)" },
            [
                "event:AD",
                "event:Ad break end",
                "song:Next Song",
            ]
        )
        let ad = projection.metadataChanges.first
        XCTAssertEqual(ad?.title, "AD")
        XCTAssertEqual(ad?.startSeconds, 10)
        XCTAssertEqual(ad?.endSeconds, 34)
    }

    func testNonSongPolicyKeepsTranscriptUntilExplicitAdEndAfterCoalescedGenericAdStarts() {
        let speaker = display(StreamAppSpeakerDisplayProjection.unknownSpeakerLabel)
        let projection = StreamAppTimelineProjection(
            paragraphs: [
                paragraph(1, speaker: speaker, start: 7980, end: 7990, text: "Ad copy after the last repeated marker."),
                paragraph(2, speaker: speaker, start: 7860, end: 7870, text: "Song lyric before the break."),
            ],
            metadata: [
                metadata(
                    "song:stale",
                    title: "Current Song",
                    artist: "Current Artist",
                    start: 7800,
                    end: 8010,
                    source: "icy"
                ),
                metadata(
                    "event:ad:coalesced",
                    title: "AD",
                    artist: nil,
                    start: 7884,
                    end: 7974,
                    kind: .event,
                    source: "icy_stream | Advertisement | ICY"
                ),
                metadata(
                    "event:ad:end",
                    title: "Ad break end",
                    artist: nil,
                    start: 8004,
                    end: 8004,
                    kind: .event,
                    source: "icy"
                ),
            ],
            transcriptionPolicy: .nonSongs
        )

        XCTAssertEqual(
            projection.timelineItems(limit: 10).filter { $0.kind == .transcript }.map(\.subtitle),
            ["Ad copy after the last repeated marker."]
        )
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
        text: String,
        words: [StreamAppTranscriptWord] = []
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
            confidence: nil,
            words: words
        )
    }

    private func timedWords(
        segmentID: Int64,
        speaker: StreamAppSpeakerDisplay,
        entries: [(Double, Double, String)]
    ) -> [StreamAppTranscriptWord] {
        entries.enumerated().map { offset, entry in
            StreamAppTranscriptWord(
                id: Int64(offset + 1),
                segmentID: segmentID,
                sequence: offset,
                speakerDisplay: speaker,
                startSeconds: entry.0,
                endSeconds: entry.1,
                text: entry.2,
                confidence: nil
            )
        }
    }

    private func metadata(
        _ id: String,
        title: String,
        artist: String?,
        start: Double,
        end: Double,
        kind: StreamAppMetadataKind = .song,
        source: String? = nil,
        rawMetadata: String? = nil
    ) -> StreamAppMetadataItem {
        StreamAppMetadataItem(
            id: id,
            kind: kind,
            startSeconds: start,
            endSeconds: end,
            title: title,
            artist: artist,
            subtitle: nil,
            source: source,
            rawMetadata: rawMetadata
        )
    }
}
