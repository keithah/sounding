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
        XCTAssertEqual(rail.spans.map(\.id), ["song:1"])
        XCTAssertEqual(rail.markers.map(\.source), [.timedID3, .scte35])
        let span = try XCTUnwrap(rail.spans.first)
        XCTAssertEqual(span.normalizedStart, 0.10, accuracy: 0.001)
        XCTAssertEqual(span.normalizedEnd, 0.70, accuracy: 0.001)
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
                timeline("event:cue:1", kind: .event, start: 20, end: 20, title: "EXT-X-CUE-OUT", subtitle: nil)
            ],
            visibleStartSeconds: 0,
            visibleEndSeconds: 30
        )

        XCTAssertEqual(rail.markers.map(\.source), [.scte35, .scte35])
    }

    private func timeline(
        _ id: String,
        kind: StreamAppTimelineItemKind,
        start: Double,
        end: Double,
        title: String,
        subtitle: String?
    ) -> StreamAppTimelineItem {
        StreamAppTimelineItem(
            id: id,
            kind: kind,
            startSeconds: start,
            endSeconds: end,
            title: title,
            subtitle: subtitle,
            isSeekable: true
        )
    }
}
