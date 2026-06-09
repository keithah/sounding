import XCTest
@testable import SoundingKit

final class StreamAppTimelineRailProjectionTests: XCTestCase {
    func testBuildsSongAndMarkerRailItemsInWindow() throws {
        let items = [
            timeline("song:1", kind: .song, start: 10, end: 70, title: "ONE-LINERS", subtitle: "HEIDI FOSS"),
            timeline("event:id3:1", kind: .event, start: 24, end: 25, title: "Timed ID3 ad start", subtitle: "ID3"),
            timeline("event:scte35:1", kind: .event, start: 52, end: 55, title: "SCTE-35 break start", subtitle: "SCTE-35"),
            timeline("transcript:1", kind: .transcript, start: 20, end: 30, title: "Speaker", subtitle: "Words")
        ]

        let rail = StreamAppTimelineRailProjection.project(
            items: items,
            visibleStartSeconds: 0,
            visibleEndSeconds: 100
        )

        XCTAssertEqual(rail.visibleStartSeconds, 0)
        XCTAssertEqual(rail.visibleEndSeconds, 100)
        XCTAssertEqual(rail.spans.map(\.id), ["song:1", "ad:event:scte35:1"])
        XCTAssertEqual(rail.markers.map(\.source), [.timedID3, .scte35])
        let songSpan = try XCTUnwrap(rail.spans.first)
        XCTAssertEqual(songSpan.normalizedStart, 0.10, accuracy: 0.001)
        XCTAssertEqual(songSpan.normalizedEnd, 0.70, accuracy: 0.001)
        let adSpan = try XCTUnwrap(rail.spans.last)
        XCTAssertEqual(adSpan.title, "AD")
        XCTAssertEqual(adSpan.source, .scte35)
        XCTAssertTrue(adSpan.isAd)
        XCTAssertEqual(adSpan.colorToken, "ad")
        XCTAssertEqual(adSpan.normalizedStart, 0.52, accuracy: 0.001)
        XCTAssertEqual(adSpan.normalizedEnd, 0.55, accuracy: 0.001)
    }

    func testClampsRailItemsToVisibleWindow() throws {
        let rail = StreamAppTimelineRailProjection.project(
            items: [
                timeline("song:1", kind: .song, start: 90, end: 130, title: "Song", subtitle: "Artist")
            ],
            visibleStartSeconds: 100,
            visibleEndSeconds: 120
        )

        let span = try XCTUnwrap(rail.spans.first)
        XCTAssertEqual(span.normalizedStart, 0.0, accuracy: 0.001)
        XCTAssertEqual(span.normalizedEnd, 1.0, accuracy: 0.001)
    }

    func testPublicRailModelsCanBeConstructed() {
        let span = StreamAppTimelineRailSpan(
            id: "song:1",
            title: "Song",
            subtitle: "Artist",
            source: nil,
            isAd: false,
            startSeconds: 10,
            endSeconds: 20,
            normalizedStart: 0.1,
            normalizedEnd: 0.2,
            colorToken: "orange",
            isSeekable: true
        )
        let marker = StreamAppTimelineRailMarker(
            id: "event:1",
            title: "Cue",
            source: .scte35,
            seconds: 15,
            normalizedPosition: 0.15,
            colorToken: "red",
            isSeekable: false
        )

        XCTAssertEqual(span.id, "song:1")
        XCTAssertEqual(marker.source, .scte35)
    }

    func testClassifiesSCTEMarkerAliases() {
        let rail = StreamAppTimelineRailProjection.project(
            items: [
                timeline("event:splice:1", kind: .event, start: 10, end: 10, title: "splice_insert", subtitle: nil),
                timeline("event:cue:1", kind: .event, start: 20, end: 20, title: "EXT-X-CUE-OUT", subtitle: nil),
                timeline("event:cue:2", kind: .event, start: 25, end: 25, title: "EXT-X-CUE-IN", subtitle: nil),
                timeline("event:cue:3", kind: .event, start: 28, end: 28, title: "cue-out", subtitle: nil),
                timeline("event:cue:4", kind: .event, start: 29, end: 29, title: "cue-in", subtitle: nil)
            ],
            visibleStartSeconds: 0,
            visibleEndSeconds: 30
        )

        XCTAssertEqual(rail.markers.map(\.source), [.scte35, .scte35, .scte35, .scte35, .scte35])
    }

    func testClassifiesBareSCTE35MarkerType() {
        let rail = StreamAppTimelineRailProjection.project(
            items: [
                timeline("event:marker:1", kind: .event, start: 10, end: 10, title: "Marker", subtitle: "SCTE35"),
                timeline("event:scte35:2", kind: .event, start: 20, end: 20, title: "Break", subtitle: nil)
            ],
            visibleStartSeconds: 0,
            visibleEndSeconds: 30
        )

        XCTAssertEqual(rail.markers.map(\.source), [.scte35, .scte35])
    }

    func testClassifiesICYMarkersWithDedicatedSource() throws {
        let rail = StreamAppTimelineRailProjection.project(
            items: [
                timeline("event:icy:1", kind: .event, start: 10, end: 10, title: "Morgan Wallen - Love Somebody", subtitle: "ICY", source: "icy_stream")
            ],
            visibleStartSeconds: 0,
            visibleEndSeconds: 30
        )

        let marker = try XCTUnwrap(rail.markers.first)
        XCTAssertEqual(marker.source, .icy)
        XCTAssertEqual(marker.colorToken, "blue")
    }

    func testID3AdvertisementMarkersUseReservedAdColor() throws {
        let rail = StreamAppTimelineRailProjection.project(
            items: [
                timeline("event:id3:ad", kind: .event, start: 10, end: 10, title: "AD", subtitle: "timed_id3", source: "timed_id3")
            ],
            visibleStartSeconds: 0,
            visibleEndSeconds: 30
        )

        let marker = try XCTUnwrap(rail.markers.first)
        XCTAssertEqual(marker.title, "AD")
        XCTAssertEqual(marker.source, .timedID3)
        XCTAssertEqual(marker.colorToken, "ad")
    }

    func testSongRailColorsAvoidReservedAdColorFamily() throws {
        let rail = StreamAppTimelineRailProjection.project(
            items: [
                timeline(
                    "song:red-looking",
                    kind: .song,
                    start: 10,
                    end: 90,
                    title: "Shake Your Money Maker",
                    subtitle: "Ludacris",
                    source: "icy"
                ),
                timeline("event:id3:ad", kind: .event, start: 95, end: 95, title: "AD", subtitle: "timed_id3", source: "timed_id3")
            ],
            visibleStartSeconds: 0,
            visibleEndSeconds: 120
        )

        let songSpan = try XCTUnwrap(rail.spans.first { !$0.isAd })
        XCTAssertNotEqual(songSpan.colorToken, "ad")
        XCTAssertNotEqual(songSpan.colorToken, "pink")

        let adMarker = try XCTUnwrap(rail.markers.first { $0.title == "AD" })
        XCTAssertEqual(adMarker.colorToken, "ad")
    }

    func testBuildsAdSpanFromSCTE35DurationEvent() throws {
        let rail = StreamAppTimelineRailProjection.project(
            items: [
                timeline(
                    "event:ad:start",
                    kind: .event,
                    start: 100,
                    end: 100,
                    title: "Ad break start",
                    subtitle: "Duration 60.464s",
                    source: "scte35"
                ),
                timeline("song:1", kind: .song, start: 90, end: 190, title: "Hey Ya!", subtitle: "OutKast")
            ],
            visibleStartSeconds: 90,
            visibleEndSeconds: 190
        )

        let adSpan = try XCTUnwrap(rail.spans.first(where: \.isAd))
        XCTAssertEqual(adSpan.title, "AD")
        XCTAssertEqual(adSpan.colorToken, "ad")
        XCTAssertEqual(adSpan.startSeconds, 100, accuracy: 0.001)
        XCTAssertEqual(adSpan.endSeconds, 160.464, accuracy: 0.001)
        XCTAssertEqual(adSpan.source, .scte35)
    }

    func testRepeatedICYAdStartsBuildSeparateAdSpansUntilNextSong() throws {
        let rail = StreamAppTimelineRailProjection.project(
            items: [
                timeline(
                    "event:icy:ad:start",
                    kind: .event,
                    start: 100,
                    end: 100,
                    title: "Ad break start",
                    subtitle: "icy",
                    source: "icy"
                ),
                timeline(
                    "event:icy:ad:repeat",
                    kind: .event,
                    start: 130,
                    end: 130,
                    title: "Ad break start",
                    subtitle: "icy",
                    source: "icy"
                ),
                timeline("song:next", kind: .song, start: 190, end: 260, title: "Next Song", subtitle: "Next Artist")
            ],
            visibleStartSeconds: 90,
            visibleEndSeconds: 260
        )

        let adSpans = rail.spans.filter(\.isAd)
        XCTAssertEqual(adSpans.map(\.title), ["AD", "AD"])
        XCTAssertEqual(adSpans.map(\.colorToken), ["ad", "ad"])
        XCTAssertEqual(adSpans.map(\.source), [.icy, .icy])
        XCTAssertEqual(adSpans.map(\.startSeconds), [100, 130])
        XCTAssertEqual(adSpans.map(\.endSeconds), [130, 190])
    }

    func testDoesNotClassifyEmbeddedCueWordsAsSCTE() {
        let rail = StreamAppTimelineRailProjection.project(
            items: [
                timeline("event:id3:rescue", kind: .event, start: 10, end: 10, title: "Rescue in progress", subtitle: "ID3"),
                timeline("event:rescue", kind: .event, start: 20, end: 20, title: "Rescue out marker", subtitle: nil),
                timeline("event:notice", kind: .event, start: 30, end: 30, title: "Station notice", subtitle: nil)
            ],
            visibleStartSeconds: 0,
            visibleEndSeconds: 40
        )

        XCTAssertEqual(rail.markers.map(\.source), [.timedID3, .unknown, .unknown])
    }

    func testNormalizesReversedVisibleWindow() throws {
        let rail = StreamAppTimelineRailProjection.project(
            items: [
                timeline("song:1", kind: .song, start: 90, end: 130, title: "Song", subtitle: "Artist"),
                timeline("event:id3:1", kind: .event, start: 110, end: 110, title: "Timed ID3", subtitle: nil)
            ],
            visibleStartSeconds: 120,
            visibleEndSeconds: 100
        )

        XCTAssertEqual(rail.visibleStartSeconds, 100)
        XCTAssertEqual(rail.visibleEndSeconds, 120)
        let span = try XCTUnwrap(rail.spans.first)
        XCTAssertEqual(span.normalizedStart, 0.0, accuracy: 0.001)
        XCTAssertEqual(span.normalizedEnd, 1.0, accuracy: 0.001)
        let marker = try XCTUnwrap(rail.markers.first)
        XCTAssertEqual(marker.normalizedPosition, 0.5, accuracy: 0.001)
    }

    func testNormalizesNonFiniteVisibleWindow() {
        let rail = StreamAppTimelineRailProjection.project(
            items: [
                timeline("song:1", kind: .song, start: 0, end: 10, title: "Song", subtitle: "Artist")
            ],
            visibleStartSeconds: .nan,
            visibleEndSeconds: .infinity
        )

        XCTAssertEqual(rail.visibleStartSeconds, 0)
        XCTAssertEqual(rail.visibleEndSeconds, 0)
        XCTAssertEqual(rail.spans, [])
        XCTAssertEqual(rail.markers, [])
    }

    func testBroadcastProjectionSuppressesShortFingerprintFlips() {
        let rail = StreamAppTimelineRailProjection.project(
            metadata: [
                metadata("song:1", title: "Clocks", artist: "Coldplay", start: 0, end: 70, source: "timed_id3"),
                metadata("song:2", title: "MUTT", artist: "Leon Thomas", start: 70, end: 76, source: "chromaprint"),
                metadata("song:3", title: "Clocks", artist: "Coldplay", start: 76, end: 84, source: "chromaprint"),
                metadata("song:4", title: "MUTT", artist: "Leon Thomas", start: 84, end: 210, source: "timed_id3"),
            ],
            visibleStartSeconds: 0,
            visibleEndSeconds: 210
        )

        XCTAssertEqual(rail.spans.map(\.title), ["Clocks", "MUTT"])
        XCTAssertEqual(rail.spans[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(rail.spans[0].endSeconds, 84, accuracy: 0.001)
        XCTAssertEqual(rail.spans[1].startSeconds, 84, accuracy: 0.001)
        XCTAssertEqual(rail.spans[1].endSeconds, 210, accuracy: 0.001)
    }

    func testBroadcastProjectionSuppressesRepeatedTitleOnlyRowsWhenArtistBackedTrackExists() {
        let rail = StreamAppTimelineRailProjection.project(
            metadata: [
                metadata("event:title:1", kind: .event, title: "The Great Divide", artist: nil, start: 0, end: 0, source: "scte35"),
                metadata("event:title:2", kind: .event, title: "The Great Divide", artist: nil, start: 8, end: 8, source: "scte35"),
                metadata("song:artist", kind: .song, title: "The Great Divide", artist: "Noah Kahan", start: 8, end: 32, source: "timed_id3"),
                metadata("event:title:3", kind: .event, title: "The Great Divide", artist: nil, start: 21, end: 21, source: "scte35"),
                metadata("event:title:4", kind: .event, title: "The Great Divide", artist: nil, start: 40, end: 40, source: "timed_id3"),
            ],
            visibleStartSeconds: 0,
            visibleEndSeconds: 60
        )

        XCTAssertEqual(rail.spans.map(\.title), ["The Great Divide"])
        XCTAssertEqual(rail.spans.first?.startSeconds, 0)
        XCTAssertEqual(rail.spans.first?.endSeconds, 40)
        XCTAssertEqual(rail.markers, [])
    }

    func testTranscriptParagraphsCreateInferredAdSpan() throws {
        let rail = StreamAppTimelineRailProjection.project(
            metadata: [],
            paragraphs: [
                paragraph(1, start: 10, end: 24, text: "Start your free trial today at Shopify.com/win."),
                paragraph(2, start: 26, end: 38, text: "Terms and conditions apply. Member FDIC."),
            ],
            visibleStartSeconds: 0,
            visibleEndSeconds: 60
        )

        let adSpan = try XCTUnwrap(rail.spans.first)
        XCTAssertEqual(adSpan.id, "ad-inferred:1")
        XCTAssertEqual(adSpan.title, "AD")
        XCTAssertEqual(adSpan.source, .transcript)
        XCTAssertEqual(adSpan.colorToken, "ad-inferred")
        XCTAssertEqual(adSpan.startSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(adSpan.endSeconds, 38, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(adSpan.confidence ?? 0, 0.70)
        XCTAssertTrue(adSpan.signals.contains { $0.contains("url") })
    }

    func testDefiniteAdSpanWinsOverOverlappingTranscriptInferredSpan() throws {
        let rail = StreamAppTimelineRailProjection.project(
            metadata: [
                metadata("event:ad:start", kind: .event, title: "Ad break start", artist: nil, start: 10, end: 10, source: "scte35"),
                metadata("event:ad:end", kind: .event, title: "Ad break end", artist: nil, start: 50, end: 50, source: "scte35"),
            ],
            paragraphs: [
                paragraph(1, start: 20, end: 30, text: "Visit acme dot com. Terms and conditions apply."),
            ],
            visibleStartSeconds: 0,
            visibleEndSeconds: 60
        )

        let adSpans = rail.spans.filter(\.isAd)
        XCTAssertEqual(adSpans.count, 1)
        let adSpan = try XCTUnwrap(adSpans.first)
        XCTAssertEqual(adSpan.source, .scte35)
        XCTAssertEqual(adSpan.colorToken, "ad")
        XCTAssertNil(adSpan.confidence)
        XCTAssertEqual(adSpan.signals, [])
        XCTAssertEqual(adSpan.startSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(adSpan.endSeconds, 50, accuracy: 0.001)
    }

    private func timeline(
        _ id: String,
        kind: StreamAppTimelineItemKind,
        start: Double,
        end: Double,
        title: String,
        subtitle: String?,
        source: String? = nil
    ) -> StreamAppTimelineItem {
        StreamAppTimelineItem(
            id: id,
            kind: kind,
            startSeconds: start,
            endSeconds: end,
            title: title,
            subtitle: subtitle,
            source: source,
            isSeekable: true
        )
    }

    private func metadata(
        _ id: String,
        kind: StreamAppMetadataKind = .song,
        title: String,
        artist: String?,
        start: Double,
        end: Double,
        source: String
    ) -> StreamAppMetadataItem {
        StreamAppMetadataItem(
            id: id,
            kind: kind,
            startSeconds: start,
            endSeconds: end,
            title: title,
            artist: artist,
            subtitle: nil,
            source: source
        )
    }

    private func paragraph(
        _ id: Int64,
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
